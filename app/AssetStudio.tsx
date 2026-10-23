"use client";

import {
  ChangeEvent,
  PointerEvent as ReactPointerEvent,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";

type AssetType = "角色" | "场景" | "道具";
type ReviewStatus = "待确认" | "通过" | "重做" | "暂缺";
type View = "canvas" | "table";
type Point = { x: number; y: number };

type Scene = {
  id: string;
  project: string;
  episode: string;
  description: string;
  position: Point;
};

type Asset = {
  id: string;
  name: string;
  type: AssetType;
  image: string;
  status: ReviewStatus;
  note: string;
  reuse: "S" | "A" | "B" | "C";
  position: Point;
};

type Relation = { sceneId: string; assetId: string };

const statusOptions: ReviewStatus[] = ["待确认", "通过", "重做", "暂缺"];
const typeOptions: AssetType[] = ["角色", "场景", "道具"];

const seedScenes: Scene[] = [
  { id: "SC-01", project: "雾港来信", episode: "第 1 集", description: "旧码头 · 夜", position: { x: 64, y: 92 } },
  { id: "SC-02", project: "雾港来信", episode: "第 1 集", description: "守港人值班室 · 夜", position: { x: 64, y: 312 } },
  { id: "SC-03", project: "雾港来信", episode: "第 2 集", description: "海关仓库 · 清晨", position: { x: 64, y: 532 } },
];

const seedAssets: Asset[] = [
  { id: "CHAR-001", name: "林默 · 基础造型", type: "角色", image: "", status: "通过", note: "正脸与全身母版已确认", reuse: "S", position: { x: 520, y: 66 } },
  { id: "CHAR-002", name: "守港人", type: "角色", image: "", status: "待确认", note: "需确认帽檐高度", reuse: "A", position: { x: 780, y: 66 } },
  { id: "ENV-001", name: "雾港旧码头", type: "场景", image: "", status: "通过", note: "夜景主场景", reuse: "S", position: { x: 520, y: 304 } },
  { id: "PROP-001", name: "铜制身份牌", type: "道具", image: "", status: "重做", note: "编号不清晰，需重做特写", reuse: "A", position: { x: 780, y: 304 } },
  { id: "ENV-002", name: "海关仓库", type: "场景", image: "", status: "暂缺", note: "等待外景母版", reuse: "A", position: { x: 520, y: 542 } },
];

const seedRelations: Relation[] = [
  { sceneId: "SC-01", assetId: "CHAR-001" },
  { sceneId: "SC-01", assetId: "CHAR-002" },
  { sceneId: "SC-01", assetId: "ENV-001" },
  { sceneId: "SC-01", assetId: "PROP-001" },
  { sceneId: "SC-02", assetId: "CHAR-001" },
  { sceneId: "SC-02", assetId: "CHAR-002" },
  { sceneId: "SC-03", assetId: "CHAR-001" },
  { sceneId: "SC-03", assetId: "ENV-002" },
];

function csvEscape(value: string | number) {
  const text = String(value ?? "");
  return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function parseCsv(text: string) {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (quoted) {
      if (char === '"' && text[index + 1] === '"') {
        cell += '"';
        index += 1;
      } else if (char === '"') quoted = false;
      else cell += char;
    } else if (char === '"') quoted = true;
    else if (char === ",") {
      row.push(cell);
      cell = "";
    } else if (char === "\n") {
      row.push(cell.replace(/\r$/, ""));
      if (row.some(Boolean)) rows.push(row);
      row = [];
      cell = "";
    } else cell += char;
  }
  row.push(cell.replace(/\r$/, ""));
  if (row.some(Boolean)) rows.push(row);
  if (rows.length < 2) return [];
  const headers = rows[0];
  return rows.slice(1).map((values) => Object.fromEntries(headers.map((key, index) => [key.trim(), values[index] ?? ""])));
}

function imageIsRenderable(value: string) {
  return /^(https?:\/\/|data:image\/|blob:)/i.test(value);
}

function AssetVisual({ asset, compact = false }: { asset: Asset; compact?: boolean }) {
  const [failed, setFailed] = useState(false);
  if (imageIsRenderable(asset.image) && !failed) {
    // User-provided asset URLs can point to arbitrary origins, so Next Image cannot safely optimize them.
    // eslint-disable-next-line @next/next/no-img-element
    return <img className={compact ? "asset-visual compact" : "asset-visual"} src={asset.image} alt={asset.name} onError={() => setFailed(true)} />;
  }
  return (
    <div className={`${compact ? "asset-visual compact" : "asset-visual"} placeholder type-${asset.type}`}>
      <span>{asset.type === "角色" ? "人" : asset.type === "场景" ? "景" : "物"}</span>
      {asset.image && <small>图片待定位</small>}
    </div>
  );
}

function StatusBadge({ status }: { status: ReviewStatus }) {
  return <span className={`status status-${status}`}>{status === "通过" && "● "}{status}</span>;
}

export default function AssetStudio() {
  const [view, setView] = useState<View>("canvas");
  const [scenes, setScenes] = useState(seedScenes);
  const [assets, setAssets] = useState(seedAssets);
  const [relations, setRelations] = useState(seedRelations);
  const [selectedScene, setSelectedScene] = useState("SC-01");
  const [selectedNode, setSelectedNode] = useState("SC-01");
  const [episodeFilter, setEpisodeFilter] = useState("全部集数");
  const [typeFilter, setTypeFilter] = useState("全部类型");
  const [statusFilter, setStatusFilter] = useState("全部状态");
  const [search, setSearch] = useState("");
  const [toast, setToast] = useState("");
  const [showEntry, setShowEntry] = useState(false);
  const [showAddAsset, setShowAddAsset] = useState(false);
  const [showHelp, setShowHelp] = useState(false);
  const [zoom, setZoom] = useState(1);
  const hydratedRef = useRef(false);
  const [scriptText, setScriptText] = useState("第 3 集|SC-04|灯塔内部 · 雨夜|角色:林默,陌生女孩|场景:灯塔内部|道具:旧钥匙");
  const [draftAsset, setDraftAsset] = useState({ name: "", type: "角色" as AssetType, image: "", note: "", reuse: "A" as Asset["reuse"] });
  const [drag, setDrag] = useState<{ id: string; start: Point; origin: Point } | null>(null);
  const [connect, setConnect] = useState<{ from: string; point: Point } | null>(null);
  const [edgeVersion, setEdgeVersion] = useState(0);
  const canvasWrapRef = useRef<HTMLDivElement>(null);
  const edgeCanvasRef = useRef<HTMLCanvasElement>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      try {
        const saved = window.localStorage.getItem("asset-frame-v1");
        if (saved) {
          const data = JSON.parse(saved) as { scenes?: Scene[]; assets?: Asset[]; relations?: Relation[] };
          if (data.scenes?.length) setScenes(data.scenes);
          if (data.assets?.length) setAssets(data.assets);
          if (data.relations) setRelations(data.relations);
          if (data.scenes?.[0]) setSelectedScene(data.scenes[0].id);
        }
      } catch {
        // Keep the built-in sample when an older local draft cannot be read.
      }
      hydratedRef.current = true;
    }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  useEffect(() => {
    if (!hydratedRef.current) return;
    window.localStorage.setItem("asset-frame-v1", JSON.stringify({ scenes, assets, relations }));
  }, [scenes, assets, relations]);

  const allNodes = useMemo(() => [
    ...scenes.map((scene) => ({ id: scene.id, kind: "scene" as const, position: scene.position })),
    ...assets.map((asset) => ({ id: asset.id, kind: "asset" as const, position: asset.position })),
  ], [scenes, assets]);

  const nodeById = useCallback((id: string) => allNodes.find((node) => node.id === id), [allNodes]);
  const episodes = useMemo(() => [...new Set(scenes.map((scene) => scene.episode))], [scenes]);
  const counts = useMemo(() => ({
    total: assets.length,
    approved: assets.filter((asset) => asset.status === "通过").length,
    pending: assets.filter((asset) => asset.status === "待确认").length,
    redo: assets.filter((asset) => asset.status === "重做").length,
    missing: assets.filter((asset) => asset.status === "暂缺").length,
  }), [assets]);

  const visibleScenes = useMemo(() => scenes.filter((scene) => episodeFilter === "全部集数" || scene.episode === episodeFilter), [scenes, episodeFilter]);
  const visibleSceneIds = useMemo(() => new Set(visibleScenes.map((scene) => scene.id)), [visibleScenes]);
  const relatedAssetIds = useMemo(() => new Set(relations.filter((relation) => visibleSceneIds.has(relation.sceneId)).map((relation) => relation.assetId)), [relations, visibleSceneIds]);
  const visibleAssets = useMemo(() => assets.filter((asset) => {
    const matchesEpisode = episodeFilter === "全部集数" || relatedAssetIds.has(asset.id);
    const matchesType = typeFilter === "全部类型" || asset.type === typeFilter;
    const matchesStatus = statusFilter === "全部状态" || asset.status === statusFilter;
    const term = search.trim().toLowerCase();
    const matchesSearch = !term || `${asset.id} ${asset.name} ${asset.note}`.toLowerCase().includes(term);
    return matchesEpisode && matchesType && matchesStatus && matchesSearch;
  }), [assets, episodeFilter, relatedAssetIds, typeFilter, statusFilter, search]);
  const visibleAssetIds = useMemo(() => new Set(visibleAssets.map((asset) => asset.id)), [visibleAssets]);

  const notify = useCallback((message: string) => {
    setToast(message);
    window.setTimeout(() => setToast(""), 2200);
  }, []);

  const updateAssetStatus = (id: string, status: ReviewStatus) => {
    setAssets((items) => items.map((asset) => asset.id === id ? { ...asset, status } : asset));
    notify(`已将 ${id} 标记为“${status}”`);
  };

  useEffect(() => {
    const wrap = canvasWrapRef.current;
    const canvas = edgeCanvasRef.current;
    if (!wrap || !canvas || view !== "canvas") return;
    const draw = () => {
      const rect = { width: wrap.clientWidth, height: wrap.clientHeight };
      const ratio = window.devicePixelRatio || 1;
      canvas.width = rect.width * ratio;
      canvas.height = rect.height * ratio;
      canvas.style.width = `${rect.width}px`;
      canvas.style.height = `${rect.height}px`;
      const context = canvas.getContext("2d");
      if (!context) return;
      context.scale(ratio, ratio);
      context.clearRect(0, 0, rect.width, rect.height);
      const drawCurve = (from: Point, to: Point, active = false) => {
        const offset = Math.max(70, Math.abs(to.x - from.x) * 0.4);
        context.beginPath();
        context.moveTo(from.x, from.y);
        context.bezierCurveTo(from.x + offset, from.y, to.x - offset, to.y, to.x, to.y);
        context.strokeStyle = active ? "#f16e43" : "rgba(61, 84, 78, .34)";
        context.lineWidth = active ? 2.3 : 1.5;
        context.stroke();
      };
      relations.forEach((relation) => {
        const scene = scenes.find((item) => item.id === relation.sceneId);
        const asset = assets.find((item) => item.id === relation.assetId);
        if (!scene || !asset || !visibleSceneIds.has(scene.id) || !visibleAssetIds.has(asset.id)) return;
        drawCurve({ x: scene.position.x + 214, y: scene.position.y + 75 }, { x: asset.position.x, y: asset.position.y + 80 }, selectedScene === scene.id);
      });
      if (connect) {
        const node = nodeById(connect.from);
        if (node) {
          const isScene = node.kind === "scene";
          drawCurve({ x: node.position.x + (isScene ? 214 : 0), y: node.position.y + (isScene ? 75 : 80) }, connect.point, true);
        }
      }
    };
    draw();
    const resizeObserver = new ResizeObserver(draw);
    resizeObserver.observe(wrap);
    return () => resizeObserver.disconnect();
  }, [view, relations, scenes, assets, connect, nodeById, selectedScene, visibleAssetIds, visibleSceneIds, edgeVersion]);

  useEffect(() => {
    if (!drag && !connect) return;
    const move = (event: PointerEvent) => {
      const rect = canvasWrapRef.current?.getBoundingClientRect();
      if (!rect) return;
      if (drag) {
        const next = { x: Math.max(16, drag.origin.x + (event.clientX - drag.start.x) / zoom), y: Math.max(16, drag.origin.y + (event.clientY - drag.start.y) / zoom) };
        if (drag.id.startsWith("SC-")) setScenes((items) => items.map((scene) => scene.id === drag.id ? { ...scene, position: next } : scene));
        else setAssets((items) => items.map((asset) => asset.id === drag.id ? { ...asset, position: next } : asset));
      }
      if (connect) setConnect((current) => current ? { ...current, point: { x: (event.clientX - rect.left) / zoom, y: (event.clientY - rect.top) / zoom } } : null);
    };
    const up = (event: PointerEvent) => {
      if (connect) {
        const target = document.elementFromPoint(event.clientX, event.clientY)?.closest<HTMLElement>("[data-node-id]")?.dataset.nodeId;
        const fromNode = nodeById(connect.from);
        const toNode = target ? nodeById(target) : undefined;
        if (fromNode && toNode && fromNode.kind !== toNode.kind) {
          const sceneId = fromNode.kind === "scene" ? fromNode.id : toNode.id;
          const assetId = fromNode.kind === "asset" ? fromNode.id : toNode.id;
          setRelations((items) => items.some((item) => item.sceneId === sceneId && item.assetId === assetId) ? items : [...items, { sceneId, assetId }]);
          setSelectedScene(sceneId);
          notify("资产关系已连接");
        }
      }
      setDrag(null);
      setConnect(null);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up, { once: true });
    return () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
  }, [drag, connect, nodeById, notify, zoom]);

  const startDrag = (event: ReactPointerEvent, id: string, position: Point) => {
    const target = event.target as HTMLElement;
    if (target.closest("button, select, [data-port]")) return;
    setSelectedNode(id);
    setDrag({ id, start: { x: event.clientX, y: event.clientY }, origin: position });
  };

  const startConnect = (event: ReactPointerEvent, id: string) => {
    event.preventDefault();
    event.stopPropagation();
    const rect = canvasWrapRef.current?.getBoundingClientRect();
    if (!rect) return;
    setConnect({ from: id, point: { x: (event.clientX - rect.left) / zoom, y: (event.clientY - rect.top) / zoom } });
  };

  const removeRelation = (sceneId: string, assetId: string) => {
    setRelations((items) => items.filter((item) => !(item.sceneId === sceneId && item.assetId === assetId)));
    notify("已解除关系，资产仍保留在库中");
  };

  const exportCsv = () => {
    const headers = ["record_type", "项目", "集数", "场次编号", "场景说明", "资产编号", "名称", "类型", "图片路径/链接", "审核状态", "备注", "复用等级", "画布X", "画布Y"];
    const rows: (string | number)[][] = [];
    scenes.forEach((scene) => rows.push(["scene", scene.project, scene.episode, scene.id, scene.description, "", "", "", "", "", "", "", Math.round(scene.position.x), Math.round(scene.position.y)]));
    assets.forEach((asset) => rows.push(["asset", "", "", "", "", asset.id, asset.name, asset.type, asset.image, asset.status, asset.note, asset.reuse, Math.round(asset.position.x), Math.round(asset.position.y)]));
    relations.forEach((relation) => rows.push(["relation", "", "", relation.sceneId, "", relation.assetId, "", "", "", "", "", "", "", ""]));
    const csv = `\uFEFF${[headers, ...rows].map((row) => row.map(csvEscape).join(",")).join("\n")}`;
    const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = `脚本资产审核台_${new Date().toISOString().slice(0, 10)}.csv`;
    link.click();
    URL.revokeObjectURL(url);
    notify("CSV 已导出，可直接用 Excel 打开");
  };

  const importCsv = async (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (!file) return;
    const records = parseCsv(await file.text().then((text) => text.replace(/^\uFEFF/, "")));
    const nextScenes: Scene[] = [];
    const nextAssets: Asset[] = [];
    const nextRelations: Relation[] = [];
    records.forEach((record, index) => {
      if (record.record_type === "scene") nextScenes.push({ id: record["场次编号"] || `SC-${index + 1}`, project: record["项目"] || "未命名项目", episode: record["集数"] || "第 1 集", description: record["场景说明"] || "待补充", position: { x: Number(record["画布X"]) || 64, y: Number(record["画布Y"]) || 80 + nextScenes.length * 210 } });
      if (record.record_type === "asset") nextAssets.push({ id: record["资产编号"] || `ASSET-${index + 1}`, name: record["名称"] || "未命名资产", type: typeOptions.includes(record["类型"] as AssetType) ? record["类型"] as AssetType : "道具", image: record["图片路径/链接"] || "", status: statusOptions.includes(record["审核状态"] as ReviewStatus) ? record["审核状态"] as ReviewStatus : "待确认", note: record["备注"] || "", reuse: (["S", "A", "B", "C"].includes(record["复用等级"]) ? record["复用等级"] : "B") as Asset["reuse"], position: { x: Number(record["画布X"]) || 520 + (nextAssets.length % 2) * 260, y: Number(record["画布Y"]) || 80 + Math.floor(nextAssets.length / 2) * 220 } });
      if (record.record_type === "relation" && record["场次编号"] && record["资产编号"]) nextRelations.push({ sceneId: record["场次编号"], assetId: record["资产编号"] });
    });
    if (!nextScenes.length && !nextAssets.length) return notify("未识别到资产审核台格式的数据");
    if (nextScenes.length) setScenes(nextScenes);
    if (nextAssets.length) setAssets(nextAssets);
    setRelations(nextRelations);
    setSelectedScene(nextScenes[0]?.id ?? "");
    setEdgeVersion((value) => value + 1);
    notify(`已导入 ${nextScenes.length} 个场次、${nextAssets.length} 项资产`);
    event.target.value = "";
  };

  const addAsset = () => {
    if (!draftAsset.name.trim()) return notify("请先填写资产名称");
    const prefix = draftAsset.type === "角色" ? "CHAR" : draftAsset.type === "场景" ? "ENV" : "PROP";
    const existing = assets.filter((asset) => asset.id.startsWith(prefix)).length + 1;
    const asset: Asset = { id: `${prefix}-${String(existing).padStart(3, "0")}`, ...draftAsset, status: "待确认", position: { x: 520 + (assets.length % 2) * 260, y: 90 + Math.floor(assets.length / 2) * 220 } };
    setAssets((items) => [...items, asset]);
    setDraftAsset({ name: "", type: "角色", image: "", note: "", reuse: "A" });
    setShowAddAsset(false);
    setView("canvas");
    notify("资产已加入待确认清单");
  };

  const ingestScript = () => {
    const lines = scriptText.split("\n").map((line) => line.trim()).filter(Boolean);
    const newScenes = [...scenes];
    const newAssets = [...assets];
    const newRelations = [...relations];
    lines.forEach((line, lineIndex) => {
      const [episode = "第 1 集", sceneIdRaw, description = "待补充", ...groups] = line.split("|").map((part) => part.trim());
      const sceneId = sceneIdRaw || `SC-${String(newScenes.length + 1).padStart(2, "0")}`;
      if (!newScenes.some((scene) => scene.id === sceneId)) newScenes.push({ id: sceneId, project: scenes[0]?.project || "未命名项目", episode, description, position: { x: 64, y: 90 + newScenes.length * 220 } });
      groups.forEach((group) => {
        const [label, names = ""] = group.split(":");
        const type: AssetType = label === "角色" ? "角色" : label === "场景" ? "场景" : "道具";
        names.split(/[，,、]/).map((name) => name.trim()).filter(Boolean).forEach((name) => {
          let asset = newAssets.find((item) => item.name === name && item.type === type);
          if (!asset) {
            const prefix = type === "角色" ? "CHAR" : type === "场景" ? "ENV" : "PROP";
            asset = { id: `${prefix}-${String(newAssets.filter((item) => item.type === type).length + 1).padStart(3, "0")}`, name, type, image: "", status: "待确认", note: "由脚本清单录入", reuse: type === "角色" ? "S" : "A", position: { x: 520 + (newAssets.length % 2) * 260, y: 90 + Math.floor(newAssets.length / 2) * 220 } };
            newAssets.push(asset);
          }
          if (!newRelations.some((item) => item.sceneId === sceneId && item.assetId === asset!.id)) newRelations.push({ sceneId, assetId: asset.id });
        });
      });
      if (lineIndex === 0) setSelectedScene(sceneId);
    });
    setScenes(newScenes);
    setAssets(newAssets);
    setRelations(newRelations);
    setShowEntry(false);
    setView("canvas");
    notify(`已从 ${lines.length} 行清单生成场次与资产关系`);
  };

  return (
    <main className="app-shell">
      <header className="topbar">
        <div className="brand-mark">帧</div>
        <div className="brand-copy"><strong>资产定帧</strong><span>视觉资产管理画布</span></div>
        <div className="project-pill"><span className="dot" />雾港来信 <span className="chevron">⌄</span></div>
        <div className="top-actions">
          <input ref={fileRef} type="file" accept=".csv,text/csv" hidden onChange={importCsv} />
          <button className="btn ghost" onClick={() => fileRef.current?.click()}>↥ 导入 CSV</button>
          <button className="btn primary" onClick={exportCsv}>↧ 导出到 Excel</button>
          <button className="icon-btn" aria-label="使用说明" onClick={() => setShowHelp(true)}>?</button>
        </div>
      </header>

      <section className="command-row">
        <div className="view-tabs">
          <button className={view === "canvas" ? "active" : ""} onClick={() => setView("canvas")}><span className="mini-grid" />关系画布</button>
          <button className={view === "table" ? "active" : ""} onClick={() => setView("table")}>≡ 资产表格</button>
        </div>
        <div className="filters">
          <select value={episodeFilter} onChange={(event) => setEpisodeFilter(event.target.value)}><option>全部集数</option>{episodes.map((episode) => <option key={episode}>{episode}</option>)}</select>
          <select value={typeFilter} onChange={(event) => setTypeFilter(event.target.value)}><option>全部类型</option>{typeOptions.map((type) => <option key={type}>{type}</option>)}</select>
          <select value={statusFilter} onChange={(event) => setStatusFilter(event.target.value)}><option>全部状态</option>{statusOptions.map((status) => <option key={status}>{status}</option>)}</select>
          <label className="search-box">⌕<input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="搜索资产编号、名称…" /></label>
        </div>
        <button className="btn warm" onClick={() => setShowEntry(true)}>＋ 批量录入资产</button>
        <button className="btn dark" onClick={() => setShowAddAsset(true)}>＋ 新增资产</button>
      </section>

      <section className="stats-row">
        <div><span>视觉资产</span><strong>{counts.total}</strong><small>项</small></div>
        <div><i className="metric-dot approved" /><span>已通过</span><strong>{counts.approved}</strong></div>
        <div><i className="metric-dot pending" /><span>待确认</span><strong>{counts.pending}</strong></div>
        <div><i className="metric-dot redo" /><span>需重做</span><strong>{counts.redo}</strong></div>
        <div><i className="metric-dot missing" /><span>暂缺</span><strong>{counts.missing}</strong></div>
        <p>拖动节点整理位置，从圆点拉线建立关系</p>
      </section>

      {view === "canvas" ? (
        <section className="workspace-grid">
          <aside className="asset-library">
            <div className="library-head"><span><small>ASSET LIBRARY</small><strong>视觉资产库</strong></span><button onClick={() => setShowAddAsset(true)}>＋</button></div>
            <div className="library-categories">
              <button className={typeFilter === "全部类型" ? "active" : ""} onClick={() => setTypeFilter("全部类型")}><span>▦</span>全部资产<b>{assets.length}</b></button>
              {typeOptions.map((type) => <button key={type} className={typeFilter === type ? "active" : ""} onClick={() => setTypeFilter(type)}><span>{type === "角色" ? "人" : type === "场景" ? "景" : "物"}</span>{type}资产<b>{assets.filter((asset) => asset.type === type).length}</b></button>)}
            </div>
            <div className="library-section-head"><strong>当前项目</strong><button onClick={() => setView("table")}>查看总表</button></div>
            <div className="library-list">
              {visibleAssets.map((asset) => <button key={asset.id} className={selectedNode === asset.id ? "active" : ""} onClick={() => setSelectedNode(asset.id)}><AssetVisual asset={asset} compact /><span><strong>{asset.name}</strong><small>{asset.id} · {asset.status}</small></span><i className={`tiny-state state-${asset.status}`} /></button>)}
            </div>
            <div className="library-foot"><span>CSV 为正式记录</span><small>本地草稿已自动保存</small></div>
          </aside>
          <div className="canvas-panel">
            <div className="canvas-toolbar">
              <span><b>场次资产关系</b><em>{visibleScenes.length} 个场次 · {visibleAssets.length} 项资产</em></span>
              <div><button onClick={() => setEdgeVersion((value) => value + 1)}>⊙ 适应画布</button><button onClick={() => setShowHelp(true)}>操作说明</button></div>
            </div>
            <div className="canvas-viewport" onPointerDown={() => setSelectedNode("")}>
            <div className="canvas-wrap" ref={canvasWrapRef} style={{ transform: `scale(${zoom})` }}>
              <canvas ref={edgeCanvasRef} className="edge-canvas" />
              <div className="canvas-label label-scenes">场次</div>
              <div className="canvas-label label-assets">视觉资产</div>
              {visibleScenes.map((scene) => (
                <article key={scene.id} data-node-id={scene.id} className={`scene-node ${selectedNode === scene.id ? "selected" : ""}`} style={{ transform: `translate(${scene.position.x}px, ${scene.position.y}px)` }} onPointerDown={(event) => { event.stopPropagation(); setSelectedScene(scene.id); startDrag(event, scene.id, scene.position); }}>
                  <div className="scene-index">{scene.id.replace("SC-", "")}</div>
                  <div className="scene-copy"><span>{scene.episode}</span><strong>{scene.description}</strong><small>{relations.filter((item) => item.sceneId === scene.id).length} 项资产已关联</small></div>
                  <button data-port className="port scene-port" aria-label="从场次拉线" onPointerDown={(event) => startConnect(event, scene.id)} />
                </article>
              ))}
              {visibleAssets.map((asset) => (
                <article key={asset.id} data-node-id={asset.id} className={`asset-node ${selectedNode === asset.id ? "selected" : ""}`} style={{ transform: `translate(${asset.position.x}px, ${asset.position.y}px)` }} onPointerDown={(event) => { event.stopPropagation(); startDrag(event, asset.id, asset.position); }}>
                  <button data-port className="port asset-port" aria-label="从资产拉线" onPointerDown={(event) => startConnect(event, asset.id)} />
                  <AssetVisual asset={asset} />
                  <div className="asset-node-copy">
                    <div><span className={`type-chip type-${asset.type}`}>{asset.type}</span><span className="reuse-chip">{asset.reuse}</span></div>
                    <strong>{asset.name}</strong><small>{asset.id}</small>
                    <select value={asset.status} className={`status-select status-${asset.status}`} onChange={(event) => updateAssetStatus(asset.id, event.target.value as ReviewStatus)}>{statusOptions.map((status) => <option key={status}>{status}</option>)}</select>
                  </div>
                </article>
              ))}
            </div>
            <div className="canvas-tools"><button className="active" title="选择工具">↖</button><button title="连线工具">⌁</button><span /><button onClick={() => setZoom((value) => Math.max(.65, +(value - .1).toFixed(2)))}>−</button><b>{Math.round(zoom * 100)}%</b><button onClick={() => setZoom((value) => Math.min(1.35, +(value + .1).toFixed(2)))}>＋</button><button onClick={() => setZoom(1)}>⊙</button></div>
            <div className="mini-map"><i /><i /><i /><i /><span /></div>
            </div>
          </div>

          <aside className="inspector">
            <div className="inspector-title"><span><small>当前场次</small><strong>{selectedScene}</strong></span><button onClick={() => setShowEntry(true)}>编辑</button></div>
            {(() => {
              const scene = scenes.find((item) => item.id === selectedScene);
              const sceneRelations = relations.filter((item) => item.sceneId === selectedScene);
              return <>
                <div className="scene-summary"><span>{scene?.episode || "未选择"}</span><strong>{scene?.description || "请选择一个场次"}</strong><small>{sceneRelations.length} 项视觉资产</small></div>
                <div className="check-head"><strong>本场资产</strong><span>{sceneRelations.filter((relation) => assets.find((asset) => asset.id === relation.assetId)?.status === "通过").length}/{sceneRelations.length} 已通过</span></div>
                <div className="check-list">
                  {sceneRelations.map((relation) => {
                    const asset = assets.find((item) => item.id === relation.assetId);
                    if (!asset) return null;
                    return <div className="check-item" key={asset.id}><AssetVisual asset={asset} compact /><div><strong>{asset.name}</strong><span>{asset.type} · {asset.id}</span><StatusBadge status={asset.status} /></div><button title="解除关系" onClick={() => removeRelation(selectedScene, asset.id)}>×</button></div>;
                  })}
                  {!sceneRelations.length && <div className="empty-state">从场次圆点拉线到资产，建立本场需要关系。</div>}
                </div>
                <button className="inspector-add" onClick={() => setShowAddAsset(true)}>＋ 添加新资产</button>
                <p className="safe-note">解除关系不会删除资产，只会从本场移除。</p>
              </>;
            })()}
          </aside>
        </section>
      ) : (
        <section className="table-panel">
          <div className="table-heading"><div><span className="eyebrow">ASSET REGISTER</span><h2>视觉资产总表</h2><p>状态、备注和图片路径会随 CSV 一起回到 Excel。</p></div><button className="btn dark" onClick={() => setShowAddAsset(true)}>＋ 新增资产</button></div>
          <div className="table-scroll"><table><thead><tr><th>资产</th><th>类型</th><th>复用级</th><th>关联场次</th><th>审核状态</th><th>图片路径 / 链接</th><th>备注</th></tr></thead><tbody>
            {visibleAssets.map((asset) => {
              const linked = relations.filter((relation) => relation.assetId === asset.id).map((relation) => relation.sceneId);
              return <tr key={asset.id}><td><div className="table-asset"><AssetVisual asset={asset} compact /><span><strong>{asset.name}</strong><small>{asset.id}</small></span></div></td><td><span className={`type-chip type-${asset.type}`}>{asset.type}</span></td><td><b className="grade">{asset.reuse}</b></td><td><div className="scene-tags">{linked.map((id) => <span key={id}>{id}</span>)}</div></td><td><select value={asset.status} className={`status-select status-${asset.status}`} onChange={(event) => updateAssetStatus(asset.id, event.target.value as ReviewStatus)}>{statusOptions.map((status) => <option key={status}>{status}</option>)}</select></td><td><span className="path-text">{asset.image || "尚未添加"}</span></td><td><span className="note-text">{asset.note || "—"}</span></td></tr>;
            })}
          </tbody></table></div>
        </section>
      )}

      <footer><span>本地草稿自动保存，正式记录请及时导出 CSV</span><span>资产定帧 · 个人制作版</span></footer>

      {showEntry && <div className="modal-backdrop" onMouseDown={() => setShowEntry(false)}><section className="modal wide" onMouseDown={(event) => event.stopPropagation()}><div className="modal-head"><div><span className="eyebrow">BULK ASSET ENTRY</span><h2>批量录入视觉资产</h2><p>一次录入某个资产组所需的角色、场景和道具；不生成图片。</p></div><button onClick={() => setShowEntry(false)}>×</button></div><label className="field"><span>资产清单</span><textarea value={scriptText} onChange={(event) => setScriptText(event.target.value)} rows={8} /></label><div className="syntax-card"><strong>填写格式</strong><code>集数 | 资产组编号 | 资产组名称 | 角色:名称1,名称2 | 场景:名称 | 道具:名称</code><small>示例：第 3 集 | SC-04 | 灯塔资产组 | 角色:林默,陌生女孩 | 场景:灯塔内部 | 道具:旧钥匙</small></div><div className="modal-actions"><button className="btn ghost" onClick={() => setShowEntry(false)}>取消</button><button className="btn primary" onClick={ingestScript}>加入资产画布</button></div></section></div>}

      {showAddAsset && <div className="modal-backdrop" onMouseDown={() => setShowAddAsset(false)}><section className="modal" onMouseDown={(event) => event.stopPropagation()}><div className="modal-head"><div><span className="eyebrow">NEW ASSET</span><h2>新增视觉资产</h2><p>仅录入角色、场景或道具。</p></div><button onClick={() => setShowAddAsset(false)}>×</button></div><div className="form-grid"><label className="field full"><span>资产名称</span><input autoFocus value={draftAsset.name} onChange={(event) => setDraftAsset((value) => ({ ...value, name: event.target.value }))} placeholder="例如：林默 · 雨夜造型" /></label><label className="field"><span>资产类型</span><select value={draftAsset.type} onChange={(event) => setDraftAsset((value) => ({ ...value, type: event.target.value as AssetType }))}>{typeOptions.map((type) => <option key={type}>{type}</option>)}</select></label><label className="field"><span>复用等级</span><select value={draftAsset.reuse} onChange={(event) => setDraftAsset((value) => ({ ...value, reuse: event.target.value as Asset["reuse"] }))}>{["S", "A", "B", "C"].map((grade) => <option key={grade}>{grade}</option>)}</select></label><label className="field full"><span>图片路径 / 链接</span><input value={draftAsset.image} onChange={(event) => setDraftAsset((value) => ({ ...value, image: event.target.value }))} placeholder="https://… 或本地文件路径" /></label><label className="field full"><span>备注</span><textarea rows={3} value={draftAsset.note} onChange={(event) => setDraftAsset((value) => ({ ...value, note: event.target.value }))} placeholder="需要确认的细节" /></label></div><div className="modal-actions"><button className="btn ghost" onClick={() => setShowAddAsset(false)}>取消</button><button className="btn primary" onClick={addAsset}>加入待确认</button></div></section></div>}

      {showHelp && <div className="modal-backdrop" onMouseDown={() => setShowHelp(false)}><section className="modal help-modal" onMouseDown={(event) => event.stopPropagation()}><div className="modal-head"><div><span className="eyebrow">QUICK GUIDE</span><h2>三步管理视觉资产</h2></div><button onClick={() => setShowHelp(false)}>×</button></div><ol className="help-list"><li><b>1</b><div><strong>录入资产</strong><p>添加角色、场景、道具，或批量录入一个资产组。</p></div></li><li><b>2</b><div><strong>拖拽与拉线</strong><p>像节点画布一样整理位置；从圆点拖到另一类节点建立关系。</p></div></li><li><b>3</b><div><strong>确认并导出</strong><p>标记通过、重做或暂缺，再导出 CSV 回到 Excel。</p></div></li></ol><button className="btn primary full-button" onClick={() => setShowHelp(false)}>明白了</button></section></div>}

      {toast && <div className="toast"><span>✓</span>{toast}</div>}
    </main>
  );
}
