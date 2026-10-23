import Foundation

/// “更新日志”窗口的数据源。
///
/// 完整版本历史仍以 `macos/CHANGELOG.md` 为唯一真源，这里只保留最近若干条摘要供窗口展示。
/// 追加一个版本的顺序：先写 `macos/CHANGELOG.md`，再在 `entries` 顶部插入同一条摘要，
/// 两处的版本号、日期和阶段描述必须一致，避免界面与文档漂移。
struct UpdateLogEntry: Identifiable, Hashable {
    /// 交付阶段。区分“已安装”和“仅源码”，不允许把未构建的改动描述成已交付。
    enum Stage: String {
        case installed = "已安装"
        case candidate = "候选未安装"
        case inProgress = "开发中"
    }

    let version: String
    let date: String
    let stage: Stage
    let summary: String
    let highlights: [String]

    var id: String { "\(version)|\(date)|\(summary)" }
}

enum UpdateLog {
    /// 新 → 旧。顺序即展示顺序，不依赖版本号字符串比较。
    static let entries: [UpdateLogEntry] = [
        .init(
            version: "V261023.3",
            date: "2026-10-23",
            stage: .candidate,
            summary: "更新日志精简",
            highlights: [
                "移除主窗口顶部常驻更新日志条、展开内容与未读角标。",
                "更新日志改为按需从“帮助 → 更新日志…”打开独立窗口查看。",
                "完整版本历史与验证范围仍以 macos/CHANGELOG.md 为准。"
            ]
        ),
        .init(
            version: "V261023.2",
            date: "2026-10-23",
            stage: .installed,
            summary: "标签与分类统一整理",
            highlights: [
                "画册顶部新增标签与分类入口，统一候选确认、词表管理和资料来源。",
                "本机整理保留依据，人工确认后保存；支持批量确认、冲突核对、撤销重做。",
                "标签识别使用独立的空白 AI 接口配置，填写并手动确认后才发送。真实接口效果待验证。"
            ]
        ),
        .init(
            version: "V261023.1",
            date: "2026-10-23",
            stage: .installed,
            summary: "分类管理（词表 v0.1）",
            highlights: [
                "新增受控分类字段与内置词表（11 维 203 词），备注保持独立。",
                "单选检查器可逐维分类，多选可批量分类；筛选、搜索、CSV 与 CLI 支持分类。",
                "分类进入整理历史可撤销；旧库无需迁移，旧分类字段保留兼容。"
            ]
        ),
        .init(
            version: "V261022.1",
            date: "2026-10-22",
            stage: .installed,
            summary: "主窗口顶部新增更新日志",
            highlights: [
                "顶部常驻一条可折叠的更新日志，显示最近版本、日期和一句话摘要。",
                "展开后列出最近四条要点，未读角标在展开后自动清除。",
                "“全部记录”窗口列出内置条目，完整历史仍以 CHANGELOG.md 为准。"
            ]
        ),
        .init(
            version: "V261018.1",
            date: "2026-10-19",
            stage: .installed,
            summary: "智能素材整理版",
            highlights: [
                "自动标签候选先生成、再由人工采纳后才写入元数据。",
                "中文查询自动拆分；本机相似分组与版本字段差异可批量查看。",
                "两个资源库 17,336 条素材安装前后一致；联网 AI 效果未实测。"
            ]
        ),
        .init(
            version: "V261017.5",
            date: "2026-10-18",
            stage: .installed,
            summary: "项目多目录",
            highlights: [
                "项目可先命名建立，再链接多个来源目录。",
                "新增来源文件夹树与“文件”浏览页，文稿和图文资产可按目录筛选。",
                "同名文件区分、重叠来源去重、离线保留与重启恢复回归通过。"
            ]
        ),
        .init(
            version: "V261017.4",
            date: "2026-10-18",
            stage: .installed,
            summary: "统一工作台与图文分集",
            highlights: [
                "新增项目大纲、原 MD 与分集阅读，支持安全写回。",
                "资产卡改为图片优先，并补充固定人物速览字段。",
                "声音参考可试听；完整界面与实际试听仍未验收。"
            ]
        ),
        .init(
            version: "V261017.3",
            date: "2026-10-17",
            stage: .candidate,
            summary: "统一项目工作台",
            highlights: [
                "项目级自动整理、持久队列与统一导航已接入。",
                "35 岁项目只读扫描 518 份资料、识别 38 人。",
                "完整界面闭环未通过，不能称全部完成。"
            ]
        ),
        .init(
            version: "V261013.3",
            date: "2026-10-13",
            stage: .installed,
            summary: "剩余功能与缓存收尾",
            highlights: [
                "缓存分段续扫、浏览让路与窗口内进度。",
                "PDF 连续分页，PSD／PSB／AI／EPS 接入系统预览。",
                "按内容指纹寻找移动改名候选，关联前复核。"
            ]
        )
    ]

    static var latest: UpdateLogEntry? { entries.first }
}
