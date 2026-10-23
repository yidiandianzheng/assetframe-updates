import SwiftUI

/// “更新日志”窗口。
///
/// 只读内置条目，不访问网络、不读取资源库。入口在应用的“帮助”菜单；
/// 完整版本历史与验证范围仍以 `macos/CHANGELOG.md` 为准。
struct UpdateLogSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("更新日志")
                        .font(.title2.bold())
                    Text("按版本倒序记录。完整历史、验证范围与未验收项以 macos/CHANGELOG.md 为准。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(UpdateLog.entries) { entry in
                        UpdateLogRow(entry: entry)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 640, height: 520)
    }
}

/// 单条更新记录：版本、日期、阶段、一句话摘要与要点。
struct UpdateLogRow: View {
    let entry: UpdateLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.version)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                Text(entry.date)
                    .font(.caption2)
                    .foregroundStyle(GraphiteTheme.panelMutedText)
                UpdateLogStageChip(stage: entry.stage)
                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(GraphiteTheme.panelSecondaryText)
                    .lineLimit(1)
            }
            ForEach(entry.highlights, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("·")
                    Text(line)
                }
                .font(.caption)
                .foregroundStyle(GraphiteTheme.panelSecondaryText)
            }
        }
    }
}

struct UpdateLogStageChip: View {
    let stage: UpdateLogEntry.Stage

    private var tint: Color {
        switch stage {
        case .installed: .green
        case .candidate: .orange
        case .inProgress: GraphiteTheme.accent
        }
    }

    var body: some View {
        Text(stage.rawValue)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }
}
