# 资产管理（图文）App · 开发与 AI 接手入口

软件开发的唯一实体目录：`/Volumes/SSD-1TB/06-工具与开发/资产管理（图文）App/`。原 Obsidian 项目目录与已迁出的软件资料目录保留兼容链接；编辑本目录即可，勿另外复制一套活跃源码。

## 从哪里开始

1. 阅读本文件及 [AGENTS.md](AGENTS.md)，确定修改对象及验证方法。
2. 桌面产品状态以 [macOS 功能状态](macos/FEATURE_STATUS.md) 和对应安装/验证记录为依据；文件名、目录新旧和打包存在均不代表已安装或验收。
3. 本次搬迁结果、逐文件摘要及旧→新映射见 [迁移记录](迁移记录/2026-10-22/README.md)。本轮未调整业务逻辑、正式安装版或生产数据。
4. 同事优化协作、逐文件「采纳/不采纳」与回退（回调）见 [变更管理](变更管理/README.md)；私有协作文库为 `yidiandianzheng/assetframe-src`，只含源码、脚本、文档与变更管理，验证证据、迁移记录、交付包和缓存只保留本机。

## 两款桌面产品共用源码

| 产品 | 产品身份 | 数据根 | 构建与打包边界 |
| --- | --- | --- | --- |
| 向量·素仓 | `AFProductKind=assets`，`com.yidiandian.assetframe` | `~/Library/Application Support/AssetFrame/` | `macos/Info.plist` 及通用打包脚本当前对应此产品 |
| 向量·剧坊 | `AFProductKind=story`，`com.yidiandian.manjuworkbench` | `~/Library/Application Support/ManjuWorkbench/` | 共用二进制，由包内产品身份决定；历史双产品打包脚本固定版本，不能当通用入口重跑 |

产品路由的实现以 `macos/Sources/AssetFrame/AppProduct.swift` 为准。`Package.swift` 定义单一可执行目标 `AssetFrame`；直接运行未打包二进制默认解析为 assets，不要当作漫剧产品测试。

## 代码地图

| 要修改什么 | 从哪里定位 |
| --- | --- |
| 启动、产品身份、工作区切换 | `AssetFrameApp.swift`、`AppProduct.swift`、`LibrarySession.swift`、`UnifiedLibraryWorkspace.swift` |
| 资产索引、导入、关系及数据库 | `GlobalMaterialStore.swift`、`MaterialDatabase.swift`、`MaterialImportController.swift`；旧版 `AssetStore`/`ProjectDatabase` 保留兼容职责，勿直接删除 |
| 画册、侧栏、高清预览和播放 | `NativeAssetGallery`、`LibraryFolderSidebar`、`GalleryWorkspaceShell`、`PreviewImagePipeline`、`MaterialPlaybackController` 等相关文件 |
| 漫剧项目、分集与图文 | `ProjectWorkbenchIndex`、`ProjectSourceManager`、`ProjectAutomationService`、`Manju*`、`Project*Workbench*` |
| 人物 MD 与资产确认 | `CharacterLibraryStore`、`CharacterMarkdown`、`CharacterProjectModules` 及 `macos/Documentation/人物资料标准/` |
| 智能整理与外部模型 | `MaterialIntelligence`、`MaterialSimilarityScan`、`DeepSeek*`、`Vision*`；真实调用与费用单独授权 |
| 本机 CLI | `macos/CLI/assetframe`、`LocalCLIService`、`LocalCLIProtocol`、`LocalCLITransport`，协议见 [CLI 说明](macos/CLI/README.md) |
| Web 原型 / 云反馈服务 | 根目录 `app/`、`tests/` / `cloud/assetframe-online/`；不代表桌面功能 |

以上 Swift 文件均位于 `macos/Sources/AssetFrame/`。未完成或断开的页面有些被 Package.swift 排除；迁移保留原状态，不把文件存在当成已接入。

## 开发环境与检查命令

清单要求：macOS 14+、Swift tools 6.0+，Sparkle 锁定 2.9.4；Web 要求 Node >=22.13.0，依赖以 package-lock.json 为准。本次主机检测到 Swift 6.4、Node 22.23.1、Python 3.9.6，工具链根为 `/Library/Developer/CommandLineTools`。检测到工具不等于构建成功，实际结果见迁移记录。

在本目录执行：

```sh
# 共用桌面目标；独立输出避免把复制过来的缓存当构建证据
(cd macos && swift build -c release --scratch-path ../开发缓存/迁移独立构建 --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --skip-update)
# 使用临时目录/隔离样例的针对性检查
(cd macos && zsh run-self-tests.sh --cli-only)
python3 macos/SelfTests/CLIClientSelfTest.py
(cd macos && zsh run-intelligence-tests.sh)
(cd macos && zsh run-project-workspace-tests.sh)
(cd macos && zsh run-project-visual-tests.sh)
# Web 与 cloud 的本地检查
npm run build
node --test tests/rendered-html.test.mjs
(cd cloud/assetframe-online && node --test)
```

图文工作台测试另依赖 `/tmp/assetframe-35-visual-project-test` 中的真实项目测试副本；本轮该临时样例不存在，测试在 `Chen identity` 前置样例断言处失败。先按授权准备测试副本再运行，不要把缺样例误判成迁移丢失生产资料，也不要改断言制造通过。

Web 依赖目录当前不完整，`vinext` 入口目标缺失，重新构建未通过。已有开发依赖随迁移原样保留；需要恢复依赖时先核对授权、锁文件和系统条件，不自动安装全套工具。本机缓存可能带旧绝对路径，缓存可用性和新路径干净构建是两回事。 本机默认 SDK 27.0 缺少 SwiftUIMacros.StateMacro 插件，完整编译会失败；本轮 SDK 26.5 的最小探针与完整 Release 构建均已通过，上面的命令就是已验证入口；其他机器按实际可用 SDK 选择，不假定此路径必有。旧文中的 SDK 路径只反映历史环境，不应硬编码复制到当前环境。

## 打包、数据与恢复边界

- `macos/package-app.sh` 当前只生成向量·素仓 App/ZIP，会修改交付输出；`run-release-gate.sh` 还会打包及启动隔离候选，不能当作纯静态检查。
- 双产品历史实现见 `macos/ProductValidation/20261018_双软件拆分/package-products.py`；含固定版本、QA 根和结果写回，保留作证据，未整理成通用发布入口。
- `release-github.sh` 已于 2026-10-23 打通并完成一次 beta 发布验证（V261023.4，仓库 `yidiandianzheng/assetframe-updates`，ZIP + Sparkle appcast + 公开下载回验）；`release-online.sh` 仍依赖旧缓存布局、未验证，不应直接执行。
- `dist-macos` 与 `macos/.build` 现在是指向本项目内部交付/缓存的链接。`软件交付/`、`开发缓存/`、`历史资料/` 保存软件包、可重建文件及历史；其中的源码快照均非活跃源码。
- 正式 App 留在 `/Applications/`；生产库登记、SQLite、钥匙串、原图片音视频及创作项目保持原位。开发目录备份不能替代这些数据的备份。应用的 SSD 素材/预览路径是运行配置，不能因迁移源码而批量替换。
- 测试应用必须使用该软件支持的 `/tmp/assetframe-qa.*` 隔离根，勿用真实生产库验证写入、导入或删除。
- 原 `.git` 仅有残留目录，无法作为有效仓库；原样保存在 `历史资料/旧Git残留/`。新本地仓库于 2026-10-23 建立基线提交并推送到私有协作文库 `yidiandianzheng/assetframe-src`（不含验证证据、交付包、缓存与用户数据）；提交与推送仍须有相应授权。
- 回退必须先核对迁移后改动，按迁移记录恢复映射；不使用旧源码或安装前数据库覆盖后来产生的工作。

---

## 迁移前保留的 Web 原型开发说明

以下保留原 README 的 Web 配置和开发细节；产品归属与维护入口以上文为准。

# Web 原型（vinext-starter）

A clean full-stack starter running on
[vinext](https://github.com/cloudflare/vinext), with optional Cloudflare D1 and
Drizzle support.

## Prerequisites

- Node.js `>=22.13.0`

## Quick Start

```bash
npm install
npm run dev
npm run build
```

This starter does not use `wrangler.jsonc`.

## Included Shape

- edit site code under `app/`
- `.openai/hosting.json` declares optional Sites D1 and R2 bindings
- `vite.config.ts` simulates declared bindings for local development
- `db/schema.ts` starts intentionally empty
- `examples/d1/` contains an optional D1 example surface
- `drizzle.config.ts` supports local migration generation when needed

## Workspace Auth Headers

OpenAI workspace sites can read the current user's email from
`oai-authenticated-user-email`.

SIWC-authenticated workspace sites may also receive
`oai-authenticated-user-full-name` when the user's SIWC profile has a non-empty
`name` claim. The full-name value is percent-encoded UTF-8 and is accompanied by
`oai-authenticated-user-full-name-encoding: percent-encoded-utf-8`.

Treat the full name as optional and fall back to email when it is absent:

```tsx
import { headers } from "next/headers";

export default async function Home() {
  const requestHeaders = await headers();
  const email = requestHeaders.get("oai-authenticated-user-email");
  const encodedFullName = requestHeaders.get("oai-authenticated-user-full-name");
  const fullName =
    encodedFullName &&
    requestHeaders.get("oai-authenticated-user-full-name-encoding") ===
      "percent-encoded-utf-8"
      ? decodeURIComponent(encodedFullName)
      : null;

  const displayName = fullName ?? email;
  // ...
}
```

## Optional Dispatch-Owned ChatGPT Sign-In

Import the ready-to-use helpers from `app/chatgpt-auth.ts` when the site needs
optional or required ChatGPT sign-in:

- Use `getChatGPTUser()` for optional signed-in UI.
- Use `requireChatGPTUser(returnTo)` for server-rendered pages that should send
  anonymous visitors through Sign in with ChatGPT.
- Use `chatGPTSignInPath(returnTo)` and `chatGPTSignOutPath(returnTo)` for
  browser links or actions.
- Pass a same-origin relative `returnTo` path for the destination after sign-in
  or sign-out. The helper validates and safely encodes it.
- Mark protected pages with `export const dynamic = "force-dynamic"` because
  they depend on per-request identity headers.

Dispatch owns `/signin-with-chatgpt`, `/signout-with-chatgpt`, `/callback`, the
OAuth cookies, and identity header injection. Do not implement app routes for
those reserved paths. Routes that do not import and call the helper remain
anonymous-compatible.

SIWC establishes identity only; it does not prove workspace membership. Use the
Sites hosting platform's access policy controls for workspace-wide restrictions,
or enforce explicit server-side membership or allowlist checks.

Use SIWC for account pages, user-specific dashboards, saved records, and write
actions tied to the current ChatGPT user. Leave public content anonymous.

## Useful Commands

- `npm run dev`: start local development
- `npm run build`: verify the vinext build output
- `npm test`: build the starter and verify its rendered loading skeleton
- `npm run db:generate`: generate Drizzle migrations after schema changes

## Learn More

- [vinext Documentation](https://github.com/cloudflare/vinext)
- [Drizzle D1 Guide](https://orm.drizzle.team/docs/get-started/d1-new)
