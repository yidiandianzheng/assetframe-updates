#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""提交变更：生成改动清单/差异/逐文件说明表，校验说明后提交到 change 分支。

用法：
    python3 变更管理/工具/提交变更.py --id CHG-20261023-01
    python3 变更管理/工具/提交变更.py --id CHG-20261023-01 --check-only
    python3 变更管理/工具/提交变更.py --id CHG-20261023-01 --notes 说明.json

流程：
    1. 第一次运行：自动生成逐文件表格，说明列填占位文字，退出码 1；
    2. 按提示填写每个文件的「说明」，保持「采纳状态」为 待定；
    3. 运行 --check-only 校验说明是否填齐；
    4. 再运行（不带 --check-only）：提交记录与代码到 change/<ID> 分支，并打印 push 命令。
"""

import argparse
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import _common as c

MAX_SUBJECT_GOAL = 60


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="生成/更新变更记录并提交到 change/<变更ID> 分支（不会自动 push）。",
    )
    parser.add_argument("--id", required=True, help="变更编号，例如 CHG-20261023-01")
    parser.add_argument("--summary", help="可选的提交标题摘要；默认使用变更目标")
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="只校验说明是否填齐，不写文件、不提交",
    )
    parser.add_argument(
        "--notes",
        help="说明文件：.json 为 {文件路径: 说明}；其它按 `文件路径<TAB>说明` 逐行填写",
    )
    return parser.parse_args(argv)


def _main_ref(root):
    for ref in ("origin/main", "main"):
        if c.ref_exists(root, ref):
            return ref
    c.fail("找不到 main 或 origin/main 分支，无法计算变更基线。")


def _merge_base(root, ref_a, ref_b):
    proc = c.run_git(root, ["merge-base", ref_a, ref_b], check=False)
    if proc.returncode != 0:
        c.fail("无法计算 %s 与当前分支的共同祖先（两者可能没有历史关联）。" % ref_a)
    return c._decode(proc.stdout).strip()


def run(argv=None):
    args = parse_args(argv)
    rec_id = args.id.strip()
    c.validate_change_id(rec_id)

    root = c.git_root(Path(__file__).resolve().parent)
    c.info("仓库根目录：%s" % root)

    branch = c.current_branch(root)
    expected = "change/%s" % rec_id
    if branch != expected:
        c.fail(
            "提交变更必须在 %s 分支执行，当前分支是：%s。\n"
            "  请先执行：git switch %s" % (expected, branch or "（游离 HEAD）", expected)
        )

    if not c.manifest_path(root, rec_id).is_file():
        c.fail(
            "找不到变更记录：%s\n"
            "  请确认已经运行 新建变更.py，或者当前不在正确的仓库。" % c.manifest_path(root, rec_id)
        )
    manifest = c.load_manifest(root, rec_id)
    if manifest.get("branch") and manifest["branch"] != expected:
        c.fail(
            "清单里的分支（%s）与当前分支（%s）不一致，记录可能已被手工改动，请核对。"
            % (manifest["branch"], expected)
        )

    c.step("检查暂存区与基线")
    c.require_empty_staged(
        root,
        action_hint="请先提交或取消暂存这些内容，再运行本脚本（脚本只应提交本次变更）。",
    )
    main_ref = _main_ref(root)
    merge_base = _merge_base(root, main_ref, "HEAD")
    recorded_base = manifest.get("base_commit", "")
    if recorded_base and recorded_base != merge_base:
        c.warn(
            "检测到变更基线已变化（可能是 rebase 到最新 main）：%s → %s"
            % (c.short_sha(recorded_base), c.short_sha(merge_base))
        )
        c.hint("清单与变更单里的基线 commit 会自动更新为 %s。" % merge_base)
    if not c.is_ancestor(root, merge_base, "HEAD"):
        c.fail("内部校验失败：merge-base 不是当前分支的祖先。")
    merge_count = c.git_text(root, ["rev-list", "--count", "--merges", "%s..HEAD" % merge_base])
    if merge_count != "0":
        c.warn("当前分支含 %s 个合并提交，可能把 main 的改动计入本次变更。" % merge_count)
        c.hint("建议用 rebase 而不是 merge 同步 main（git rebase origin/main）。")
    c.ok("当前分支：%s；基线：%s（%s）" % (branch, c.short_sha(merge_base), main_ref))

    c.step("计算本次改动")
    untracked = c.untracked_change_files(root)
    if untracked:
        c.info("发现 %d 个未跟踪文件，将一并纳入变更清单：" % len(untracked))
        for path in untracked[:20]:
            c.info("  + %s" % path)
        if len(untracked) > 20:
            c.info("  …… 共 %d 个" % len(untracked))
    intent_added = False
    try:
        if untracked:
            # git add -N：让未跟踪文件参与重命名检测与完整 diff，但先不真正暂存
            c.run_git(root, ["add", "-N", "--"] + untracked)
            intent_added = True
        entries = c.diff_entries_worktree(root, merge_base)
        diff_text = c.diff_text_worktree(root, merge_base)
    finally:
        if intent_added:
            c.run_git(root, ["reset", "-q", "--"] + untracked, check=False)

    metadata_warnings = _metadata_warnings(root, merge_base, rec_id)
    if metadata_warnings:
        c.warn("检测到 变更管理/ 下的其它改动（不会进入本次变更清单）：")
        for item in metadata_warnings:
            c.warn("  %s" % item)
        c.hint("这些改动请单独处理；变更记录/索引会随本脚本自动提交。")

    if not entries:
        c.fail(
            "当前分支相对基线 %s 没有任何文件变化，无从提交。\n"
            "  请先在 change/%s 分支修改文件。" % (c.short_sha(merge_base), rec_id)
        )
    c.ok("共 %d 个文件：%s" % (len(entries), c.summarize_actions(entries)))
    for desc in c.describe_entries(entries):
        c.info("  " + desc)

    c.step("整理逐文件说明")
    form_text = c.read_form(root, rec_id)
    parsed = c.parse_change_form(form_text)
    existing_rows = parsed["rows"]
    notes = {}
    if args.notes:
        notes = c.parse_notes_file(args.notes)
        unknown = sorted(set(notes) - {item["path"] for item in entries})
        if unknown:
            c.fail(
                "说明文件里包含不在本次变更中的路径：\n"
                + "\n".join("    - " + p for p in unknown)
                + "\n  请删除这些条目或确认路径写法。"
            )
    stale_rows = sorted(set(existing_rows) - {item["path"] for item in entries})
    if stale_rows:
        c.warn("变更单里有过期文件行（本次改动中已不存在），将自动移除：")
        for path in stale_rows[:20]:
            c.warn("  - %s" % path)

    missing = []
    for entry in entries:
        path = entry["path"]
        old_row = existing_rows.get(path, {})
        note = notes.get(path)
        if note is None:
            note = old_row.get("note", "")
        note = (note or "").strip()
        if not note or note == c.PLACEHOLDER_NOTE:
            note = c.PLACEHOLDER_NOTE
            missing.append(path)
        entry["note"] = note
        status = (old_row.get("adopt") or "待定").strip()
        if status not in c.ALLOWED_ADOPT:
            c.fail(
                "变更单里 %s 的「采纳状态」不合法：%r\n  只能填写：%s"
                % (path, status, " / ".join(c.ALLOWED_ADOPT))
            )
        entry["adopt"] = status

    if args.check_only:
        if missing:
            _print_missing(c, missing)
            c.fail("说明未填齐：还有 %d 个文件需要填写说明（--check-only 不写文件）。" % len(missing))
        c.ok("说明校验通过：%d 个文件均已填写说明。" % len(entries))
        c.hint("可以运行（去掉 --check-only）提交：python3 变更管理/工具/提交变更.py --id %s" % rec_id)
        return 0

    # 写回记录文件（先写占位说明也需要落盘，方便同事直接在变更单里填写）
    form_text = c.apply_form_table(form_text, entries)
    form_text = c.update_form_status(
        form_text,
        "待审核",
        {
            "基线 commit": "`%s`" % merge_base,
            "变更分支": "`%s`" % expected,
            "变更文件数": str(len(entries)),
        },
    )
    manifest["base_commit"] = merge_base
    manifest["status"] = "待审核"
    manifest["files"] = [
        {
            "path": entry["path"],
            "old_path": entry["old_path"],
            "action": entry["action"],
            "type_label": entry["type_label"],
            "added": entry["added"],
            "deleted": entry["deleted"],
            "note": entry["note"],
        }
        for entry in entries
    ]
    c.save_manifest(root, rec_id, manifest)
    c.write_text(c.form_path(root, rec_id), form_text)
    c.write_text(c.diff_path(root, rec_id), diff_text)
    c.update_index(root, manifest, status="待审核", adopted="-", reverted="-")
    c.ok("已更新：变更单 / 清单 / 改动.diff / 索引。")

    if missing:
        _print_missing(c, missing)
        c.warn("尚未提交：请填写完说明后重新运行（或先 --check-only 校验）。")
        c.line()
        c.line("说明填写方式（任选其一）：")
        c.line("  A. 直接编辑 %s 的「说明」列，填好后重跑本脚本。" % c.form_path(root, rec_id).relative_to(root))
        c.line("  B. 复制一个说明文件（JSON：{\"路径\": \"说明\"}），用 --notes 传入。")
        c.line("     注意：不要把「采纳状态」改成采纳/不采纳，那是负责人的工作。")
        return 1

    c.step("提交到 change 分支")
    commit_paths = [c.RECORD_ROOT + "/" + rec_id, c.INDEX_PATH]
    for entry in entries:
        commit_paths.append(entry["path"])
        if entry["old_path"]:
            commit_paths.append(entry["old_path"])
    subject_goal = (args.summary or manifest.get("goal") or "").strip() or "变更提交"
    subject = "变更 %s: %s" % (rec_id, subject_goal[:MAX_SUBJECT_GOAL])
    body_one = "变更文件 %d 个：%s。" % (len(entries), c.summarize_actions(entries))
    body_two = "\n".join(c.describe_entries(entries))
    commit_sha = c.stage_and_commit(root, subject, (body_one, body_two), commit_paths)
    c.ok("已提交：%s %s" % (c.short_sha(commit_sha), subject))

    c.step("完成")
    c.info("变更单：%s" % c.form_path(root, rec_id).relative_to(root))
    c.line()
    c.line("请把分支推送到私有仓库（脚本不会自动 push）：")
    c.line("  git push -u origin %s" % expected)
    c.line()
    c.line("推送后请通知负责人审核；负责人将逐文件标记采纳状态并运行：")
    c.line("  git fetch origin && python3 变更管理/工具/审核应用.py --id %s" % rec_id)
    return 0


def _metadata_warnings(root, merge_base, rec_id):
    """找出 变更管理/ 下不会被本脚本提交的改动。"""
    all_entries = []
    for path in c.git_z(root, ["diff", "--name-only", "-z", merge_base]):
        if not c.is_metadata_path(path):
            continue
        if path == c.INDEX_PATH or path.startswith(c.RECORD_ROOT + "/" + rec_id):
            continue
        all_entries.append(path)
    return all_entries


def _print_missing(c, missing):
    c.line()
    c.warn("以下 %d 个文件还没有填写说明：" % len(missing))
    for path in missing:
        c.warn("  - %s" % path)


def main(argv=None):
    return c.run_cli("=== 变更管理 · 提交变更 ===", run, argv)


if __name__ == "__main__":
    sys.exit(main())
