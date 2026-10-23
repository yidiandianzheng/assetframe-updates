#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""新建变更：校验工作区 → 从 main 创建 change/<ID> 分支 → 生成变更单与清单。

用法：
    python3 变更管理/工具/新建变更.py --id CHG-20261023-01 --owner 张三 --goal "说明本次优化目标"
"""

import argparse
import shutil
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import _common as c


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="新建一条变更：从 main 创建 change/<变更ID> 分支，并生成变更单/清单。",
    )
    parser.add_argument("--id", required=True, help="变更编号，格式 CHG-YYYYMMDD-NN（如 CHG-20261023-01）")
    parser.add_argument("--owner", required=True, help="负责人姓名（会写进变更单与索引）")
    parser.add_argument("--goal", required=True, help="本次变更的目标说明")
    return parser.parse_args(argv)


def run(argv=None):
    args = parse_args(argv)
    rec_id = args.id.strip()
    owner = args.owner.strip()
    goal = args.goal.strip()

    c.step("校验参数")
    c.validate_change_id(rec_id)
    if not owner:
        c.fail("负责人不能为空。")
    if not goal:
        c.fail("目标说明不能为空。")

    root = c.git_root(Path(__file__).resolve().parent)
    c.info("仓库根目录：%s" % root)
    c.info("变更编号：%s" % rec_id)
    c.info("负责人：%s" % owner)
    c.info("目标：%s" % goal)

    c.step("检查分支与工作区")
    branch = c.current_branch(root)
    if branch != "main":
        c.fail(
            "新建变更必须从 main 分支开始，当前分支是：%s。\n"
            "  请先执行：git switch main" % (branch or "（游离 HEAD）")
        )
    if c.ref_exists(root, "change/" + rec_id):
        c.fail("本地已存在分支 change/%s，请换一个编号，或先删除旧分支。" % rec_id)
    if c.ref_exists(root, "origin/change/" + rec_id):
        c.fail("远程已存在分支 origin/change/%s，请换一个编号（可能是同事已用过的编号）。" % rec_id)
    if c.record_dir(root, rec_id).exists():
        c.fail("记录目录已存在：%s\n  请换一个编号，或先确认是否重复创建。" % c.record_dir(root, rec_id))

    c.require_clean(
        root,
        action_hint="新建变更要求工作区干净；请先提交、还原或 git stash 现有改动。",
    )

    base_head = c.head_commit(root)
    base_short = c.short_sha(base_head)
    c.ok("当前在 main，工作区干净，基线 commit：%s" % base_short)

    if c.ref_exists(root, "origin/main"):
        origin_main = c.resolve_ref(root, "origin/main")
        if origin_main != base_head:
            c.warn(
                "本地 main（%s）与 origin/main（%s）不一致。"
                % (base_short, c.short_sha(origin_main))
            )
            c.hint("建议先执行 git pull --ff-only 再新建变更，否则同事会缺最新基线；本脚本不联网。")
    else:
        c.warn("未检测到 origin/main。若这是协作仓库，请先配置远程并推送 main。")

    c.step("创建变更分支与记录")
    c.run_git(root, ["switch", "-c", "change/%s" % rec_id, "main"])
    created_at = c.now_str()
    manifest = {
        "id": rec_id,
        "owner": owner,
        "goal": goal,
        "created_at": created_at,
        "base_commit": base_head,
        "base_ref": "main",
        "branch": "change/%s" % rec_id,
        "status": "待提交",
        "files": [],
    }
    index_path = root / c.INDEX_PATH
    index_before = index_path.read_text(encoding="utf-8") if index_path.is_file() else None
    created_dir = c.record_dir(root, rec_id)
    try:
        created_dir.mkdir(parents=True, exist_ok=False)
        c.save_manifest(root, rec_id, manifest)
        c.write_text(c.form_path(root, rec_id), c.render_new_form(root, manifest))
        c.update_index(root, manifest, status="待提交", adopted="-", reverted="-")
    except Exception:
        # 失败回滚：回到 main，删除刚创建的分支与记录目录，恢复索引
        _rollback_created(root, rec_id, index_path, index_before, created_dir)
        raise

    c.step("完成")
    c.ok("已创建分支 change/%s（基于 main %s）。" % (rec_id, base_short))
    c.info("变更单：%s" % c.form_path(root, rec_id).relative_to(root))
    c.info("清单：%s" % c.manifest_path(root, rec_id).relative_to(root))
    c.info("索引已加入一行，状态：待提交。")
    c.line()
    c.line("下一步：")
    c.line("  1. 在 change/%s 分支上修改代码/文档。" % rec_id)
    c.line("  2. 运行：python3 变更管理/工具/提交变更.py --id %s" % rec_id)
    c.line("  3. 按提示填写每个文件的说明后再次运行，提交成功后再执行打印出的 git push 命令。")
    return 0


def _rollback_created(root, rec_id, index_path, index_before, created_dir):
    try:
        current = c.current_branch(root)
        if current == "change/" + rec_id:
            c.run_git(root, ["switch", "main"], check=False)
        if c.ref_exists(root, "change/" + rec_id):
            c.run_git(root, ["branch", "-D", "change/" + rec_id], check=False)
        if created_dir.exists():
            shutil.rmtree(created_dir, ignore_errors=True)
        if index_before is None:
            if index_path.is_file():
                index_path.unlink()
        else:
            index_path.write_text(index_before, encoding="utf-8")
    except Exception:
        c.warn("自动回滚未完全成功，请手动检查 main 分支与 变更管理/记录/%s。" % rec_id)


def main(argv=None):
    return c.run_cli("=== 变更管理 · 新建变更 ===", run, argv)


if __name__ == "__main__":
    sys.exit(main())
