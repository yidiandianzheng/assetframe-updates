import SwiftUI

struct FeishuImportPreviewView: View {
    @ObservedObject var store: AssetStore
    let preview: FeishuImportPreview

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("回导飞书表格").font(.title2.bold())
                    Text("按不可变调用编号匹配 · 已匹配 \(preview.matchedCount) 个形态")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { store.cancelFeishuImport() }.keyboardShortcut(.cancelAction)
                Button("确认回导 \(Set(preview.changes.map(\.variantID)).count) 个形态") { store.applyFeishuImport() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!preview.canApply)
            }.padding(18)
            Divider()
            if !preview.errors.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("发现 \(preview.errors.count) 个错误，已阻止回导", systemImage: "xmark.octagon.fill").bold()
                    ForEach(preview.errors, id: \.self) { Text("• \($0)") }
                }
                .font(.callout).foregroundStyle(.red)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.07))
                Divider()
            }
            if preview.changes.isEmpty {
                ContentUnavailableView(
                    preview.errors.isEmpty ? "没有发现文字变化" : "请先修复表格错误",
                    systemImage: preview.errors.isEmpty ? "checkmark.circle" : "tablecells.badge.ellipsis",
                    description: Text(preview.sourceURL.lastPathComponent)
                ).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(preview.changes) {
                    TableColumn("调用编号") { Text($0.callCode).font(.system(.body, design: .monospaced)) }.width(min: 190, ideal: 240)
                    TableColumn("字段", value: \.field).width(min: 90, ideal: 120)
                    TableColumn("修改前", value: \.oldValue).width(min: 180, ideal: 240)
                    TableColumn("修改后", value: \.newValue).width(min: 180, ideal: 240)
                }
            }
        }
        .frame(minWidth: 880, minHeight: 560)
    }
}
