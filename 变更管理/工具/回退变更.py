#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""回退变更（“回调”）：按应用记录把采纳文件恢复到应用前版本并提交。

用法：
    python3 变更管理/工具/回退变更.py --id CHG-20261023-01 --dry-run
    python3 变更管理/工具/回退变更.py --id CHG-20261023-01
    python3 变更管理/工具/回退变更.py --id CHG-20261023-01 --force

说明：
    - 读取 变更管理/记录/<ID>/应用记录.json 里最近一次未回退的应用；
    - 把当时采纳的文件恢复到应用前版本，新增文件删除、重命名还原；
    - 提交 "回退变更 <ID>" 并更新索引/记录；
    - 只回退源码；App 需要重新打包安装后才会生效。
"""

import argparse
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import _common as c

REVERT_TITLE = "=== 变更管理 · 回退变更 ==="


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="按应用记录回退已采纳的变更（不 push）。",
    )
    parser.add_argument("--id", required=True, help="变更编号，例如 CHG-20261023-01")
    parser.add_argument("--dry-run", action="store_true", help="只检查并预演，不写文件、不提交")
    parser.add_argument("--force", action="store_true", help="文件在采纳后被其它提交改过时仍强制回退")
    return parser.parse_args(argv)


def _find_application(app_record):
    applications = app_record.get("applications") or []
    if not applications:
        c.fail("应用记录里没有任何应用历史，无法回退。")
    for application in reversed(applications):
        if not application.get("reverted_at"):
            return application
    c.fail("该变更的所有应用记录都已回退过，没有可回退的内容。")


def _conflicts(root, application):
    conflicts = []
    for entry in application.get("files", []):
        for post in entry.get("post", []):
            rel = post["path"]
            exists_now = (root / rel).exists()
            if post.get("exists"):
                if not exists_now:
                    conflicts.append("%s（已被删除或改名）" % rel)
                    continue
                current_sha = c.hash_worktree_file(root, rel) or ""
                if current_sha != post.get("sha"):
                    conflicts.append("%s（内容在采纳后被修改）" % rel)
                if not c.path_exists_in_commit(root, "HEAD", rel):
                    conflicts.append("%s（已不在当前提交中）" % rel)
            else:
                if exists_now:
                    conflicts.append("%s（本应不存在，但又被创建了）" % rel)
    return conflicts


def _restore_entry(root, before_commit, entry):
    action = entry.get("action")
    path = entry["path"]
    old_path = entry.get("old_path")
    if action == "A":
        if (root / path).exists():
            c.run_git(root, ["rm", "-q", "-f", "--", path])
        c.info("  删除新增文件 %s" % path)
    elif action == "D":
        c.run_git(root, ["checkout", before_commit, "--", path])
        c.info("  恢复被删除文件 %s" % path)
    elif action == "R":
        if not old_path:
            c.fail("应用记录里的重命名缺少旧路径：%s" % path)
        if entry.get("pre_exists_primary"):
            c.run_git(root, ["checkout", before_commit, "--", path])
        elif (root / path).exists():
            c.run_git(root, ["rm", "-q", "-f", "--", path])
        c.run_git(root, ["checkout", before_commit, "--", old_path])
        c.info("  还原重命名 %s → %s" % (path, old_path))
    else:  # M
        c.run_git(root, ["checkout", before_commit, "--", path])
        c.info("  恢复修改前版本 %s" % path)


def run(argv=None):
    args = parse_args(argv)
    rec_id = args.id.strip()
    c.validate_change_id(rec_id)

    root = c.git_root(Path(__file__).resolve().parent)
    branch = c.current_branch(root)
    c.info("仓库根目录：%s" % root)
    if branch != "main":
        c.fail("回退变更必须在 main 分支执行，当前分支是：%s。\n  请先执行：git switch main" % (branch or "（游离 HEAD）"))

    c.step("读取应用记录")
    app_record = c.load_application_record(root, rec_id)
    application = _find_application(app_record)
    files = application.get("files") or []
    before_commit = application.get("before_commit") or ""
    if not files:
        c.fail("最近一次应用记录里没有采纳文件，无需/无法回退。")
    if not before_commit:
        c.fail("应用记录缺少 before_commit 字段，记录可能已损坏。")
    if not c.ref_exists(root, before_commit):
        c.fail("应用前提交 %s 已不存在于仓库中，无法安全回退。" % c.short_sha(before_commit))
    if not c.is_ancestor(root, before_commit, "HEAD"):
        c.fail(
            "应用前提交 %s 不是当前 main 的祖先（main 历史可能被改写/重置）。\n"
            "  无法自动回退，请人工核对后处理。" % c.short_sha(before_commit)
        )
    c.ok(
        "找到应用记录：%s，应用前提交 %s，采纳 %d 个文件。"
        % (application.get("applied_at", "时间未知"), c.short_sha(before_commit), len(files))
    )

    c.step("检查工作区与文件状态")
    c.require_clean_for_apply(root, rec_id)
    conflicts = _conflicts(root, application)
    if conflicts:
        message = "以下文件在采纳之后又被其它提交改动过，直接回退会覆盖这些改动：\n" + "\n".join(
            "    - " + item for item in conflicts
        )
        if not args.force:
            c.fail(
                message
                + "\n  处理：确认这些改动可以放弃后，加 --force 再执行回退。"
            )
        c.warn(message)
        c.warn("已按 --force 继续；回退会覆盖上述文件。")
    else:
        c.ok("所有待回退文件自采纳后未被其它提交改动。")

    c.step("回退计划")
    for entry in files:
        label = c.TYPE_LABELS.get(entry.get("action"), "修改")
        c.info("%s %s%s" % (label, entry["path"], ("（旧路径：%s）" % entry["old_path"]) if entry.get("old_path") else ""))

    if args.dry_run:
        c.step("预演结果（--dry-run，未做任何修改）")
        c.ok("预演通过。正式运行会把上述文件恢复到 %s 提交时的内容并提交回退。" % c.short_sha(before_commit))
        return 0

    c.step("恢复文件")
    for entry in files:
        _restore_entry(root, before_commit, entry)

    c.step("更新记录与索引")
    application["reverted_at"] = c.now_str()
    c.save_application_record(root, rec_id, app_record)

    manifest = c.load_manifest(root, rec_id)
    form_text = c.read_form(root, rec_id)
    form_text = c.update_form_status(form_text, "已回退", {"基线 commit": "`%s`" % manifest.get("base_commit", "")})
    c.write_text(c.form_path(root, rec_id), form_text)
    manifest["status"] = "已回退"
    c.save_manifest(root, rec_id, manifest)
    adopted_label = "%s/%s" % (
        application.get("adopted_count", len(files)),
        application.get("total_count", len(files)),
    )
    reverted_time = c.now_minute()
    c.update_index(
        root,
        manifest,
        status="已回退",
        adopted=adopted_label,
        reverted=reverted_time,
    )
    c.ok("索引已更新：状态 已回退，回退时间 %s。" % reverted_time)

    c.step("提交回退")
    commit_paths = [c.RECORD_ROOT + "/" + rec_id, c.INDEX_PATH]
    for entry in files:
        commit_paths.append(entry["path"])
        if entry.get("old_path"):
            commit_paths.append(entry["old_path"])
    subject = "回退变更 %s" % rec_id
    body_lines = [
        "回退应用时间：%s（应用前提交 %s）" % (application.get("applied_at", "未知"), c.short_sha(before_commit)),
        "回退文件：\n%s" % "\n".join(c.describe_entries(files)),
    ]
    commit_sha = c.stage_and_commit(root, subject, tuple(body_lines), commit_paths)
    c.ok("已提交：%s %s" % (c.short_sha(commit_sha), subject))

    c.step("完成")
    c.ok("源码已回退，需重新打包安装才生效。")
    if any(entry["path"].endswith(".swift") for entry in files):
        c.info("本次回退包含 Swift 源码，App 必须重新打包安装：")
        c.info("  cd macos && ./package-app.sh")
    else:
        c.info("本次回退未涉及 Swift 源码；如涉及运行脚本/文档，请按需重新使用。")
    c.line()
    c.line("下一步：")
    c.line("  1. 如需推送 main：git push origin main（请确认已有授权）。")
    c.line("  2. 重新打包并替换安装版 App，回退才会真正生效。")
    c.line("  3. 如要再次采纳同一变更：python3 变更管理/工具/审核应用.py --id %s" % rec_id)
    return 0


def main(argv=None):
    return c.run_cli(REVERT_TITLE, run, argv)


if __name__ == "__main__":
    sys.exit(main())
