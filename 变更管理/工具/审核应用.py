#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""审核应用：负责人逐文件确认采纳/不采纳后，把采纳文件应用到 main 并提交。

用法：
    # 第 1 步：第一次运行会把变更单复制到 main 工作区，提示逐文件标注
    python3 变更管理/工具/审核应用.py --id CHG-20261023-01
    # 第 2 步：编辑 变更管理/记录/<ID>/变更单.md，把每个文件改成 采纳 / 不采纳
    # 第 3 步：预演（不写文件、不提交、不构建）
    python3 变更管理/工具/审核应用.py --id CHG-20261023-01 --dry-run
    # 第 4 步：正式应用（涉及 .swift 会先跑 swift build -c release，失败自动恢复）
    python3 变更管理/工具/审核应用.py --id CHG-20261023-01

脚本不会 push；成功后打印 push 与回退命令。
"""

import argparse
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import _common as c

APPLY_TITLE = "=== 变更管理 · 审核应用 ==="


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="按变更单逐文件采纳，应用到 main 并提交（不 push）。",
    )
    parser.add_argument("--id", required=True, help="变更编号，例如 CHG-20261023-01")
    parser.add_argument("--dry-run", action="store_true", help="只校验并预演，不写文件、不构建、不提交")
    parser.add_argument("--no-build", action="store_true", help="跳过 Swift 构建检查（涉及 .swift 时默认会构建）")
    parser.add_argument("--branch", help="指定变更分支引用（默认优先 origin/change/<ID>，其次 change/<ID>）")
    parser.add_argument("--refresh-record", action="store_true", help="用变更分支的最新记录覆盖工作区记录（会丢失当前标注）")
    parser.add_argument("--allow-overwrite", action="store_true", help="main 在基线后改过同一文件时仍强制应用（谨慎）")
    return parser.parse_args(argv)


def _entry_key(entry):
    return (entry.get("action", ""), entry.get("old_path") or "", entry["path"])


def _describe(key):
    action, old_path, path = key
    label = c.TYPE_LABELS.get(action, action or "修改")
    if old_path:
        return "%s %s（旧路径：%s）" % (label, path, old_path)
    return "%s %s" % (label, path)


def _compare_manifests(worktree_manifest, branch_manifest):
    diffs = []
    for field in ("id", "owner", "branch", "base_commit"):
        left = worktree_manifest.get(field)
        right = branch_manifest.get(field)
        if left != right:
            diffs.append("%s：工作区 %r / 分支 %r" % (field, left, right))
    left_files = {_entry_key(item) for item in worktree_manifest.get("files", [])}
    right_files = {_entry_key(item) for item in branch_manifest.get("files", [])}
    for key in sorted(left_files - right_files):
        diffs.append("工作区多出文件：%s" % _describe(key))
    for key in sorted(right_files - left_files):
        diffs.append("分支更新了文件：%s" % _describe(key))
    return diffs


def _validate_branch_diff(actual_entries, manifest_entries):
    actual = {_entry_key(item) for item in actual_entries}
    wanted = {_entry_key(item) for item in manifest_entries}
    if actual == wanted:
        return
    lines = []
    for key in sorted(wanted - actual):
        lines.append("    - 清单有、分支实际没有：%s" % _describe(key))
    for key in sorted(actual - wanted):
        lines.append("    - 分支实际有、清单没有：%s" % _describe(key))
    c.fail(
        "变更清单（清单.json）与分支的实际改动不一致，清单已过期。\n"
        + "\n".join(lines)
        + "\n  处理：请同事在 change 分支重新运行 提交变更.py 后重新审核。"
    )


def _drift_conflicts(root, base_commit, adopted):
    """检查 main 在基线之后是否改过本次要采纳的文件。"""
    conflicts = []
    main_head = c.head_commit(root)
    for entry in adopted:
        paths = [entry["path"]]
        if entry.get("old_path"):
            paths.append(entry["old_path"])
        for path in paths:
            changed = c.git_z(root, ["diff", "--name-only", "-z", base_commit, main_head, "--", path])
            if changed:
                conflicts.append("%s（main 在基线后改过）" % path)
        if entry["action"] == "A" and c.path_exists_in_commit(root, main_head, entry["path"]):
            conflicts.append("%s（main 上已存在同名新文件）" % entry["path"])
    return conflicts


def _apply_entry(root, ref, entry):
    action = entry["action"]
    path = entry["path"]
    old_path = entry.get("old_path")
    pre_exists_primary = c.path_exists_in_commit(root, "HEAD", path)
    record = {
        "path": path,
        "old_path": old_path,
        "action": action,
        "pre_exists_primary": pre_exists_primary,
        "post": [],
    }
    if action == "D":
        if not pre_exists_primary:
            c.fail("要删除的文件在 main 上不存在：%s" % path)
        c.run_git(root, ["rm", "-q", "--", path])
        record["post"] = [{"path": path, "exists": False}]
        c.info("  删除 %s" % path)
    elif action == "R":
        if not old_path:
            c.fail("重命名记录缺少旧路径：%s" % path)
        c.run_git(root, ["checkout", ref, "--", path])
        c.run_git(root, ["rm", "-q", "--", old_path])
        sha = c.hash_worktree_file(root, path) or ""
        record["post"] = [
            {"path": path, "exists": True, "sha": sha},
            {"path": old_path, "exists": False},
        ]
        c.info("  重命名 %s → %s" % (old_path, path))
    else:  # A / M
        c.run_git(root, ["checkout", ref, "--", path])
        sha = c.hash_worktree_file(root, path) or ""
        record["post"] = [{"path": path, "exists": True, "sha": sha}]
        c.info("  %s %s" % ("新增" if action == "A" else "修改", path))
    return record


def _restore_worktree(root, before_commit, applied):
    c.warn("正在把工作区恢复到审核前状态……")
    c.run_git(root, ["reset", "-q", "--hard", before_commit], check=False)
    for record in applied:
        if not record["pre_exists_primary"]:
            full = root / record["path"]
            if full.exists() and not c.path_exists_in_commit(root, before_commit, record["path"]):
                try:
                    full.unlink()
                except OSError:
                    pass
    dirty = set(c.git_z(root, ["diff", "--name-only", "-z"]))
    dirty |= set(c.git_z(root, ["diff", "--cached", "--name-only", "-z"]))
    if dirty:
        c.warn("恢复后仍有未提交改动，请人工检查：")
        for path in sorted(dirty):
            c.warn("  - %s" % path)
    else:
        c.ok("工作区已恢复到审核前状态。")
    for record in applied:
        c.info("  已恢复：%s" % record["path"])


def _update_status(rec_id, adopted, total):
    if total <= 0:
        return "不采纳"
    if len(adopted) == 0:
        return "不采纳"
    if len(adopted) == total:
        return "已采纳"
    return "部分采纳"


def run(argv=None):
    args = parse_args(argv)
    rec_id = args.id.strip()
    c.validate_change_id(rec_id)

    root = c.git_root(Path(__file__).resolve().parent)
    branch = c.current_branch(root)
    c.info("仓库根目录：%s" % root)
    if branch != "main":
        c.fail("审核应用必须在 main 分支执行，当前分支是：%s。\n  请先执行：git switch main" % (branch or "（游离 HEAD）"))
    c.require_clean_for_apply(root, rec_id)

    c.step("定位变更分支")
    ref, ref_sha = c.resolve_change_ref(root, rec_id, args.branch)
    c.ok("变更分支：%s（%s）" % (ref, c.short_sha(ref_sha)))

    branch_manifest_text = c.read_record_from_branch(root, ref, rec_id, "清单.json")
    try:
        import json as _json

        branch_manifest = _json.loads(branch_manifest_text)
    except Exception as exc:
        c.fail("变更分支里的 清单.json 无法解析：%s" % exc)
    if branch_manifest.get("id") != rec_id:
        c.fail("变更分支记录里的编号（%s）与 --id 不一致。" % branch_manifest.get("id"))
    if branch_manifest.get("branch") and branch_manifest.get("branch") != "change/" + rec_id:
        c.fail("清单里记录的分支是 %s，与预期 change/%s 不一致。" % (branch_manifest["branch"], rec_id))
    base_commit = branch_manifest.get("base_commit") or ""
    if not base_commit or not c.ref_exists(root, base_commit):
        c.fail("清单里的基线 commit 无效：%r" % base_commit)

    c.step("校验基线与分支")
    if not c.is_ancestor(root, base_commit, ref_sha):
        c.fail(
            "变更分支不是从记录的基线提交派生的（基线 %s 不是 %s 的祖先）。\n"
            "  处理：请同事在 change 分支执行 git rebase origin/main，然后重新运行 提交变更.py 刷新基线。"
            % (c.short_sha(base_commit), ref)
        )
    main_head = c.head_commit(root)
    if not c.is_ancestor(root, base_commit, main_head):
        c.fail(
            "基线漂移：变更基线 %s 不是当前 main（%s）的祖先。\n"
            "  main 历史可能被改写，或变更分支与当前 main 没有共同历史。\n"
            "  处理（二选一）：\n"
            "    1. 请同事在 change 分支执行 git rebase origin/main，再运行 提交变更.py 刷新基线；\n"
            "    2. 基于当前 main 重新创建变更并重新提交。"
            % (c.short_sha(base_commit), c.short_sha(main_head))
        )
    c.ok("基线 %s 是当前 main（%s）的祖先。" % (c.short_sha(base_commit), c.short_sha(main_head)))

    c.step("核对清单与分支实际改动")
    actual_entries = c.diff_entries_ref(root, base_commit, ref)
    manifest_entries = branch_manifest.get("files") or []
    _validate_branch_diff(actual_entries, manifest_entries)
    c.ok("清单与分支实际改动一致：%d 个文件（%s）。" % (len(actual_entries), c.summarize_actions(actual_entries)))

    c.step("准备记录与逐文件标注")
    rec_dir = c.record_dir(root, rec_id)
    worktree_has_record = c.form_path(root, rec_id).is_file() and c.manifest_path(root, rec_id).is_file()
    copied = False
    if worktree_has_record:
        worktree_manifest = c.load_manifest(root, rec_id)
        diffs = _compare_manifests(worktree_manifest, branch_manifest)
        if diffs:
            if args.refresh_record:
                c.warn("工作区记录与分支不一致，按 --refresh-record 覆盖（当前标注会丢失）：")
                for item in diffs:
                    c.warn("  " + item)
                c.copy_record_from_branch(root, ref, rec_id)
                copied = True
            else:
                c.fail(
                    "工作区里的变更记录与变更分支不一致（同事可能更新了分支）：\n"
                    + "\n".join("    - " + item for item in diffs)
                    + "\n  处理：确认后加 --refresh-record 重新复制分支记录（会丢失当前标注），或手工核对。"
                )
    else:
        if args.dry_run:
            c.warn("工作区尚无变更记录；--dry-run 不会复制。正式运行时会把分支记录复制到工作区供标注。")
        else:
            copied_files = c.copy_record_from_branch(root, ref, rec_id)
            copied = True
            c.ok("已把 %s 复制到工作区：%s" % (ref, "、".join(copied_files)))

    if copied or worktree_has_record:
        form_text = c.read_form(root, rec_id)
    else:
        form_text = c.read_record_from_branch(root, ref, rec_id, "变更单.md")
    parsed = c.parse_change_form(form_text)
    adopt_map = {}
    pending = []
    missing_rows = []
    for entry in manifest_entries:
        row = parsed["rows"].get(entry["path"])
        if not row:
            missing_rows.append(entry["path"])
            continue
        status = (row.get("adopt") or "").strip()
        if status not in c.ALLOWED_ADOPT:
            c.fail(
                "文件 %s 的「采纳状态」不合法：%r\n  只能填写：%s"
                % (entry["path"], status, " / ".join(c.ALLOWED_ADOPT))
            )
        if status == "待定":
            pending.append(entry["path"])
        adopt_map[entry["path"]] = status
    stray = sorted(set(parsed["rows"]) - {entry["path"] for entry in manifest_entries})
    if stray:
        c.warn("变更单里存在清单之外的文件行（将被忽略，建议重新生成变更单）：")
        for path in stray:
            c.warn("  - %s" % path)
    if missing_rows:
        c.fail(
            "变更单缺少以下文件的表格行（记录可能不完整）：\n"
            + "\n".join("    - " + path for path in missing_rows)
            + "\n  处理：加 --refresh-record 重新复制分支记录，或让同事重新运行 提交变更.py。"
        )
    if pending:
        c.line()
        c.warn("还有 %d 个文件没有标注采纳状态（当前为 待定）：" % len(pending))
        for path in pending:
            c.warn("  - %s" % path)
        c.line()
        target_form = c.form_path(root, rec_id)
        if target_form.is_file():
            c.line("请编辑：%s" % target_form.relative_to(root))
        else:
            c.line("请编辑：变更单")
        c.line("把每个文件的「采纳状态」改为 采纳 或 不采纳，然后重新运行本脚本。")
        c.line("只想先看计划可用：--dry-run（校验通过后不会写文件）。")
        return 1

    adopted = [entry for entry in manifest_entries if adopt_map.get(entry["path"]) == "采纳"]
    rejected = [entry for entry in manifest_entries if adopt_map.get(entry["path"]) == "不采纳"]
    total = len(manifest_entries)
    c.ok("标注完整：采纳 %d / 不采纳 %d / 共 %d。" % (len(adopted), len(rejected), total))

    c.step("检查 main 是否在基线后改过待采纳文件")
    conflicts = _drift_conflicts(root, base_commit, adopted)
    if conflicts:
        message = "main 在基线后改过以下待采纳文件，直接应用会覆盖 main 上的新改动：\n" + "\n".join(
            "    - " + item for item in conflicts
        )
        if not args.allow_overwrite:
            c.fail(
                message
                + "\n  处理（推荐）：请同事 git rebase origin/main 后重新提交变更，再审核。\n"
                "  确需覆盖时，加 --allow-overwrite 再运行。"
            )
        c.warn(message)
        c.warn("已按 --allow-overwrite 继续（请确认覆盖是预期行为）。")
    else:
        c.ok("未发现同文件冲突。")

    swift_adopted = c.swift_files_in(adopted)
    if not adopted:
        build_note = "无采纳文件，未执行构建检查"
    elif swift_adopted and args.no_build:
        build_note = "涉及 Swift 文件，已按 --no-build 跳过构建检查"
    elif swift_adopted:
        build_note = "待执行 swift build -c release"
    else:
        build_note = "未涉及 Swift 文件，跳过构建检查"

    if args.dry_run:
        c.step("预演结果（--dry-run，未做任何修改）")
        c.info("将采纳 %d 个文件：" % len(adopted))
        for entry in adopted:
            c.info("  + %s" % _describe(_entry_key(entry)))
        if rejected:
            c.info("不采纳 %d 个文件：" % len(rejected))
            for entry in rejected:
                c.info("  - %s" % _describe(_entry_key(entry)))
        c.info("构建检查：%s" % build_note)
        c.ok("预演通过。正式运行时会把采纳文件应用到 main 并提交（不会 push）。")
        return 0

    c.step("检查历史应用记录")
    app_record = c.load_application_record(root, rec_id)
    active = [app for app in app_record.get("applications", []) if not app.get("reverted_at")]
    if active and active[-1].get("files"):
        c.fail(
            "该变更已有未回退的应用记录（应用时间：%s）。\n"
            "  请先运行：python3 变更管理/工具/回退变更.py --id %s"
            % (active[-1].get("applied_at", "未知"), rec_id)
        )

    if not adopted:
        c.step("记录全部不采纳")
        status = "不采纳"
        form_text = c.update_form_status(form_text, status, {"基线 commit": "`%s`" % base_commit})
        c.write_text(c.form_path(root, rec_id), form_text)
        branch_manifest["status"] = status
        c.save_manifest(root, rec_id, branch_manifest)
        c.update_index(root, branch_manifest, status=status, adopted="0/%d" % total, reverted="-")
        subject = "采纳变更 %s: 0/%d 个文件" % (rec_id, total)
        body = "审核结论：全部不采纳（0/%d）。\n\n不采纳文件：\n%s" % (
            total,
            "\n".join(c.describe_entries(rejected)) or "（无）",
        )
        commit_sha = c.stage_and_commit(
            root, subject, (body,), [c.RECORD_ROOT + "/" + rec_id, c.INDEX_PATH]
        )
        c.ok("已记录审核结论并提交：%s %s" % (c.short_sha(commit_sha), subject))
        c.line()
        c.line("如需推送 main：git push origin main（请确认已有授权）。")
        return 0

    before_commit = c.head_commit(root)
    applied = []
    c.step("应用采纳文件")
    try:
        for entry in adopted:
            applied.append(_apply_entry(root, ref, entry))
        if swift_adopted and not args.no_build:
            c.step("Swift 构建检查")
            build_ok, build_output, build_display = c.run_build_check(root)
            if not build_ok:
                c.line(c.output_tail(build_output))
                c.fail(
                    "构建检查失败（命令：%s）。\n  已中止，不会提交；接下来恢复工作区。" % build_display
                )
            build_note = "构建检查通过（%s）" % build_display
            c.ok("构建检查通过。")
    except Exception:
        _restore_worktree(root, before_commit, applied)
        raise

    c.step("写入应用记录与索引")
    try:
        _finalize_application(
            root, rec_id, ref, base_commit, form_text, branch_manifest, app_record,
            adopted, rejected, total, applied, before_commit, build_note,
            swift_adopted,
        )
    except Exception:
        if c.head_commit(root) == before_commit and c.current_branch(root) == "main":
            _restore_worktree(root, before_commit, applied)
        else:
            c.warn("写入/提交阶段出错，但已有新提交存在，未执行自动重置；请人工检查 git 状态。")
        raise
    return 0


def _finalize_application(
    root, rec_id, ref, base_commit, form_text, branch_manifest, app_record,
    adopted, rejected, total, applied, before_commit, build_note,
    swift_adopted,
):
    application = {
        "applied_at": c.now_str(),
        "before_commit": before_commit,
        "change_ref": ref,
        "build": build_note,
        "total_count": total,
        "adopted_count": len(adopted),
        "rejected": [entry["path"] for entry in rejected],
        "files": applied,
        "reverted_at": None,
    }
    app_record["id"] = rec_id
    app_record["change_branch"] = "change/" + rec_id
    app_record["base_commit"] = base_commit
    app_record.setdefault("applications", []).append(application)
    c.save_application_record(root, rec_id, app_record)

    status = _update_status(rec_id, adopted, total)
    form_text = c.update_form_status(form_text, status, {"基线 commit": "`%s`" % base_commit})
    c.write_text(c.form_path(root, rec_id), form_text)
    branch_manifest["status"] = status
    branch_manifest["base_commit"] = base_commit
    c.save_manifest(root, rec_id, branch_manifest)
    c.update_index(
        root,
        branch_manifest,
        status=status,
        adopted="%d/%d" % (len(adopted), total),
        reverted="-",
    )
    c.ok("索引状态：%s；采纳文件数：%d/%d。" % (status, len(adopted), total))

    c.step("提交到 main")
    commit_paths = [c.RECORD_ROOT + "/" + rec_id, c.INDEX_PATH]
    for entry in adopted:
        commit_paths.append(entry["path"])
        if entry.get("old_path"):
            commit_paths.append(entry["old_path"])
    subject = "采纳变更 %s: %d/%d 个文件" % (rec_id, len(adopted), total)
    body_lines = [
        "变更目标：%s" % (branch_manifest.get("goal") or "-"),
        "来源分支：%s（基线 %s）" % (ref, c.short_sha(base_commit)),
        "采纳文件：\n%s" % ("\n".join(c.describe_entries(adopted)) or "（无）"),
    ]
    if rejected:
        body_lines.append("未采纳文件：\n%s" % "\n".join(c.describe_entries(rejected)))
    body_lines.append("构建检查：%s" % build_note)
    commit_sha = c.stage_and_commit(root, subject, tuple(body_lines), commit_paths)
    c.ok("已提交：%s %s" % (c.short_sha(commit_sha), subject))

    c.step("完成")
    c.line("审核结果：%s（采纳 %d/%d 个文件）" % (status, len(adopted), total))
    c.line("应用提交：%s" % commit_sha)
    c.line()
    c.line("下一步：")
    c.line("  1. 如需推送 main：git push origin main（请确认已有授权）。")
    if swift_adopted:
        c.line("  2. 源码已变化，需要重新打包安装才会在 App 中生效：")
        c.line("     cd macos && ./package-app.sh")
        c.line("     有关 SDK/参数可参考 变更管理/README.md 的构建环境变量说明。")
    else:
        c.line("  2. 本次未涉及 Swift 源码，App 行为通常无需重新打包（文档/脚本类改动除外）。")
    c.line("  3. 如需回退（回调）：python3 变更管理/工具/回退变更.py --id %s" % rec_id)
    return 0


def main(argv=None):
    return c.run_cli(APPLY_TITLE, run, argv)


if __name__ == "__main__":
    sys.exit(main())
