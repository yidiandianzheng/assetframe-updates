import SwiftUI

enum FeatureAvailability: String, CaseIterable, Identifiable {
    case production = "正式可用"
    case experimental = "实验功能"
    case paused = "暂停能力"

    var id: Self { self }
    var systemImage: String {
        switch self {
        case .production: "checkmark.seal.fill"
        case .experimental: "testtube.2"
        case .paused: "pause.circle.fill"
        }
    }
}

struct FeatureStatusRecord: Identifiable {
    let name: String
    let availability: FeatureAvailability
    let detail: String
    var id: String { "\(availability.rawValue)|\(name)" }
}

struct FeatureStatusView: View {
    let onClose: () -> Void

    private let records: [FeatureStatusRecord] = [
        .init(name: "资产库与本地文件夹原位管理", availability: .production, detail: "正式入口已接入；普通资产不复制或移动原图。"),
        .init(name: "图片五星、通用资产与导出库", availability: .production, detail: "五星和通用资产分别创建独立受管副本。"),
        .init(name: "AI 名称、类型和标签建议", availability: .production, detail: "人工确认后才写入元数据；费用调用另设确认门。"),
        .init(name: "音视频生产素材管理", availability: .experimental, detail: "V260905.1：SQLite、波形/关键帧、镜头固定版本、生产交付已接入；真实生产样本与用户验收仍需完成。"),
        .init(name: "候选对比与保存筛选", availability: .experimental, detail: "进入本轮真实素材走查后再升级为正式能力。"),
        .init(name: "剧本查缺", availability: .experimental, detail: "源码仍与正式 target 隔离，完成端到端验收前不进入主导航。"),
        .init(name: "资料库审计", availability: .experimental, detail: "本地分析组件存在，但正式界面仍需完成编译链和真实流程验收。"),
        .init(name: "飞书回导", availability: .paused, detail: "当前迁移版本未恢复写入，保留源码但不宣称可用。"),
        .init(name: "自动脚本解析", availability: .paused, detail: "未形成正式、可验收的自动生产流程。")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("功能状态")
                        .font(.title2.bold())
                    Text("正式、实验与暂停能力分开说明，避免文档和界面漂移。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()
            List {
                ForEach(FeatureAvailability.allCases) { availability in
                    Section {
                        ForEach(records.filter { $0.availability == availability }) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.name).font(.headline)
                                Text(record.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Label(availability.rawValue, systemImage: availability.systemImage)
                    }
                }
            }
        }
        .frame(width: 720, height: 600)
    }
}

