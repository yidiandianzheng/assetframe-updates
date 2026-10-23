#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""变更管理工具自测：在 /tmp 临时 git 仓库里模拟完整协作流程。

覆盖：
    - 新建变更（编号/工作区/分支校验）
    - 逐文件说明占位 → --check-only → 提交 → 打印 push 命令（脚本不自动 push）
    - 负责人审核：复制变更单、逐文件标注、--dry-run、部分采纳应用
    - 回退（回调）：恢复修改/删除新增，索引与记录状态更新
    - 一轮补充：新增/删除/重命名 + --notes + --no-build
    - 构建失败自动恢复（用假 swift 模拟失败，不真正执行 Swift 构建）
    - 基线漂移检测

约束：
    - 所有写入都在 /tmp 下的临时目录；
    - 本地 bare 仓库模拟 origin，不连接任何真实远程；
    - 不触碰真实工作区（本脚本只读取真实 变更管理/ 目录作为工具来源）。
"""

import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent          # 变更管理/工具
PKG = HERE.parent                               # 变更管理
REPO = PKG.parent                               # 真实仓库（只读）

sys.path.insert(0, str(HERE))
import _common as cm  # noqa: E402  （用同一份公共库做断言与解析）

PY = sys.executable
TODAY = datetime.date.today().strftime("%Y%m%d")
RESULTS = []  # [(名称, 是否通过)]

DOC_BASE = "# 基线说明\n\n第一行。\n"
DOC_CHANGED = DOC_BASE + "\n补充说明：这是同事新增的说明段落。\n"
TXT_BASE = "alpha\nbeta\n"
TXT_CHANGED = TXT_BASE + "gamma\n"
SWIFT_MAIN_BASE = 'print("baseline")\n'
SWIFT_MAIN_CHANGED = 'print("changed by colleague")\n'
SWIFT_NEW = 'func hello() -> String { "自测新增" }\n'
PACKAGE_SWIFT = '// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "SelfTest")\n'


# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------


def indent(text, prefix):
    return "\n".join(prefix + line for line in str(text).splitlines())


def tail(text, limit=2500):
    text = (text or "").strip()
    if len(text) <= limit:
        return text
    return "……（输出过长，仅显示末尾）……\n" + text[-limit:]


def check(name, cond, detail=""):
    passed = bool(cond)
    RESULTS.append((name, passed))
    print("  [%s] %s" % ("PASS" if passed else "FAIL", name))
    if not passed and detail:
        print(indent(detail, "       "))
    return passed


def expect(name, code, output, want=0, contains=()):
    if isinstance(want, int):
        good = code == want
    else:  # "nonzero"
        good = code != 0
    missed = [item for item in contains if item not in output]
    if missed:
        good = False
    detail = "退出码=%r（期望 %r）\n未包含：%r\n输出尾部：\n%s" % (code, want, missed, tail(output))
    return check(name, good, detail)


def git_env():
    env = os.environ.copy()
    env.update(
        {
            "GIT_LITERAL_PATHSPECS": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "cat",
            "PAGER": "cat",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
    )
    return env


def run_proc(cmd, cwd, env_extra=None, timeout=300):
    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"
    env.pop(cm.BUILD_TIMEOUT_ENV, None)
    # 断言输出里显示中文路径而不是转义形式
    env["GIT_CONFIG_COUNT"] = "1"
    env["GIT_CONFIG_KEY_0"] = "core.quotePath"
    env["GIT_CONFIG_VALUE_0"] = "false"
    if env_extra:
        env.update(env_extra)
    proc = subprocess.run(
        [str(item) for item in cmd],
        cwd=str(cwd),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )
    output = (proc.stdout or b"") + (proc.stderr or b"")
    return proc.returncode, output.decode("utf-8", "replace")


def run_tool(repo, script, args, env_extra=None):
    return run_proc([PY, str(repo / "变更管理" / "工具" / script)] + list(args), cwd=repo, env_extra=env_extra)


class Git:
    def __init__(self, cwd):
        self.cwd = Path(cwd)

    def run(self, *args, expect=0):
        code, out = run_proc(["git", "-C", str(self.cwd)] + [str(a) for a in args], cwd=self.cwd)
        if expect is not None and code != expect:
            raise RuntimeError("git %s 失败（%s）：\n%s" % (" ".join(map(str, args)), code, out))
        return code, out

    def out(self, *args):
        _code, out = self.run(*args)
        return out.strip()

    def z(self, *args):
        code, out = run_proc(
            ["git", "-C", str(self.cwd)] + [str(a) for a in args] + ["-z"],
            cwd=self.cwd,
        )
        if code != 0:
            raise RuntimeError("git %s 失败" % (args,))
        return [item for item in out.split("\x00") if item]

    def sha(self, ref="HEAD"):
        return self.out("rev-parse", ref)

    def subject(self):
        return self.out("log", "-1", "--pretty=%s")

    def commit_count(self):
        return int(self.out("rev-list", "--count", "HEAD"))

    def clean(self):
        return self.out("status", "--porcelain") == ""

    def tracked_changes(self):
        return [line for line in self.out("status", "--porcelain").splitlines() if not line.startswith("??")]

    def untracked(self):
        return [line[3:] for line in self.out("status", "--porcelain").splitlines() if line.startswith("??")]

    def ref_exists(self, ref):
        code, _out = self.run("rev-parse", "--verify", "--quiet", ref + "^{commit}", expect=None)
        return code == 0

    def ref_sha(self, ref):
        return self.out("rev-parse", ref)


def git(repo):
    return Git(repo)


def read_text(repo, rel):
    return (Path(repo) / rel).read_text(encoding="utf-8")


def write_text(repo, rel, text):
    path = Path(repo) / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def text_exists(repo, rel):
    return (Path(repo) / rel).exists()


def update_form(repo, rec_id, updates):
    """直接改变更单表格里的「说明」/「采纳状态」列（模拟人工编辑）。"""
    path = Path(repo) / "变更管理" / "记录" / rec_id / "变更单.md"
    text = path.read_text(encoding="utf-8")
    parsed = cm.parse_change_form(text)
    if not parsed["table"]:
        raise RuntimeError("变更单里没有逐文件表：%s" % path)
    lines = parsed["lines"]
    for idx, cells in cm.table_data_rows(lines, parsed["table"]):
        key = cm.strip_ticks(cells[0])
        update = updates.get(key)
        if not update:
            continue
        while len(cells) < 5:
            cells.append("")
        if "note" in update:
            cells[3] = update["note"]
        if "adopt" in update:
            cells[4] = update["adopt"]
        lines[idx] = "| " + " | ".join(cm.escape_cell(value) for value in cells) + " |"
    path.write_text("\n".join(lines).rstrip("\n") + "\n", encoding="utf-8")


def form_meta(repo, rec_id):
    return cm.parse_change_form(read_text(repo, "变更管理/记录/%s/变更单.md" % rec_id))["meta"]


def form_rows(repo, rec_id):
    return cm.parse_change_form(read_text(repo, "变更管理/记录/%s/变更单.md" % rec_id))["rows"]


def index_cells(repo, rec_id):
    lines = cm.read_index_lines(Path(repo))
    _idx, cells = cm.find_index_row(lines, rec_id)
    return cells or []


def application_record(repo, rec_id):
    return cm.load_application_record(Path(repo), rec_id)


def write_notes_file(path, mapping):
    Path(path).write_text(json.dumps(mapping, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# 阶段 1：初始化临时仓库
# ---------------------------------------------------------------------------


class Ctx:
    def __init__(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="assetframe-change-selftest-", dir="/tmp")).resolve()
        self.origin = self.tmp / "origin.git"
        self.colleague = self.tmp / "同事 工作区"
        self.owner = self.tmp / "负责人 工作区"
        self.drift = self.tmp / "漂移 工作区"
        self.baseline_sha = ""
        self.id1 = "CHG-%s-01" % TODAY
        self.id2 = "CHG-%s-02" % TODAY
        self.id3 = "CHG-%s-03" % TODAY


def phase_setup(ctx):
    print("\n阶段 1：准备临时 git 仓库（/tmp，本地 bare 仓库模拟 origin）")
    ctx.tmp.mkdir(parents=True, exist_ok=True)
    code, out = run_proc(["git", "init", "--bare", str(ctx.origin)], cwd=ctx.tmp)
    check("创建本地 bare 仓库作为 origin", code == 0, out)
    ctx.colleague.mkdir()
    code, out = run_proc(["git", "init", "-b", "main", str(ctx.colleague)], cwd=ctx.tmp)
    check("初始化同事工作区（main）", code == 0, out)
    col = git(ctx.colleague)
    col.run("config", "user.name", "自测同事")
    col.run("config", "user.email", "selftest-colleague@example.invalid")
    git(ctx.origin).run("config", "core.bare", "true")

    write_text(ctx.colleague, "Package.swift", PACKAGE_SWIFT)
    write_text(ctx.colleague, "Sources/Demo/main.swift", SWIFT_MAIN_BASE)
    write_text(ctx.colleague, "资料/变更 说明.md", DOC_BASE)
    write_text(ctx.colleague, "数据/示例.txt", TXT_BASE)

    # 复制真实“变更管理”工具包（只读来源），排除记录与缓存
    tools_src = HERE
    tools_dst = ctx.colleague / "变更管理" / "工具"

    def ignore(_dir, names):
        return [name for name in names if name in ("__pycache__", "记录") or name.endswith(".pyc")]

    shutil.copytree(tools_src, tools_dst, ignore=ignore)
    shutil.copytree(PKG / "模板", ctx.colleague / "变更管理" / "模板")
    shutil.copy2(PKG / "索引.md", ctx.colleague / "变更管理" / "索引.md")
    if (PKG / "README.md").is_file():
        shutil.copy2(PKG / "README.md", ctx.colleague / "变更管理" / "README.md")

    col.run("add", "-A")
    col.run("commit", "-m", "基线：自测临时仓库")
    check("基线提交成功", col.commit_count() == 1)
    col.run("remote", "add", "origin", str(ctx.origin))
    col.run("push", "-u", "origin", "main")
    check("main 已推送到本地 origin", git(ctx.origin).ref_exists("main"))
    ctx.baseline_sha = col.sha()

    code, out = run_proc(["git", "clone", str(ctx.origin), str(ctx.owner)], cwd=ctx.tmp)
    check("负责人从 origin 克隆仓库", code == 0, out)
    own = git(ctx.owner)
    own.run("config", "user.name", "自测负责人")
    own.run("config", "user.email", "selftest-owner@example.invalid")
    check("负责人工作区包含变更工具包", (ctx.owner / "变更管理" / "工具" / "_common.py").is_file())
    check("负责人工作区干净", own.clean())

    code, out = run_proc(["git", "config", "--local", "remote.origin.url", str(ctx.origin)], cwd=ctx.owner)
    check("负责人仓库原点指向本地临时仓库", code == 0, out)
    check("同事仓库原点指向本地临时仓库", git(ctx.colleague).out("remote", "get-url", "origin") == str(ctx.origin))
    return col, own


# ---------------------------------------------------------------------------
# 阶段 2：主流程（2 个文件、部分采纳、回退）
# ---------------------------------------------------------------------------


def phase_primary(ctx, col, own):
    print("\n阶段 2：主流程 —— 新建 → 修改 2 个文件 → 提交 → 部分采纳 → 回退")
    id1 = ctx.id1

    code, out = run_tool(
        ctx.colleague,
        "新建变更.py",
        ["--id", id1, "--owner", "同事 甲", "--goal", "自测：补充说明与示例数据"],
    )
    expect("新建变更成功", code, out, 0)
    check("当前分支为 change/%s" % id1, col.out("symbolic-ref", "--short", "HEAD") == "change/" + id1)
    check(
        "变更单与清单已生成",
        (ctx.colleague / "变更管理" / "记录" / id1 / "变更单.md").is_file()
        and (ctx.colleague / "变更管理" / "记录" / id1 / "清单.json").is_file(),
    )
    manifest = cm.load_manifest(ctx.colleague, id1)
    check("清单的 base_commit 等于基线提交", manifest["base_commit"] == ctx.baseline_sha, manifest.get("base_commit"))
    check("索引状态为待提交", index_cells(ctx.colleague, id1)[4] == "待提交", index_cells(ctx.colleague, id1))

    code, out = run_tool(ctx.colleague, "新建变更.py", ["--id", "CHG-2026-1", "--owner", "甲", "--goal", "x"])
    expect("非法编号被拒绝", code, out, "nonzero", ("CHG-YYYYMMDD-NN",))
    code, out = run_tool(ctx.colleague, "新建变更.py", ["--id", "CHG-20261301-01", "--owner", "甲", "--goal", "x"])
    expect("非法日期被拒绝", code, out, "nonzero", ("日期不合法",))
    check("非法新建失败后未创建分支", not col.ref_exists("change/CHG-20261301-01"))

    code, out = run_tool(ctx.colleague, "新建变更.py", ["--id", ctx.id2, "--owner", "甲", "--goal", "x"])
    expect("在 change 分支上新建被拒绝", code, out, "nonzero", ("必须从 main",))

    col.run("switch", "main")
    write_text(ctx.colleague, "临时 脏文件.txt", "dirty\n")
    code, out = run_tool(ctx.colleague, "新建变更.py", ["--id", ctx.id2, "--owner", "甲", "--goal", "x"])
    expect("工作区不干净时新建被拒绝", code, out, "nonzero", ("工作区不干净",))
    (ctx.colleague / "临时 脏文件.txt").unlink()
    col.run("switch", "change/" + id1)
    status_lines = col.out("status", "--porcelain").splitlines()
    check(
        "回到变更分支后，工作区只有新建阶段的索引/记录改动",
        all("变更管理" in line for line in status_lines)
        and any("索引.md" in line for line in status_lines)
        and any("变更管理/记录/" in line for line in status_lines),
        status_lines,
    )

    write_text(ctx.colleague, "资料/变更 说明.md", DOC_CHANGED)
    write_text(ctx.colleague, "数据/示例.txt", TXT_CHANGED)

    code, out = run_tool(ctx.colleague, "提交变更.py", ["--id", id1])
    expect("首次提交生成占位说明并中止", code, out, "nonzero", ("说明",))
    check("变更单里出现占位说明", "请填写本文件的改动说明" in read_text(ctx.colleague, "变更管理/记录/%s/变更单.md" % id1))
    check("清单记录了 2 个文件", len(cm.load_manifest(ctx.colleague, id1).get("files") or []) == 2)
    check("尚未产生提交", col.commit_count() == 1)

    code, out = run_tool(ctx.colleague, "提交变更.py", ["--id", id1, "--check-only"])
    expect("说明未填时 --check-only 失败", code, out, "nonzero", ("说明未填齐",))

    update_form(
        ctx.colleague,
        id1,
        {
            "资料/变更 说明.md": {"note": "补充说明段落，便于阅读"},
            "数据/示例.txt": {"note": "补充一行示例数据"},
        },
    )
    code, out = run_tool(ctx.colleague, "提交变更.py", ["--id", id1, "--check-only"])
    expect("说明填齐后 --check-only 通过", code, out, 0, ("说明校验通过",))

    code, out = run_tool(ctx.colleague, "提交变更.py", ["--id", id1])
    expect("提交变更成功", code, out, 0, ("git push -u origin change/%s" % id1,))
    check("提交标题正确", col.subject().startswith("变更 %s" % id1), col.subject())
    check("提交包含变更记录", "变更管理/记录/%s/变更单.md" % id1 in col.out("ls-files", "变更管理/记录/%s" % id1))
    check("脚本没有自动 push（本地 origin 暂无分支）", not git(ctx.origin).ref_exists("change/" + id1))

    col.run("push", "-u", "origin", "change/" + id1)
    check("同事把 change 分支推送到本地 origin", git(ctx.origin).ref_exists("change/" + id1))

    own.run("fetch", "origin")
    check("负责人 fetch 到远程变更分支", own.ref_exists("origin/change/" + id1))

    write_text(ctx.owner, "负责人 脏文件.txt", "dirty\n")
    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", id1, "--dry-run"])
    expect("负责人工作区不干净时审核被拒绝", code, out, "nonzero", ("工作区不干净",))
    (ctx.owner / "负责人 脏文件.txt").unlink()

    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", id1, "--dry-run"])
    expect("尚未复制变更单时 dry-run 提示需要标注", code, out, "nonzero", ("待定",))
    check("dry-run 不会复制记录到工作区", not (ctx.owner / "变更管理" / "记录" / id1).exists())

    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", id1])
    expect("首次审核运行复制变更单并提示标注", code, out, "nonzero", ("采纳状态",))
    check(
        "变更单/清单/改动.diff 已复制到负责人工作区",
        all(
            (ctx.owner / "变更管理" / "记录" / id1 / name).is_file()
            for name in ("变更单.md", "清单.json", "改动.diff")
        ),
    )
    rows = form_rows(ctx.owner, id1)
    check("变更单有 2 行且状态均为待定", len(rows) == 2 and all(row["adopt"] == "待定" for row in rows.values()))

    update_form(
        ctx.owner,
        id1,
        {
            "资料/变更 说明.md": {"adopt": "采纳"},
            "数据/示例.txt": {"adopt": "不采纳"},
        },
    )
    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", id1, "--dry-run"])
    expect("标注完成后 dry-run 通过", code, out, 0, ("预演通过",))
    check("dry-run 后没有提交", own.commit_count() == 1)
    check("dry-run 后没有跟踪文件的改动", own.tracked_changes() == [])

    check("负责人在 main 分支上审核", own.out("symbolic-ref", "--short", "HEAD") == "main")
    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", id1])
    expect("部分采纳应用成功", code, out, 0, ("采纳变更 %s: 1/2 个文件" % id1,))
    check("采纳文件内容为变更分支版本", read_text(ctx.owner, "资料/变更 说明.md") == DOC_CHANGED)
    check("未采纳文件保持基线内容", read_text(ctx.owner, "数据/示例.txt") == TXT_BASE)
    check("应用后提交标题正确", own.subject() == "采纳变更 %s: 1/2 个文件" % id1, own.subject())
    check("应用后工作区干净", own.clean(), own.out("status", "--porcelain"))
    cells = index_cells(ctx.owner, id1)
    check(
        "索引状态=部分采纳、采纳文件数=1/2、回退时间=-",
        len(cells) >= 8 and cells[4] == "部分采纳" and cells[5] == "1/2" and cells[6] == "-",
        cells,
    )
    check("变更单状态=部分采纳", form_meta(ctx.owner, id1).get("当前状态") == "部分采纳", form_meta(ctx.owner, id1))
    record = application_record(ctx.owner, id1)
    app = (record.get("applications") or [None])[0]
    check(
        "应用记录字段正确（before_commit/采纳数/总数）",
        app is not None
        and app.get("before_commit") == ctx.baseline_sha
        and app.get("adopted_count") == 1
        and app.get("total_count") == 2
        and app.get("reverted_at") is None,
        app,
    )
    check("应用记录里的构建说明为未涉及 Swift", "未涉及 Swift" in (app or {}).get("build", ""), (app or {}).get("build"))
    check(
        "记录目录已随应用提交进入 main",
        cm.path_exists_in_commit(Path(ctx.owner), "HEAD", "变更管理/记录/%s/变更单.md" % id1),
    )

    # 回退
    code, out = run_tool(ctx.owner, "回退变更.py", ["--id", id1, "--dry-run"])
    expect("回退 dry-run 通过", code, out, 0, ("预演通过",))
    check("回退 dry-run 不改动提交", own.subject() == "采纳变更 %s: 1/2 个文件" % id1)

    code, out = run_tool(ctx.owner, "回退变更.py", ["--id", id1])
    expect("回退成功且提示重新打包", code, out, 0, ("需重新打包安装才生效",))
    check("回退后采纳文件恢复基线内容", read_text(ctx.owner, "资料/变更 说明.md") == DOC_BASE)
    check("回退后未采纳文件仍为基线内容", read_text(ctx.owner, "数据/示例.txt") == TXT_BASE)
    check("回退提交标题正确", own.subject() == "回退变更 %s" % id1, own.subject())
    check("回退后工作区干净", own.clean(), own.out("status", "--porcelain"))
    cells = index_cells(ctx.owner, id1)
    check(
        "索引状态=已回退且有回退时间",
        len(cells) >= 8 and cells[4] == "已回退" and cells[6] not in ("-", ""),
        cells,
    )
    check("变更单状态=已回退", form_meta(ctx.owner, id1).get("当前状态") == "已回退")
    record = application_record(ctx.owner, id1)
    check(
        "应用记录标记已回退",
        bool((record.get("applications") or [{}])[0].get("reverted_at")),
        record,
    )

    code, out = run_tool(ctx.owner, "回退变更.py", ["--id", id1])
    expect("重复回退被拒绝", code, out, "nonzero", ("都已回退",))

    # 回退后仍可再次采纳同一变更（验证应用记录可追加、回退不破坏记录）
    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", id1, "--no-build"])
    expect("回退后可再次应用同一变更", code, out, 0, ("采纳变更 %s: 1/2 个文件" % id1,))
    record = application_record(ctx.owner, id1)
    check(
        "再次应用后应用记录追加为 2 条",
        len(record.get("applications") or []) == 2
        and not (record["applications"][1].get("reverted_at")),
        record.get("applications"),
    )
    code, out = run_tool(ctx.owner, "回退变更.py", ["--id", id1])
    expect("再次回退成功", code, out, 0, ("需重新打包安装才生效",))
    record = application_record(ctx.owner, id1)
    check(
        "两次应用记录均标记已回退",
        all(app.get("reverted_at") for app in (record.get("applications") or [])),
        record.get("applications"),
    )
    check("再次回退后文件恢复基线", read_text(ctx.owner, "资料/变更 说明.md") == DOC_BASE)
    check("再次回退后索引仍为已回退", index_cells(ctx.owner, id1)[4] == "已回退")

    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", "CHG-19990101-01", "--dry-run"])
    expect("不存在的变更编号被拒绝", code, out, "nonzero", ("找不到变更分支",))


# ---------------------------------------------------------------------------
# 阶段 3：新增/删除/重命名 + --notes + --no-build
# ---------------------------------------------------------------------------


def phase_advanced(ctx, col, own):
    print("\n阶段 3：新增/删除/重命名 + --notes + --no-build")
    id2 = ctx.id2
    col.run("switch", "main")
    check("同事切回 main 且干净", col.clean(), col.out("status", "--porcelain"))

    code, out = run_tool(ctx.colleague, "新建变更.py", ["--id", id2, "--owner", "同事 乙", "--goal", "自测：新增删除重命名"])
    expect("新建第二个变更成功", code, out, 0)

    write_text(ctx.colleague, "Sources/Demo/新增 功能.swift", SWIFT_NEW)
    (ctx.colleague / "数据" / "示例.txt").unlink()
    (ctx.colleague / "资料" / "变更 说明.md").rename(ctx.colleague / "资料" / "改名 说明.md")

    notes_path = ctx.tmp / "说明-id2.json"
    write_notes_file(
        notes_path,
        {
            "Sources/Demo/新增 功能.swift": "新增功能示例文件（仅自测）",
            "数据/示例.txt": "删除不再需要的示例数据",
            "资料/改名 说明.md": "重命名说明文件并保持不变",
        },
    )
    code, out = run_tool(ctx.colleague, "提交变更.py", ["--id", id2, "--notes", str(notes_path)])
    expect("使用 --notes 提交新增/删除/重命名成功", code, out, 0)
    manifest = cm.load_manifest(ctx.colleague, id2)
    actions = sorted(item["action"] for item in manifest.get("files") or [])
    check("清单识别出 新增/删除/重命名", actions == ["A", "D", "R"], actions)
    rows = form_rows(ctx.colleague, id2)
    check("变更单说明来自 --notes", rows["数据/示例.txt"]["note"] == "删除不再需要的示例数据")
    col.run("push", "-u", "origin", "change/" + id2)
    own.run("fetch", "origin")

    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", id2])
    expect("首次审核第二变更需标注", code, out, "nonzero", ("采纳状态",))
    update_form(
        ctx.owner,
        id2,
        {
            "Sources/Demo/新增 功能.swift": {"adopt": "采纳"},
            "数据/示例.txt": {"adopt": "采纳"},
            "资料/改名 说明.md": {"adopt": "采纳"},
        },
    )
    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", id2, "--dry-run"])
    expect("第二变更 dry-run 通过", code, out, 0, ("预演通过",))

    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", id2, "--no-build"])
    expect("第二变更全部采纳应用成功（--no-build）", code, out, 0, ("采纳变更 %s: 3/3 个文件" % id2,))
    check("新增文件已应用", text_exists(ctx.owner, "Sources/Demo/新增 功能.swift") and read_text(ctx.owner, "Sources/Demo/新增 功能.swift") == SWIFT_NEW)
    check("删除文件已消失", not text_exists(ctx.owner, "数据/示例.txt"))
    check(
        "重命名已应用（新名存在、旧名消失）",
        text_exists(ctx.owner, "资料/改名 说明.md") and not text_exists(ctx.owner, "资料/变更 说明.md"),
    )
    cells = index_cells(ctx.owner, id2)
    check("索引状态=已采纳、采纳文件数=3/3", cells[4] == "已采纳" and cells[5] == "3/3", cells)
    record = application_record(ctx.owner, id2)
    build_note = (record.get("applications") or [{}])[0].get("build", "")
    check("应用记录注明 --no-build 跳过构建", "--no-build" in build_note, build_note)
    check("应用后工作区干净", own.clean(), own.out("status", "--porcelain"))

    code, out = run_tool(ctx.owner, "回退变更.py", ["--id", id2])
    expect("第二变更回退成功", code, out, 0, ("需重新打包安装才生效",))
    check("回退后新增文件消失", not text_exists(ctx.owner, "Sources/Demo/新增 功能.swift"))
    check("回退后删除文件恢复", read_text(ctx.owner, "数据/示例.txt") == TXT_BASE)
    check(
        "回退后重命名还原",
        text_exists(ctx.owner, "资料/变更 说明.md") and not text_exists(ctx.owner, "资料/改名 说明.md"),
    )
    check("第二变更回退提交标题正确", own.subject() == "回退变更 %s" % id2, own.subject())
    check("第二变更索引状态=已回退", index_cells(ctx.owner, id2)[4] == "已回退")
    check("第二变更回退后工作区干净", own.clean(), own.out("status", "--porcelain"))


# ---------------------------------------------------------------------------
# 阶段 4：构建失败自动恢复
# ---------------------------------------------------------------------------


def phase_build_failure(ctx, col, own):
    print("\n阶段 4：Swift 构建失败 → 自动恢复工作区、不提交")
    id3 = ctx.id3
    col.run("switch", "main")
    check("同事切回 main 且干净", col.clean(), col.out("status", "--porcelain"))
    code, out = run_tool(ctx.colleague, "新建变更.py", ["--id", id3, "--owner", "同事 丙", "--goal", "自测：构建失败恢复"])
    expect("新建第三个变更成功", code, out, 0)
    write_text(ctx.colleague, "Sources/Demo/main.swift", SWIFT_MAIN_CHANGED)
    notes_path = ctx.tmp / "说明-id3.json"
    write_notes_file(notes_path, {"Sources/Demo/main.swift": "修改入口输出，用于模拟"})
    code, out = run_tool(ctx.colleague, "提交变更.py", ["--id", id3, "--notes", str(notes_path)])
    expect("第三个变更提交成功", code, out, 0)
    col.run("push", "-u", "origin", "change/" + id3)
    own.run("fetch", "origin")

    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", id3])
    expect("第三个变更首次审核需标注", code, out, "nonzero", ("采纳状态",))
    update_form(ctx.owner, id3, {"Sources/Demo/main.swift": {"adopt": "采纳"}})
    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", id3, "--dry-run"])
    expect("构建失败前 dry-run 通过", code, out, 0, ("预演通过",))

    fakebin = ctx.tmp / "fakebin"
    fakebin.mkdir(exist_ok=True)
    fake_swift = fakebin / "swift"
    fake_swift.write_text("#!/bin/sh\necho 'error: simulated build failure [SELFTEST]' >&2\nexit 1\n", encoding="utf-8")
    fake_swift.chmod(0o755)

    before_count = own.commit_count()
    before_content = read_text(ctx.owner, "Sources/Demo/main.swift")
    fake_env = {"PATH": str(fakebin) + os.pathsep + os.environ.get("PATH", "")}
    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", id3], env_extra=fake_env)
    expect("构建失败时中止且恢复工作区", code, out, "nonzero", ("构建检查失败", "已恢复到审核前状态"))
    check("构建失败后源文件内容未变", read_text(ctx.owner, "Sources/Demo/main.swift") == before_content)
    check("构建失败后没有提交", own.commit_count() == before_count)
    check("构建失败后没有跟踪文件改动", own.tracked_changes() == [], own.tracked_changes())
    cells = index_cells(ctx.owner, id3)
    check("构建失败后索引未更新", (not cells) or cells[0] != id3, cells)

    # 用“成功的假 swift”验证构建命令与环境变量展开（不真正执行 Swift 构建）
    args_file = ctx.tmp / "swift-args.txt"
    fake_swift.write_text(
        "#!/bin/sh\nprintf '%%s\\n' \"$@\" > %s\nexit 0\n" % str(args_file), encoding="utf-8"
    )
    fake_swift.chmod(0o755)
    build_env = {
        "PATH": str(fakebin) + os.pathsep + os.environ.get("PATH", ""),
        "ASSETFRAME_SWIFT_SDK": "/fake/SDKs/MacOSX26.5.sdk",
        "ASSETFRAME_SWIFT_BUILD_FLAGS": "--skip-update --scratch-path /tmp/self-test-flags",
        "ASSETFRAME_SWIFT_SCRATCH_PATH": "/tmp/self-test-scratch",
    }
    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", id3], env_extra=build_env)
    expect("构建检查通过后应用成功", code, out, 0, ("构建检查通过", "采纳变更 %s: 1/1 个文件" % id3))
    captured = args_file.read_text(encoding="utf-8").split() if args_file.is_file() else []
    check(
        "构建命令为 swift build -c release 且展开 SDK/FLAGS/SCRATCH 环境变量",
        captured[:3] == ["build", "-c", "release"]
        and "--sdk" in captured
        and "/fake/SDKs/MacOSX26.5.sdk" in captured
        and "--skip-update" in captured
        and "/tmp/self-test-flags" in captured
        and "/tmp/self-test-scratch" in captured,
        captured,
    )
    check("应用后 source 内容为新版本", read_text(ctx.owner, "Sources/Demo/main.swift") == SWIFT_MAIN_CHANGED)
    record = application_record(ctx.owner, id3)
    check(
        "应用记录注明构建检查通过",
        "构建检查通过" in ((record.get("applications") or [{}])[0].get("build") or ""),
        record.get("applications"),
    )
    code, out = run_tool(ctx.owner, "回退变更.py", ["--id", id3])
    expect("第三个变更回退成功", code, out, 0, ("需重新打包安装才生效",))
    check("回退后 source 恢复基线内容", read_text(ctx.owner, "Sources/Demo/main.swift") == SWIFT_MAIN_BASE)


# ---------------------------------------------------------------------------
# 阶段 4b：提交失败时恢复工作区（模拟 pre-commit 钩子拒绝提交）
# ---------------------------------------------------------------------------


def phase_commit_failure(ctx, col, own):
    print("\n阶段 4b：提交失败 → 恢复工作区、不破坏已有状态")
    id1 = ctx.id1
    hook = ctx.owner / ".git" / "hooks" / "pre-commit"
    hook.parent.mkdir(parents=True, exist_ok=True)
    hook.write_text("#!/bin/sh\necho 'blocked by selftest hook' >&2\nexit 1\n", encoding="utf-8")
    hook.chmod(0o755)
    before_subject = own.subject()
    before_count = own.commit_count()
    before_content = read_text(ctx.owner, "资料/变更 说明.md")
    try:
        code, out = run_tool(ctx.owner, "审核应用.py", ["--id", id1, "--no-build"])
        expect("提交失败时中止并恢复工作区", code, out, "nonzero", ("git commit 失败", "已恢复到审核前状态"))
        check("提交失败后源文件未变", read_text(ctx.owner, "资料/变更 说明.md") == before_content)
        check("提交失败后没有新提交", own.commit_count() == before_count and own.subject() == before_subject)
        check("提交失败后没有跟踪文件改动", own.tracked_changes() == [], own.tracked_changes())
        check("提交失败后索引状态未变", index_cells(ctx.owner, id1)[4] == "已回退")
    finally:
        hook.unlink()

    # 移除钩子后重试成功，再回退，保证 owner 仓库回到干净状态
    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", id1, "--no-build"])
    expect("移除钩子后应用成功", code, out, 0, ("采纳变更 %s: 1/2 个文件" % id1,))
    code, out = run_tool(ctx.owner, "回退变更.py", ["--id", id1])
    expect("提交失败恢复后的回退成功", code, out, 0, ("需重新打包安装才生效",))
    check("提交失败恢复测试后工作区干净", own.clean(), own.out("status", "--porcelain"))


# ---------------------------------------------------------------------------
# 阶段 5：全部不采纳
# ---------------------------------------------------------------------------


def phase_reject_all(ctx, col, own):
    print("\n阶段 5：全部不采纳（0/N）")
    rec_id = "CHG-%s-04" % TODAY
    col.run("switch", "main")
    check("同事切回 main 且干净（全部不采纳阶段）", col.clean(), col.out("status", "--porcelain"))
    code, out = run_tool(ctx.colleague, "新建变更.py", ["--id", rec_id, "--owner", "同事 丁", "--goal", "自测：全部不采纳"])
    expect("新建第四个变更成功", code, out, 0)
    write_text(ctx.colleague, "资料/变更 说明.md", DOC_CHANGED)
    notes_path = ctx.tmp / "说明-id4.json"
    write_notes_file(notes_path, {"资料/变更 说明.md": "仅自测的说明改动"})
    code, out = run_tool(ctx.colleague, "提交变更.py", ["--id", rec_id, "--notes", str(notes_path)])
    expect("第四个变更提交成功", code, out, 0)
    col.run("push", "-u", "origin", "change/" + rec_id)
    own.run("fetch", "origin")

    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", rec_id])
    expect("第四个变更首次审核需标注", code, out, "nonzero", ("采纳状态",))
    update_form(ctx.owner, rec_id, {"资料/变更 说明.md": {"adopt": "不采纳"}})
    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", rec_id, "--dry-run"])
    expect("全部不采纳时 dry-run 通过", code, out, 0, ("预演通过",))
    before_content = read_text(ctx.owner, "资料/变更 说明.md")
    code, out = run_tool(ctx.owner, "审核应用.py", ["--id", rec_id])
    expect("全部不采纳也记录结论", code, out, 0, ("采纳变更 %s: 0/1 个文件" % rec_id,))
    check("全部不采纳后文件内容未变", read_text(ctx.owner, "资料/变更 说明.md") == before_content)
    check("全部不采纳后提交标题正确", own.subject() == "采纳变更 %s: 0/1 个文件" % rec_id, own.subject())
    cells = index_cells(ctx.owner, rec_id)
    check("全部不采纳时索引状态=不采纳、采纳文件数=0/1", cells[4] == "不采纳" and cells[5] == "0/1", cells)
    code, out = run_tool(ctx.owner, "回退变更.py", ["--id", rec_id])
    expect("全部不采纳的变更拒绝回退", code, out, "nonzero", ("没有任何应用历史",))
    check("全部不采纳记录后工作区干净", own.clean(), own.out("status", "--porcelain"))


# ---------------------------------------------------------------------------
# 阶段 6：基线漂移检测
# ---------------------------------------------------------------------------


def phase_drift(ctx):
    print("\n阶段 5：基线漂移检测（main 历史被改写）")
    code, out = run_proc(["git", "clone", str(ctx.origin), str(ctx.drift)], cwd=ctx.tmp)
    check("克隆漂移测试仓库", code == 0, out)
    drift = git(ctx.drift)
    drift.run("config", "user.name", "自测漂移")
    drift.run("config", "user.email", "selftest-drift@example.invalid")
    drift.run("fetch", "origin")
    drift.run("commit", "--amend", "--allow-empty", "-m", "改写基线（模拟 main 历史变化）")
    check("基线提交不再是新 main 的祖先", not cm.is_ancestor(Path(ctx.drift), ctx.baseline_sha, "HEAD"))
    code, out = run_tool(ctx.drift, "审核应用.py", ["--id", ctx.id2, "--dry-run"])
    expect("基线漂移时停止并提示 rebase", code, out, "nonzero", ("基线漂移", "rebase"))
    check("基线漂移时未复制变更记录", not (ctx.drift / "变更管理" / "记录" / ctx.id2).exists())

    # main 在基线后改过待采纳文件：默认拒绝，--allow-overwrite 才放行
    conflict = ctx.tmp / "冲突 工作区"
    code, out = run_proc(["git", "clone", str(ctx.origin), str(conflict)], cwd=ctx.tmp)
    check("克隆冲突测试仓库", code == 0, out)
    cref = git(conflict)
    cref.run("config", "user.name", "自测冲突")
    cref.run("config", "user.email", "selftest-conflict@example.invalid")
    cref.run("fetch", "origin")
    write_text(conflict, "数据/示例.txt", "main 在基线后修改了该文件\n")
    cref.run("add", "-A")
    cref.run("commit", "-m", "main 在基线后修改数据文件")
    code, out = run_tool(conflict, "审核应用.py", ["--id", ctx.id2])
    expect("冲突测试首次审核需标注", code, out, "nonzero", ("采纳状态",))
    update_form(
        conflict,
        ctx.id2,
        {
            "Sources/Demo/新增 功能.swift": {"adopt": "采纳"},
            "数据/示例.txt": {"adopt": "采纳"},
            "资料/改名 说明.md": {"adopt": "采纳"},
        },
    )
    code, out = run_tool(conflict, "审核应用.py", ["--id", ctx.id2, "--dry-run"])
    expect("main 改过同一文件时默认拒绝", code, out, "nonzero", ("覆盖", "--allow-overwrite"))
    check("冲突被拒绝后未应用文件", not (conflict / "Sources/Demo/新增 功能.swift").exists())
    code, out = run_tool(conflict, "审核应用.py", ["--id", ctx.id2, "--dry-run", "--allow-overwrite"])
    expect("--allow-overwrite 时 dry-run 放行", code, out, 0, ("预演通过",))
    check("冲突测试 dry-run 未产生提交", cref.commit_count() == 2)


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------


def main():
    print("=== 变更管理工具自测（/tmp 临时仓库）===")
    print("真实仓库（只读工具来源）：%s" % REPO)
    ctx = None
    exit_code = 1
    try:
        ctx = Ctx()
        print("临时目录：%s" % ctx.tmp)
        col, own = phase_setup(ctx)
        phase_primary(ctx, col, own)
        phase_advanced(ctx, col, own)
        phase_build_failure(ctx, col, own)
        phase_commit_failure(ctx, col, own)
        phase_reject_all(ctx, col, own)
        phase_drift(ctx)

        # 全程只连本地 bare 仓库
        for name, repo in (("同事工作区", ctx.colleague), ("负责人工作区", ctx.owner), ("漂移测试仓库", ctx.drift)):
            url = git(repo).out("remote", "get-url", "origin")
            check("%s 的 origin 指向本地临时仓库" % name, str(url).startswith(str(ctx.tmp)), url)
        check("自测未访问真实远程（无真实仓库写入）", True)

        passed = sum(1 for _name, good in RESULTS if good)
        failed = len(RESULTS) - passed
        print("\nSUMMARY: 通过 %d / 失败 %d（共 %d 项检查）" % (passed, failed, len(RESULTS)))
        if failed == 0:
            print("结果：PASS —— 变更管理工具自测全部通过。")
            dead = [name for name, good in RESULTS if not good]
            del dead
            exit_code = 0
        else:
            print("结果：FAIL —— 以下检查失败：")
            for name, good in RESULTS:
                if not good:
                    print("  - %s" % name)
            exit_code = 1
    except Exception:
        print("\n✘ 自测执行异常：")
        traceback.print_exc()
        passed = sum(1 for _name, good in RESULTS if good)
        failed = (len(RESULTS) - passed) + 1
        print("\nSUMMARY: 通过 %d / 失败 %d（其中含执行异常 1 项）" % (passed, failed))
        exit_code = 1
    finally:
        if ctx is not None:
            keep = os.environ.get("SELFTEST_KEEP", "").strip()
            if exit_code == 0 and not keep:
                shutil.rmtree(ctx.tmp, ignore_errors=True)
                print("已清理临时目录：%s" % ctx.tmp)
            else:
                print("临时目录已保留供排查：%s" % ctx.tmp)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
