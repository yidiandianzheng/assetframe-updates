# 项目协作说明

本文件适用于本目录及子目录；后续 AI 先读 README.md，再读对应功能状态/验证记录。项目唯一实体工作区是本目录；旧路径只是兼容链接。

## 修改边界

- 两款桌面产品共用 macos/Sources/AssetFrame；以 AppProduct 和包内 AFProductKind 区分。保持产品身份、数据根及 CLI 端点隔离。
- 修改前定位活跃实现和调用方；Package.swift 排除的实验页面不能视作正式功能。保留与本轮无关的用户和其他任务改动。
- 源码快照、软件交付、开发缓存、历史资料及 ProductValidation/rollback 只作证据；不在其中继续日常开发。历史日志、报告内旧路径保持原文。
- 功能状态以 macos/FEATURE_STATUS.md 和对应记录裁决；源码、构建、安装、真实操作和用户验收分别报告。
- 本地 Git 为迁移后新建，旧 .git 残留已保留，未恢复旧历史；不得为填补历史编造提交。提交、推送、安装替换和发布须有相应授权。2026-10-23 起有基线提交，远程 origin 是唯一项目仓库 `yidiandianzheng/assetframe-updates`（源码、脚本、文档与 Releases 安装包同库）。
- 同事优化改动统一走 `变更管理/` 流程：`change/<变更ID>` 分支提交，负责人逐文件采纳后由审核脚本合入 main，可按变更单回退；不直接推 main、不把证据/交付包/用户数据/密钥提交到协作文库。

## 验证与维护

- 实际环境、模块地图及检查命令见 README.md。按改动运行相应检查；不要为局部更改重构整个项目。
- 独立构建输出使用开发缓存/迁移独立构建；macos/.build 是迁移保留缓存，不以缓存存在宣称通过。移动后二次修改应以新源码重新构建。
- 本次不改正式 App、生产库、钥匙串或原素材。运行应用或测试写入须使用支持的 /tmp/assetframe-qa.* 隔离根；执行脚本前确认是否调用线上模型、发布或触及生产数据。
- package-app.sh 只打向量·素仓；历史双产品脚本有固定版本，发布脚本仍有既有路径不一致。不要以通用打包通过宣称两产品发布均通过。
- 密钥不写入代码、Git、示例或交接文件；生产 endpoint/token 不进入报告。依赖和工具安装、外部上传/模型费用须核对授权。
- 同一成果同一时刻只有一个写入负责人；其他实例只读审查或在隔离位置交候选。
- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.
