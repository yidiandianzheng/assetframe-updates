import SwiftUI

struct AssetFileLocationsSection: View {
    enum Style {
        case grouped
        case plain
    }

    @ObservedObject var store: AssetStore
    let assetID: String
    var style: Style = .grouped

    @ViewBuilder
    var body: some View {
        if style == .plain {
            locationContent
        } else {
            GroupBox("文件位置") {
                locationContent.padding(.top, 4)
            }
        }
    }

    private var locationContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            locationRow
            if let originalPath = store.originalSourcePath(for: assetID) {
                Divider()
                originalSourceRow(originalPath)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func originalSourceRow(_ path: String) -> some View {
        let exists = FileManager.default.fileExists(atPath: path)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("原始本地来源", systemImage: "externaldrive")
                    .font(.callout.bold())
                Spacer()
                Label(exists ? "正常" : "离线", systemImage: exists ? "checkmark.circle.fill" : "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(exists ? .green : .orange)
            }
            Text(path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
            HStack(spacing: 8) {
                Button("在 Finder 中显示", systemImage: "folder") {
                    store.revealOriginalSource(for: assetID)
                }
                .disabled(!exists)
                Button("复制路径", systemImage: "doc.on.doc") {
                    store.copyOriginalSourcePath(for: assetID)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var locationRow: some View {
        let location = store.fileLocation(for: assetID)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("当前文件", systemImage: "doc")
                    .font(.callout.bold())
                Spacer()
                Label(statusText(location), systemImage: statusIcon(location))
                    .font(.caption)
                    .foregroundStyle(statusColor(location))
            }
            Text(location?.displayPath ?? "未记录文件位置")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(location?.path ?? "")
            HStack(spacing: 8) {
                Button("在 Finder 中显示", systemImage: "folder") {
                    store.revealFileLocation(for: assetID)
                }
                .disabled(location?.exists != true)
                Button("复制路径", systemImage: "doc.on.doc") {
                    store.copyFileLocation(for: assetID)
                }
                .disabled(location == nil)
                if location?.exists != true {
                    Button("重新定位文件", systemImage: "arrow.triangle.2.circlepath") {
                        store.relinkSource(for: assetID)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func statusText(_ location: AssetFileLocation?) -> String {
        guard let location else { return "未记录" }
        return location.exists ? "正常" : "已失联"
    }

    private func statusIcon(_ location: AssetFileLocation?) -> String {
        guard let location else { return "questionmark.circle" }
        return location.exists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func statusColor(_ location: AssetFileLocation?) -> Color {
        guard let location else { return .secondary }
        return location.exists ? .green : .orange
    }
}
