#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""变更管理工具公共库（Python 3 标准库，无第三方依赖）。

本文件被同目录下的 新建变更.py / 提交变更.py / 审核应用.py / 回退变更.py 共同引用，
不是独立命令。所有 git 操作均通过 -C <仓库根目录> 执行，路径一律用参数列表传递，
git 文件列表一律使用 -z（NUL 分隔）解析，避免中文、空格和特殊字符造成歧义。
"""

import datetime
import json
import os
import re
import shlex
import subprocess
import sys
import traceback
from pathlib import Path

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

ID_RE = re.compile(r"^CHG-(\d{8})-(\d{2})$")
META_DIR = "变更管理"
RECORD_ROOT = "变更管理/记录"
TOOL_DIR = "变更管理/工具"
TEMPLATE_PATH = "变更管理/模板/变更单.md"
INDEX_PATH = "变更管理/索引.md"
DOCS_DIR = "变更管理"

ALLOWED_ADOPT = ("采纳", "不采纳", "待定")
INDEX_STATUS = ("待提交", "待审核", "已采纳", "部分采纳", "已回退", "不采纳")
TYPE_LABELS = {"A": "新增", "M": "修改", "D": "删除", "R": "重命名", "C": "新增", "T": "修改"}
META_KEYS = (
    "变更编号",
    "负责人",
    "创建日期",
    "目标",
    "基线 commit",
    "变更分支",
    "当前状态",
    "变更文件数",
)
PLACEHOLDER_NOTE = "（请填写本文件的改动说明）"
INDEX_HEADER_LINES = [
    "# 变更索引",
    "",
    "> 本表由 `变更管理/工具/` 下的脚本自动维护，请勿手工改动列顺序。",
    "> 状态可选项：待提交 / 待审核 / 已采纳 / 部分采纳 / 已回退 / 不采纳。",
    "> 回退时间格式：`YYYY-MM-DD HH:MM`。",
    "",
    "| 编号 | 负责人 | 日期 | 目标 | 状态 | 采纳文件数 | 回退时间 | 记录链接 |",
    "| --- | --- | --- | --- | --- | --- | --- | --- |",
]

GIT_ENV_OVERRIDES = {
    # 路径一律按字面量处理，避免文件名里的 * ? [ 等被当成通配符
    "GIT_LITERAL_PATHSPECS": "1",
    # 绝不弹交互式凭据/密码提示；脚本本身不联网
    "GIT_TERMINAL_PROMPT": "0",
    "GIT_PAGER": "cat",
    "PAGER": "cat",
}

BUILD_TIMEOUT_ENV = "ASSETFRAME_CHANGE_BUILD_TIMEOUT"
DEFAULT_BUILD_TIMEOUT = 3600


# ---------------------------------------------------------------------------
# 输出与错误
# ---------------------------------------------------------------------------


class ToolError(Exception):
    """可直接展示给用户的错误。"""


def setup_console():
    """统一按 UTF-8 输出，避免终端编码导致中文乱码。"""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def line(msg=""):
    print(msg)


def step(title):
    print("\n── %s ──" % title)


def info(msg):
    print("  %s" % msg)


def ok(msg):
    print("✔ %s" % msg)


def warn(msg):
    print("⚠ %s" % msg)


def hint(msg):
    print("  提示：%s" % msg)


def fail(msg):
    raise ToolError(msg)


def run_cli(banner, func, argv=None):
    """统一的脚本入口包装：打印标题、捕获错误、返回退出码。"""
    setup_console()
    line(banner)
    try:
        code = func(argv)
        return 0 if code is None else int(code)
    except ToolError as exc:
        print("\n✘ %s" % exc, file=sys.stderr)
        return 1
    except SystemExit as exc:  # argparse 的 --help / 参数错误
        return int(exc.code or 0)
    except KeyboardInterrupt:
        print("\n已取消。", file=sys.stderr)
        return 130
    except Exception as exc:  # 兜底：打印栈便于定位，但退出码保持非 0
        print("\n✘ 内部错误：%s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        traceback.print_exc()
        return 1


# ---------------------------------------------------------------------------
# 时间
# ---------------------------------------------------------------------------


def now_str():
    return datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z")


def now_minute():
    return datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M")


def today_str():
    return datetime.date.today().strftime("%Y-%m-%d")


# ---------------------------------------------------------------------------
# git 基础
# ---------------------------------------------------------------------------


def _decode(raw):
    if raw is None:
        return ""
    return raw.decode("utf-8", "surrogateescape")


def _git_env():
    env = os.environ.copy()
    env.update(GIT_ENV_OVERRIDES)
    return env


def run_git(root, args, check=True):
    """执行 git 命令，返回 CompletedProcess（stdout/stderr 为 bytes）。"""
    cmd = ["git", "-C", str(root)] + [str(a) for a in args]
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=_git_env(),
        )
    except FileNotFoundError:
        fail("未找到 git 命令。请先安装 Git（macOS 可执行 `xcode-select --install`）。")
    if check and proc.returncode != 0:
        stderr = _decode(proc.stderr).strip()
        fail(
            "git 命令执行失败（退出码 %d）：\n  git %s\n%s"
            % (proc.returncode, " ".join(str(a) for a in args), stderr)
        )
    return proc


def git_text(root, args, check=True):
    return _decode(run_git(root, args, check=check).stdout).strip()


def git_z(root, args, check=True):
    """执行期望输出以 NUL 结尾列表的 git 命令，返回字符串列表。"""
    raw = run_git(root, args, check=check).stdout
    parts = raw.split(b"\x00")
    if parts and parts[-1] == b"":
        parts = parts[:-1]
    return [_decode(p) for p in parts]


def git_root(start_dir=None):
    """从脚本所在目录向上定位 git 仓库根目录。"""
    start = Path(start_dir) if start_dir else Path(__file__).resolve().parent
    proc = run_git(start, ["rev-parse", "--show-toplevel"], check=False)
    if proc.returncode != 0:
        fail(
            "无法定位 git 仓库根目录（脚本应放在仓库的 变更管理/工具/ 下，且仓库需已 git init）。\n"
            "  当前定位起点：%s" % start
        )
    root = Path(_decode(proc.stdout).strip())
    if not root.is_dir():
        fail("git 返回的仓库根目录不存在：%s" % root)
    return root


def current_branch(root):
    proc = run_git(root, ["symbolic-ref", "--quiet", "--short", "HEAD"], check=False)
    if proc.returncode != 0:
        return None
    return _decode(proc.stdout).strip()


def head_commit(root):
    return git_text(root, ["rev-parse", "HEAD"])


def short_sha(sha):
    return (sha or "")[:10]


def ref_exists(root, ref):
    proc = run_git(
        root,
        ["rev-parse", "--verify", "--quiet", "%s^{commit}" % ref],
        check=False,
    )
    return proc.returncode == 0


def resolve_ref(root, ref):
    return git_text(root, ["rev-parse", ref])


def is_ancestor(root, ancestor, descendant):
    proc = run_git(
        root, ["merge-base", "--is-ancestor", str(ancestor), str(descendant)], check=False
    )
    if proc.returncode not in (0, 1):
        fail("判断提交祖先关系失败：%s / %s" % (ancestor, descendant))
    return proc.returncode == 0


def path_exists_in_commit(root, commit, relpath):
    out = run_git(
        root, ["ls-tree", "-z", "--name-only", commit, "--", relpath]
    ).stdout
    return bool(out.strip(b"\x00"))


def hash_worktree_file(root, relpath):
    """计算工作区文件内容哈希；文件不存在返回 None。"""
    full = root / relpath
    if not full.exists():
        return None
    return git_text(root, ["hash-object", "--", relpath])


def read_branch_text(root, ref, relpath):
    proc = run_git(root, ["show", "%s:%s" % (ref, relpath)], check=False)
    if proc.returncode != 0:
        fail("无法从 %s 读取文件 %s（分支/文件可能不存在）。" % (ref, relpath))
    return _decode(proc.stdout)


def branch_has_path(root, ref, relpath):
    proc = run_git(root, ["show", "%s:%s" % (ref, relpath)], check=False)
    return proc.returncode == 0


# ---------------------------------------------------------------------------
# 工作区校验
# ---------------------------------------------------------------------------


def _path_allowed(relpath, allowed_prefixes):
    for prefix in allowed_prefixes:
        prefix = prefix.rstrip("/")
        if not prefix:
            continue
        if relpath == prefix or relpath.startswith(prefix + "/"):
            return True
    return False


def workspace_problems(root, allow_prefixes=()):
    """返回工作区不干净的条目说明列表；空列表表示干净。"""
    problems = []
    tracked = set(git_z(root, ["diff", "--name-only", "-z"]))
    tracked |= set(git_z(root, ["diff", "--cached", "--name-only", "-z"]))
    for path in sorted(tracked):
        problems.append("已修改但未提交：%s" % path)
    untracked = git_z(root, ["ls-files", "--others", "--exclude-standard", "-z"])
    for path in sorted(untracked):
        if "__pycache__" in path.split("/"):
            continue
        if not _path_allowed(path, allow_prefixes):
            problems.append("未跟踪文件：%s" % path)
    return problems


def require_clean(root, allow_prefixes=(), action_hint=""):
    problems = workspace_problems(root, allow_prefixes)
    if problems:
        show = "\n".join("    - " + p for p in problems[:20])
        if len(problems) > 20:
            show += "\n    …… 共 %d 项" % len(problems)
        extra = ("\n  " + action_hint) if action_hint else ""
        fail("工作区不干净，为避免误操作已停止。请先提交、还原或暂存（git stash）这些内容：\n" + show + extra)


def require_clean_for_apply(root, rec_id):
    """审核/回退时允许 本变更 记录目录尚未被提交（负责人标注状态后未提交）。"""
    return require_clean(
        root,
        allow_prefixes=("%s/%s" % (RECORD_ROOT, rec_id),),
        action_hint="审核/回退前，除本变更记录目录外的工作区改动必须先处理。",
    )


# ---------------------------------------------------------------------------
# 标记表格（Markdown）
# ---------------------------------------------------------------------------


def escape_cell(value):
    s = str(value if value is not None else "")
    s = s.replace("\r", " ").replace("\n", " ")
    return s.replace("|", "\\|")


def unescape_cell(value):
    return value.replace("\\|", "|").strip()


def strip_ticks(value):
    v = (value or "").strip()
    if len(v) >= 2 and v.startswith("`") and v.endswith("`"):
        v = v[1:-1].strip()
    return v


def split_row(text):
    s = text.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    parts = re.split(r"(?<!\\)\|", s)
    return [unescape_cell(p) for p in parts]


def is_separator_row(text):
    s = text.strip()
    if not s.startswith("|"):
        return False
    return re.match(r"^\|[\s\-:|]+\|?$", s) is not None


def find_table(lines):
    """定位逐文件表，返回 (表头行号, 表格结束行号(不含))；找不到返回 None。"""
    for idx, raw in enumerate(lines):
        s = raw.strip()
        if s.startswith("|") and "文件路径" in s and "采纳状态" in s:
            end = idx + 1
            while end < len(lines) and lines[end].strip().startswith("|"):
                end += 1
            return idx, end
    return None


def table_data_rows(lines, table):
    header_idx, end_idx = table
    start = header_idx + 1
    if start < end_idx and is_separator_row(lines[start]):
        start += 1
    rows = []
    for idx in range(start, end_idx):
        cells = split_row(lines[idx])
        if not cells or not cells[0].strip():
            continue
        rows.append((idx, cells))
    return rows


def parse_change_form(text):
    lines = text.splitlines()
    meta = {}
    meta_indices = {}
    for idx, raw in enumerate(lines):
        match = re.match(r"^\s*-\s*([^：:]{1,40}?)\s*[：:]\s*(.*)$", raw)
        if not match:
            continue
        key = match.group(1).strip()
        if key in META_KEYS:
            meta[key] = strip_ticks(match.group(2))
            meta_indices[key] = idx
    rows = {}
    row_order = []
    table = find_table(lines)
    if table:
        for _idx, cells in table_data_rows(lines, table):
            path = strip_ticks(cells[0])
            if not path:
                continue
            row = {
                "path": path,
                "type": cells[1] if len(cells) > 1 else "",
                "lines": cells[2] if len(cells) > 2 else "",
                "note": cells[3] if len(cells) > 3 else "",
                "adopt": cells[4] if len(cells) > 4 else "",
            }
            rows[path] = row
            row_order.append(path)
    return {
        "lines": lines,
        "meta": meta,
        "meta_indices": meta_indices,
        "rows": rows,
        "row_order": row_order,
        "table": table,
    }


def upsert_meta_line(lines, key, value):
    pattern = re.compile(r"^\s*-\s*" + re.escape(key) + r"\s*[：:]\s*")
    for idx, raw in enumerate(lines):
        if pattern.match(raw):
            lines[idx] = "- %s：%s" % (key, value)
            return
    # 没有该字段：插到最后一个 meta 字段之后
    last = None
    for idx, raw in enumerate(lines):
        match = re.match(r"^\s*-\s*([^：:]{1,40}?)\s*[：:]", raw)
        if match and match.group(1).strip() in META_KEYS:
            last = idx
    insert_at = (last + 1) if last is not None else len(lines)
    lines.insert(insert_at, "- %s：%s" % (key, value))


def render_files_table(entries):
    lines = [
        "| 文件路径 | 类型 | +行/-行 | 说明 | 采纳状态 |",
        "| --- | --- | --- | --- | --- |",
    ]
    for entry in entries:
        type_label = TYPE_LABELS.get(entry.get("action", "M"), "修改")
        if entry.get("old_path"):
            type_label += "（旧路径：%s）" % entry["old_path"]
        lines.append(
            "| %s | %s | %s | %s | %s |"
            % (
                escape_cell(entry["path"]),
                escape_cell(type_label),
                escape_cell(format_line_stat(entry)),
                escape_cell(entry.get("note") or PLACEHOLDER_NOTE),
                escape_cell(entry.get("adopt") or "待定"),
            )
        )
    return lines


def apply_form_table(text, entries):
    """把逐文件表替换为最新内容，其余内容（风险/验证/结论）原样保留。"""
    lines = text.splitlines()
    table = find_table(lines)
    rendered = render_files_table(entries)
    if table:
        header_idx, end_idx = table
        # 表头/分隔行按旧内容保留，避免用户自定义列标题被冲掉
        old_header = lines[header_idx]
        old_sep = lines[header_idx + 1] if header_idx + 1 < end_idx else None
        new_block = [old_header]
        if old_sep is not None and is_separator_row(old_sep):
            new_block.append(old_sep)
        new_block.extend(rendered[2:])
        lines[header_idx:end_idx] = new_block
    else:
        insert_at = len(lines)
        for idx, raw in enumerate(lines):
            if "逐文件" in raw and raw.strip().startswith("#"):
                insert_at = idx + 1
                while insert_at < len(lines) and not lines[insert_at].strip():
                    insert_at += 1
                break
        block = [""] + rendered + [""]
        lines[insert_at:insert_at] = block
    return "\n".join(lines).rstrip("\n") + "\n"


def update_form_status(text, status, extra_meta=None):
    lines = text.splitlines()
    upsert_meta_line(lines, "当前状态", status)
    if extra_meta:
        for key, value in extra_meta.items():
            upsert_meta_line(lines, key, value)
    return "\n".join(lines).rstrip("\n") + "\n"


def format_line_stat(entry):
    added = entry.get("added")
    deleted = entry.get("deleted")
    if added is None or deleted is None:
        return "二进制"
    return "+%s/-%s" % (added, deleted)


def parse_notes_file(path):
    """--notes 文件：.json 为 {路径: 说明}；其它扩展名按 `路径<TAB>说明` 解析。"""
    notes_path = Path(path).expanduser()
    if not notes_path.is_file():
        fail("找不到说明文件：%s" % notes_path)
    try:
        raw = notes_path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        fail("说明文件不是 UTF-8 编码：%s" % notes_path)
    if notes_path.suffix.lower() == ".json":
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            fail("说明 JSON 解析失败：%s\n  %s" % (notes_path, exc))
        if not isinstance(data, dict):
            fail("说明 JSON 必须是「文件路径 → 说明」的对象。")
        return {str(k): str(v).strip() for k, v in data.items()}
    notes = {}
    for lineno, raw_line in enumerate(raw.splitlines(), 1):
        text = raw_line.strip()
        if not text or text.startswith("#"):
            continue
        if "\t" in text:
            parts = text.split("\t", 1)
        elif text.startswith("|"):
            cells = split_row(text)
            if len(cells) < 2:
                continue
            parts = [cells[0], cells[1]]
        else:
            fail(
                "说明文件第 %d 行格式不对：需要 `文件路径<TAB>说明`（或用 .json 文件）。\n  该行：%s"
                % (lineno, text)
            )
        key = strip_ticks(parts[0])
        value = parts[1].strip()
        if key:
            notes[key] = value
    return notes


# ---------------------------------------------------------------------------
# 清单 / 变更单 / 索引
# ---------------------------------------------------------------------------


def record_dir(root, rec_id):
    return root / RECORD_ROOT / rec_id


def manifest_path(root, rec_id):
    return record_dir(root, rec_id) / "清单.json"


def form_path(root, rec_id):
    return record_dir(root, rec_id) / "变更单.md"


def diff_path(root, rec_id):
    return record_dir(root, rec_id) / "改动.diff"


def application_record_path(root, rec_id):
    return record_dir(root, rec_id) / "应用记录.json"


def read_json(path, what="记录文件"):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail("找不到%s：%s" % (what, path))
    except json.JSONDecodeError as exc:
        fail("%s 不是合法 JSON：%s\n  %s" % (what, path, exc))


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def write_text(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def load_manifest(root, rec_id):
    data = read_json(manifest_path(root, rec_id), "变更清单 清单.json")
    if not isinstance(data, dict) or not data.get("id"):
        fail("清单.json 内容不完整（缺少 id）。")
    return data


def save_manifest(root, rec_id, manifest):
    write_json(manifest_path(root, rec_id), manifest)


def read_form(root, rec_id):
    path = form_path(root, rec_id)
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        fail("找不到变更单：%s\n  请确认已运行 新建变更.py，且当前在正确的仓库/分支。" % path)


def load_application_record(root, rec_id):
    path = application_record_path(root, rec_id)
    if not path.is_file():
        return {"id": rec_id, "applications": []}
    data = read_json(path, "应用记录 应用记录.json")
    if not isinstance(data, dict):
        fail("应用记录格式错误：%s" % path)
    data.setdefault("applications", [])
    return data


def save_application_record(root, rec_id, data):
    write_json(application_record_path(root, rec_id), data)


def validate_change_id(rec_id):
    match = ID_RE.match(rec_id or "")
    if not match:
        fail("变更编号格式错误：%s\n  正确格式：CHG-YYYYMMDD-NN（例如 CHG-20261023-01）" % rec_id)
    date_text, seq = match.group(1), match.group(2)
    try:
        datetime.datetime.strptime(date_text, "%Y%m%d")
    except ValueError:
        fail("变更编号里的日期不合法：%s（应为 YYYYMMDD，例如 20261023）" % date_text)
    if int(seq) < 1:
        fail("变更编号序号至少为 01：%s" % rec_id)
    return date_text, seq


def read_index_lines(root):
    path = root / INDEX_PATH
    if path.is_file():
        return path.read_text(encoding="utf-8").splitlines()
    return list(INDEX_HEADER_LINES)


def ensure_index_table(lines):
    header_idx = None
    for idx, raw in enumerate(lines):
        if raw.strip().startswith("|") and "编号" in raw and "记录链接" in raw:
            header_idx = idx
            break
    if header_idx is not None:
        return lines
    if lines and lines[-1].strip():
        lines.append("")
    lines.extend(INDEX_HEADER_LINES[5:])
    return lines


def find_index_row(lines, rec_id):
    for idx, raw in enumerate(lines):
        s = raw.strip()
        if not s.startswith("|"):
            continue
        cells = split_row(s)
        if not cells:
            continue
        if ID_RE.search(cells[0]):
            if rec_id in cells[0]:
                return idx, cells
    return None, None


def render_index_row(fields):
    return "| %s | %s | %s | %s | %s | %s | %s | %s |" % (
        escape_cell(fields["id"]),
        escape_cell(fields["owner"]),
        escape_cell(fields["date"]),
        escape_cell(fields["goal"]),
        escape_cell(fields["status"]),
        escape_cell(fields["adopted"]),
        escape_cell(fields["reverted"]),
        escape_cell(fields["link"]),
    )


def index_fields(manifest, status=None, adopted="-", reverted="-"):
    rec_id = manifest["id"]
    created = (manifest.get("created_at") or "")[:10] or today_str()
    return {
        "id": rec_id,
        "owner": manifest.get("owner") or "-",
        "date": created,
        "goal": manifest.get("goal") or "-",
        "status": status or manifest.get("status") or "待提交",
        "adopted": adopted,
        "reverted": reverted,
        "link": "[变更单](记录/%s/变更单.md)" % rec_id,
    }


def update_index(root, manifest, status=None, adopted="-", reverted="-"):
    """新增/更新索引行。返回写入后的索引路径。"""
    lines = ensure_index_table(read_index_lines(root))
    fields = index_fields(manifest, status=status, adopted=adopted, reverted=reverted)
    row_idx, _cells = find_index_row(lines, manifest["id"])
    row_line = render_index_row(fields)
    if row_idx is not None:
        lines[row_idx] = row_line
    else:
        last_table = None
        for idx, raw in enumerate(lines):
            if raw.strip().startswith("|"):
                last_table = idx
        if last_table is None:
            lines.extend(INDEX_HEADER_LINES[5:])
            lines.append(row_line)
        else:
            lines.insert(last_table + 1, row_line)
    path = root / INDEX_PATH
    write_text(path, "\n".join(lines).rstrip("\n") + "\n")
    return path


# ---------------------------------------------------------------------------
# 差异计算
# ---------------------------------------------------------------------------


def is_metadata_path(relpath):
    return relpath == META_DIR or relpath.startswith(META_DIR + "/")


def split_diff_name_status(z_items):
    entries = []
    idx = 0
    while idx < len(z_items):
        status = z_items[idx]
        idx += 1
        if not status:
            continue
        if status[0] in ("R", "C"):
            if idx + 1 >= len(z_items):
                fail("解析 git diff --name-status -z 输出失败（重命名记录不完整）。")
            old = z_items[idx]
            new = z_items[idx + 1]
            idx += 2
            entries.append({"action": status[0], "old_path": old, "path": new})
        else:
            if idx >= len(z_items):
                fail("解析 git diff --name-status -z 输出失败（路径缺失）。")
            path = z_items[idx]
            idx += 1
            entries.append({"action": status[0], "old_path": None, "path": path})
    return entries


def _to_int_or_none(text):
    try:
        return int(text)
    except (TypeError, ValueError):
        return None


def split_diff_numstat(z_items):
    entries = []
    idx = 0
    while idx < len(z_items):
        item = z_items[idx]
        idx += 1
        if not item:
            continue
        parts = item.split("\t", 2)
        if len(parts) < 2:
            fail("解析 git diff --numstat -z 输出失败：%r" % item)
        added = _to_int_or_none(parts[0])
        deleted = _to_int_or_none(parts[1])
        path = parts[2] if len(parts) > 2 else ""
        if path == "":
            if idx + 1 >= len(z_items):
                fail("解析 git diff --numstat -z 输出失败（重命名记录不完整）。")
            old = z_items[idx]
            new = z_items[idx + 1]
            idx += 2
            entries.append(
                {
                    "old_path": old,
                    "path": new,
                    "added": added,
                    "deleted": deleted,
                }
            )
        else:
            entries.append(
                {"old_path": None, "path": path, "added": added, "deleted": deleted}
            )
    return entries


def merge_diff_entries(name_status, numstat):
    stat_map = {}
    for item in numstat:
        key = (item["old_path"], item["path"]) if item["old_path"] else (None, item["path"])
        stat_map[key] = item
    merged = []
    for entry in name_status:
        key = (
            (entry["old_path"], entry["path"])
            if entry["old_path"]
            else (None, entry["path"])
        )
        stat = stat_map.pop(key, None)
        merged.append(
            {
                "path": entry["path"],
                "old_path": entry["old_path"],
                "action": entry["action"],
                "type_label": TYPE_LABELS.get(entry["action"], "修改"),
                "added": stat["added"] if stat else None,
                "deleted": stat["deleted"] if stat else None,
            }
        )
    # 理论上不会剩下无法匹配的 numstat；若剩，补为修改项
    for key, stat in stat_map.items():
        merged.append(
            {
                "path": stat["path"],
                "old_path": stat["old_path"],
                "action": "M",
                "type_label": TYPE_LABELS["M"],
                "added": stat["added"],
                "deleted": stat["deleted"],
            }
        )
    merged.sort(key=lambda item: (item["path"], item["action"]))
    return merged


def diff_entries_ref(root, base, ref, include_metadata=False):
    """对比 base 与 ref（三点点号：以 base 与 ref 的merge-base 为起点）。"""
    spec = "%s...%s" % (base, ref)
    name_status = split_diff_name_status(
        git_z(root, ["diff", "--name-status", "-M", "-z", spec])
    )
    numstat = split_diff_numstat(
        git_z(root, ["diff", "--numstat", "-M", "-z", spec])
    )
    entries = merge_diff_entries(name_status, numstat)
    if include_metadata:
        return entries
    return [item for item in entries if not is_metadata_path(item["path"])]


def untracked_change_files(root):
    paths = git_z(root, ["ls-files", "--others", "--exclude-standard", "-z"])
    return [p for p in paths if not is_metadata_path(p)]


def diff_entries_worktree(root, base):
    """对比 base 与工作区（含未跟踪文件；调用前需对未跟踪文件 git add -N）。"""
    name_status = split_diff_name_status(
        git_z(root, ["diff", "--name-status", "-M", "-z", base])
    )
    numstat = split_diff_numstat(git_z(root, ["diff", "--numstat", "-M", "-z", base]))
    entries = merge_diff_entries(name_status, numstat)
    return [item for item in entries if not is_metadata_path(item["path"])]


def diff_text_worktree(root, base):
    raw = run_git(
        root,
        ["diff", "-M", "--no-color", "--no-ext-diff", base],
    ).stdout
    return _decode(raw)


def summarize_actions(entries):
    counts = {"A": 0, "M": 0, "D": 0, "R": 0, "other": 0}
    for entry in entries:
        action = entry.get("action")
        if action in counts:
            counts[action] += 1
        else:
            counts["other"] += 1
    parts = []
    for action, label in (("A", "新增"), ("M", "修改"), ("D", "删除"), ("R", "重命名")):
        if counts[action]:
            parts.append("%s %d" % (label, counts[action]))
    if counts["other"]:
        parts.append("其它 %d" % counts["other"])
    return "、".join(parts) if parts else "无文件变化"


def describe_entries(entries):
    lines = []
    for entry in entries:
        label = TYPE_LABELS.get(entry.get("action"), "修改")
        extra = ""
        if entry.get("old_path"):
            extra = "（旧路径：%s）" % entry["old_path"]
        text = "%s %s %s" % (label, entry["path"], extra)
        lines.append(text.rstrip())
    return lines


# ---------------------------------------------------------------------------
# 提交
# ---------------------------------------------------------------------------


def staged_paths(root):
    return set(git_z(root, ["diff", "--cached", "--name-only", "-z"]))


def require_empty_staged(root, action_hint=""):
    staged = staged_paths(root)
    if staged:
        show = "\n".join("    - %s" % p for p in sorted(staged)[:20])
        extra = ("\n  " + action_hint) if action_hint else ""
        fail("暂存区已有其它改动，为避免把无关内容带进提交，已停止：\n" + show + extra)


def git_add_all(root, paths):
    unique = []
    seen = set()
    for path in paths:
        if path and path not in seen:
            seen.add(path)
            unique.append(path)
    if not unique:
        fail("没有需要暂存的文件。")
    to_add = []
    for path in unique:
        if (root / path).exists():
            to_add.append(path)
            continue
        # 文件已不在工作区：若索引里还有，需要 add 以暂存删除；
        # 若索引里也已没有（例如审核应用已用 git rm 暂存删除），跳过即可。
        proc = run_git(root, ["ls-files", "--error-unmatch", "--", path], check=False)
        if proc.returncode == 0:
            to_add.append(path)
    if not to_add:
        if not staged_paths(root):
            fail("没有需要暂存的文件。")
        return
    # 参数较多时分批，避免超过系统命令长度上限
    chunk = 200
    for start in range(0, len(to_add), chunk):
        run_git(root, ["add", "-A", "--"] + to_add[start : start + chunk])


def commit_changes(root, subject, body_lines=()):
    if not staged_paths(root):
        fail("没有可提交的改动。")
    args = ["commit", "-m", subject]
    for text in body_lines:
        args.extend(["-m", text])
    proc = run_git(root, args, check=False)
    if proc.returncode != 0:
        fail(
            "git commit 失败（退出码 %d）：\n%s"
            % (proc.returncode, _decode(proc.stderr).strip())
        )
    return head_commit(root)


def stage_and_commit(root, subject, body_lines, paths):
    git_add_all(root, paths)
    return commit_changes(root, subject, body_lines)


# ---------------------------------------------------------------------------
# 变更分支定位
# ---------------------------------------------------------------------------


def resolve_change_ref(root, rec_id, branch_override=None):
    """定位远程/本地 change/<ID> 分支，返回 (ref, sha)。"""
    if branch_override:
        if not ref_exists(root, branch_override):
            fail("指定的分支不存在：%s" % branch_override)
        return branch_override, resolve_ref(root, branch_override)
    branch = "change/" + rec_id
    remote = "origin/" + branch
    has_local = ref_exists(root, branch)
    has_remote = ref_exists(root, remote)
    if has_local and has_remote:
        local_sha = resolve_ref(root, branch)
        remote_sha = resolve_ref(root, remote)
        if local_sha != remote_sha:
            fail(
                "本地分支 %s 与 %s 指向不同提交，无法确定审核对象：\n"
                "  本地：%s\n  远程：%s\n"
                "  请先确认哪一个是同事的最新提交，或用 --branch <分支引用> 明确指定；\n"
                "  也可以删除/更新本地分支后重试（例如 git branch -f %s %s）。"
                % (
                    branch,
                    remote,
                    short_sha(local_sha),
                    short_sha(remote_sha),
                    branch,
                    remote,
                )
            )
        return remote, remote_sha
    if has_remote:
        return remote, resolve_ref(root, remote)
    if has_local:
        return branch, resolve_ref(root, branch)
    fail(
        "找不到变更分支 %s（本地和远程都没有）。\n"
        "  请先确认已获得推送权限并执行：git fetch origin\n"
        "  如果同事还没推送，可请他先执行：git push -u origin %s\n"
        "  仅在本机测试时，可用 --branch %s 指定本地分支。" % (branch, branch, branch)
    )


# ---------------------------------------------------------------------------
# 记录复制
# ---------------------------------------------------------------------------


RECORD_FILES = ("变更单.md", "清单.json", "改动.diff")


def record_file_rel(rec_id, name):
    return "%s/%s/%s" % (RECORD_ROOT, rec_id, name)


def copy_record_from_branch(root, ref, rec_id):
    """把变更分支里的记录文件复制到当前工作区，返回覆盖的文件名列表。"""
    target = record_dir(root, rec_id)
    target.mkdir(parents=True, exist_ok=True)
    copied = []
    for name in RECORD_FILES:
        rel = record_file_rel(rec_id, name)
        if not branch_has_path(root, ref, rel):
            if name == "改动.diff":
                warn("变更分支里没有 改动.diff（旧版本记录），跳过复制。")
                continue
            fail("变更分支 %s 缺少记录文件：%s" % (ref, rel))
        write_text(target / name, read_branch_text(root, ref, rel))
        copied.append(name)
    return copied


def read_record_from_branch(root, ref, rec_id, name):
    rel = record_file_rel(rec_id, name)
    return read_branch_text(root, ref, rel)


# ---------------------------------------------------------------------------
# 构建检查
# ---------------------------------------------------------------------------


def find_swift_package_dir(root):
    for rel in ("macos", ""):
        package_dir = (root / rel) if rel else root
        if (package_dir / "Package.swift").is_file():
            return package_dir
    return None


def swift_files_in(entries):
    return [entry for entry in entries if entry["path"].endswith(".swift")]


def build_command():
    """返回构建命令列表与工作目录；由调用方决定是否执行。"""
    cmd = ["swift", "build", "-c", "release"]
    sdk = os.environ.get("ASSETFRAME_SWIFT_SDK", "").strip()
    if sdk:
        cmd.extend(["--sdk", os.path.expanduser(sdk)])
    flags = os.environ.get("ASSETFRAME_SWIFT_BUILD_FLAGS", "").strip()
    if flags:
        try:
            cmd.extend(shlex.split(flags))
        except ValueError as exc:
            fail("环境变量 ASSETFRAME_SWIFT_BUILD_FLAGS 无法解析：%s" % exc)
    scratch = os.environ.get("ASSETFRAME_SWIFT_SCRATCH_PATH", "").strip()
    if scratch:
        cmd.extend(["--scratch-path", os.path.expanduser(scratch)])
    return cmd


def build_timeout_seconds():
    raw = os.environ.get(BUILD_TIMEOUT_ENV, "").strip()
    if not raw:
        return DEFAULT_BUILD_TIMEOUT
    try:
        value = int(raw)
    except ValueError:
        fail("环境变量 %s 必须是整数秒：%s" % (BUILD_TIMEOUT_ENV, raw))
    if value <= 0:
        fail("环境变量 %s 必须大于 0：%s" % (BUILD_TIMEOUT_ENV, raw))
    return value


def run_build_check(root):
    """执行 Swift 构建检查，返回 (是否通过, 输出文本, 命令展示)。"""
    package_dir = find_swift_package_dir(root)
    if package_dir is None:
        fail(
            "检测到 .swift 文件，但找不到 Package.swift（应在 macos/Package.swift 或仓库根目录）。\n"
            "  若本轮不需要构建检查，请加 --no-build。"
        )
    cmd = build_command()
    timeout = build_timeout_seconds()
    display = " ".join(shlex.quote(part) for part in cmd)
    info("构建目录：%s" % package_dir)
    info("构建命令：%s" % display)
    info("超时上限：%d 秒（可用 %s 调整）" % (timeout, BUILD_TIMEOUT_ENV))
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(package_dir),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
    except FileNotFoundError:
        fail(
            "未找到 swift 命令，无法执行构建检查。\n"
            "  请确认已安装 Xcode/Command Line Tools，或加 --no-build 跳过构建。"
        )
    except subprocess.TimeoutExpired:
        return False, "构建超时（%d 秒），已终止。可用 %s 调整上限。" % (
            timeout,
            BUILD_TIMEOUT_ENV,
        ), display
    output = _decode(proc.stdout)
    return proc.returncode == 0, output, display


def output_tail(text, limit=6000):
    text = (text or "").strip("\n")
    if len(text) <= limit:
        return text
    return "……（省略前 %d 字节）……\n%s" % (len(text) - limit, text[-limit:])


# ---------------------------------------------------------------------------
# 变更单渲染（新建变更.py 使用）
# ---------------------------------------------------------------------------


def builtin_template():
    return """# 变更单 {{变更编号}}

- 变更编号：{{变更编号}}
- 负责人：{{负责人}}
- 创建日期：{{创建日期}}
- 目标：{{目标}}
- 基线 commit：{{基线 commit}}
- 变更分支：{{变更分支}}
- 当前状态：{{当前状态}}
- 变更文件数：{{变更文件数}}

## 一、目标与背景

{{目标}}

## 二、逐文件变更与采纳状态

> 「采纳状态」只能填写：采纳 / 不采纳 / 待定。
> 负责人必须把每个文件都改成「采纳」或「不采纳」后，才能运行审核应用脚本。

| 文件路径 | 类型 | +行/-行 | 说明 | 采纳状态 |
| --- | --- | --- | --- | --- |

## 三、风险与影响

- 风险：

## 四、验证方法

- 验证步骤：

## 五、审核结论（负责人填写）

- 结论：
- 备注：
"""


def read_template(root):
    path = root / TEMPLATE_PATH
    if path.is_file():
        return path.read_text(encoding="utf-8")
    warn("找不到模板 %s，改用内置模板。" % TEMPLATE_PATH)
    return builtin_template()


def render_new_form(root, manifest):
    template = read_template(root)
    values = {
        "变更编号": manifest["id"],
        "负责人": manifest.get("owner", ""),
        "创建日期": (manifest.get("created_at") or "")[:10],
        "目标": manifest.get("goal", ""),
        "基线 commit": "`%s`" % manifest.get("base_commit", ""),
        "变更分支": "`%s`" % manifest.get("branch", ""),
        "当前状态": "待提交",
        "变更文件数": "0",
    }
    text = template
    for key, value in values.items():
        text = text.replace("{{%s}}" % key, str(value))
    # 未替换的占位符统一留空，避免出现在正式记录里
    text = re.sub(r"\{\{[^}]+\}\}", "", text)
    return text
