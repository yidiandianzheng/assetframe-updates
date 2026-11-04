#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把分类结果渲染成可点选的核验页（单文件 HTML，无外部依赖）。

用途：在改 App 之前，先确认「品牌 / 茶类 / 产品线 / 机位 / 图类型 / 比例 / 验收」
这些徽标和筛选组合的结果是否与截图一致。数据全部内嵌，直接双击打开即可。

用法：python3 图库分类/build_preview.py
"""

from __future__ import annotations

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
RESULT = os.path.join(HERE, "输出", "分类结果.json")
TARGET = os.path.join(HERE, "预览.html")

FACETS = [
    ("brand", "品牌"),
    ("tea_type", "茶类"),
    ("usage", "用途"),
    ("asset_kind", "图类型"),
    ("ratio", "比例"),
    ("acceptance", "验收"),
    ("organize_status", "状态"),
]


def main() -> int:
    with open(RESULT, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    records = [record for record in data["records"] if record["scope"] == "产品图"]
    slim = [
        {
            "n": record["name"],
            "p": record["path"],
            "b": record["brand"],
            "t": record["tea_type"],
            "l": record["product_line"],
            "s": record["shot"],
            "k": record["asset_kind"],
            "u": record["usage"],
            "r": record["ratio"],
            "a": record["acceptance"],
            "o": record["organize_status"],
        }
        for record in records
    ]

    html = PAGE.replace("__DATA__", json.dumps(slim, ensure_ascii=False))
    html = html.replace("__TOTAL__", str(len(slim)))
    with open(TARGET, "w", encoding="utf-8") as handle:
        handle.write(html)
    print(f"已生成 {TARGET}，产品图 {len(slim)} 张")
    return 0


PAGE = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>产品图库 · 分类核验</title>
<style>
  :root{--bg:#faf9f6;--card:#fff;--line:#e6e2d9;--ink:#1f1d1a;--muted:#6f6a60;--accent:#1d6b52;--accent-soft:#e8f2ee;--warn:#8a5a00;--warn-soft:#fbf0d9}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.55 -apple-system,"PingFang SC","Helvetica Neue",sans-serif}
  header{padding:18px 28px 14px;border-bottom:1px solid var(--line);background:#fff}
  h1{margin:0 0 4px;font-size:19px;font-weight:600;letter-spacing:.2px}
  .sub{color:var(--muted);font-size:12.5px}
  .bar{display:flex;gap:10px;align-items:center;padding:14px 28px;background:#fff;border-bottom:1px solid var(--line);position:sticky;top:0;z-index:5}
  .search{flex:1;display:flex;gap:8px}
  .search input{flex:1;padding:9px 12px;border:1px solid var(--line);border-radius:8px;font-size:13px;background:var(--bg)}
  .search input:focus{outline:2px solid var(--accent-soft);border-color:var(--accent)}
  button{font:inherit;cursor:pointer;border-radius:8px;border:1px solid var(--line);background:#fff;padding:7px 12px;color:var(--ink)}
  button:hover{border-color:#c9c2b4}
  .btn{background:var(--accent);border-color:var(--accent);color:#fff}
  .btn.ghost{background:#fff;color:var(--ink)}
  main{padding:16px 28px 60px}
  .facet{display:flex;gap:10px;align-items:flex-start;padding:9px 0;border-bottom:1px dashed var(--line)}
  .facet .label{width:64px;flex:none;color:var(--muted);font-size:12.5px;padding-top:5px}
  .chips{display:flex;flex-wrap:wrap;gap:7px}
  .chip{border:1px solid var(--line);background:#fff;border-radius:7px;padding:5px 10px;font-size:12.5px;color:#3d3a34}
  .chip b{font-weight:500;color:var(--muted);margin-left:5px;font-size:11.5px}
  .chip.on{background:var(--accent-soft);border-color:var(--accent);color:var(--accent);font-weight:500}
  .chip.on b{color:var(--accent)}
  .meta{display:flex;justify-content:space-between;align-items:center;margin:16px 0 12px;color:var(--muted);font-size:12.5px}
  .meta strong{color:var(--ink);font-weight:600}
  .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(212px,1fr));gap:16px}
  .card{background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden;display:flex;flex-direction:column}
  .thumb{height:150px;background:#f2efe8;display:flex;align-items:center;justify-content:center;overflow:hidden;position:relative}
  .thumb img{width:100%;height:100%;object-fit:cover;display:block}
  .thumb .ph{color:#b3ac9d;font-size:12px;padding:0 10px;text-align:center}
  .thumb:empty::after{content:attr(data-k);color:#b3ac9d;font-size:12px}
  .card-body{padding:9px 10px 11px;display:flex;flex-direction:column;gap:6px}
  .name{font-size:12.5px;line-height:1.45;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;min-height:36px}
  .tags{display:flex;flex-wrap:wrap;gap:4px}
  .tag{font-size:10.5px;padding:2px 6px;border-radius:5px;background:#f4f1ea;color:#5d574c;white-space:nowrap}
  .tag.brand{background:var(--accent-soft);color:var(--accent)}
  .tag.tea{background:#fbf0d9;color:#8a5a00}
  .tag.shot{background:#eef1f7;color:#3b5170}
  .tag.ok{background:#e8f2ee;color:#1d6b52}
  .tag.todo{background:#f7ece8;color:#a2462c}
  .empty{padding:60px 0;text-align:center;color:var(--muted)}
  .note{margin-top:18px;padding:12px 14px;background:#fff;border:1px solid var(--line);border-radius:9px;color:var(--muted);font-size:12px;line-height:1.7}
</style>
</head>
<body>
<header>
  <h1>产品图库 · 分类核验</h1>
  <div class="sub">按品牌、茶类、用途和关键词查找图片；卡片显示完整徽标（品牌 / 茶类 / 产品线 / 机位 / 图类型 / 比例 / 验收 / 整理状态）</div>
</header>

<div class="bar">
  <div class="search">
    <input id="q" placeholder="搜索商品、品牌、规格、图片标题或关键词">
    <button class="btn" onclick="render()">搜索</button>
  </div>
  <button class="ghost" onclick="reset()">清空条件</button>
</div>

<main>
  <div id="facets"></div>
  <div class="meta"><span>匹配 <strong id="count">0</strong> 张素材，涉及 <strong id="lines">0</strong> 款产品线</span><span id="hint"></span></div>
  <div class="grid" id="grid"></div>
  <div class="note">
    本页数据来自 <code>图库分类/输出/分类结果.json</code>，只读渲染，不写库、不改原图。
    分类为规则判定（文件名 + 目录 + 产品名称映射表），「未识别」表示现有命名里没有品牌线索，需要补标签，不是识别失败。
  </div>
</main>

<script>
const DATA = __DATA__;
const TOTAL = __TOTAL__;
const FACETS = [["b","品牌"],["t","茶类"],["u","用途"],["k","图类型"],["r","比例"],["a","验收"],["o","状态"]];
const state = {b:new Set(),t:new Set(),u:new Set(),k:new Set(),r:new Set(),a:new Set(),o:new Set(),q:""};

function countBy(key){const m=new Map();DATA.forEach(d=>m.set(d[key],(m.get(d[key])||0)+1));return [...m.entries()].sort((x,y)=>y[1]-x[1]);}

function buildFacets(){
  const host=document.getElementById("facets");
  host.innerHTML=FACETS.map(([key,label])=>{
    const items=countBy(key).slice(0,9).map(([val,n])=>{
      const on=state[key].has(val)?" on":"";
      return `<button class="chip${on}" onclick="toggle('${key}',${JSON.stringify(val).replace(/"/g,'&quot;')})">${val}<b>${n}</b></button>`;
    }).join("");
    return `<div class="facet"><div class="label">${label}</div><div class="chips"><button class="chip${state[key].size?"":" on"}" onclick="clearFacet('${key}')">全部</button>${items}</div></div>`;
  }).join("");
}

function toggle(key,val){
  const set=state[key];
  if(set.has(val))set.delete(val);else set.add(val);
  buildFacets();render();
}
function clearFacet(key){state[key].clear();buildFacets();render();}
function reset(){Object.keys(state).forEach(k=>k==="q"?(state.q=""):state[k].clear());document.getElementById("q").value="";buildFacets();render();}

function match(d){
  for(const [key] of FACETS){const set=state[key];if(set.size&&!set.has(d[key]))return false;}
  if(state.q){
    const text=(d.n+" "+d.b+" "+d.t+" "+d.l+" "+d.k+" "+d.u+" "+d.s).toLowerCase();
    if(!text.includes(state.q.toLowerCase()))return false;
  }
  return true;
}

function tag(cls,text){return `<span class="tag ${cls}">${esc(text)}</span>`;}

function esc(v){return String(v==null?"":v).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");}

function render(){
  state.q=document.getElementById("q").value.trim();
  const rows=DATA.filter(match);
  document.getElementById("count").textContent=rows.length;
  document.getElementById("lines").textContent=new Set(rows.map(d=>d.l).filter(v=>v!=="未归类")).size;
  document.getElementById("hint").textContent="共 "+TOTAL+" 张产品图";
  document.getElementById("grid").innerHTML=rows.length?rows.map(d=>{
    const tags=[
      d.b!=="未识别"?tag("brand",d.b):tag("todo","品牌待补"),
      d.t!=="未分类"?tag("tea",d.t):tag("todo","茶类待补"),
      d.l!=="未归类"?tag("",d.l):"",
      d.s!=="未标注"?tag("shot",d.s):"",
      tag("",d.k), tag("",d.r), tag("",d.u),
      d.a!=="待核"?tag("",d.a):tag("todo","验收待核"),
      tag(d.o==="可用"?"ok":"todo",d.o)
    ].join("");
    return `<article class="card"><div class="thumb" data-k="${esc(d.k)}"><img loading="lazy" src="file://${esc(d.p)}" alt="" onerror="this.remove()"></div><div class="card-body"><div class="name" title="${esc(d.n)}">${esc(d.n)}</div><div class="tags">${tags}</div></div></article>`;
  }).join(""):`<div class="empty">没有匹配的素材，试试清空条件</div>`;
}

buildFacets();render();
document.getElementById("q").addEventListener("input",render);
</script>
</body>
</html>
"""


if __name__ == "__main__":
    raise SystemExit(main())
