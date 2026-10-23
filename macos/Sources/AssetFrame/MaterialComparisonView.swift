import SwiftUI

struct MaterialComparisonSelection: Identifiable {
    let id = UUID()
    let ids: [String]
}

struct MaterialComparisonView: View {
    @ObservedObject var store: GlobalMaterialStore
    let ids: [String]
    let onClose: () -> Void
    @State private var zoom = 1.0
    @State private var saving = false
    @State private var error: String?
    private var materials: [MaterialRecord] {
        ids.compactMap { id in store.materials.first { $0.id == id && $0.deletedAt == nil } }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("候选对比").font(.title2)
                Spacer()
                Slider(value: $zoom, in: 1...3).frame(width: 150).accessibilityLabel("同步缩放")
                Button("重置") { zoom = 1 }
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
            }
            Text("保留只更新当前素材的审核状态；其他候选和已有镜头引用保持不变。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange) }
            HStack(alignment: .top, spacing: 12) {
                ForEach(materials) { material in
                    VStack(alignment: .leading, spacing: 10) {
                        MaterialThumbnailView(material: material, previewMaximumDimension: 1400)
                            .scaleEffect(zoom).frame(height: 330).clipped()
                        Text(material.name).lineLimit(3)
                        Text("\(material.production?.versionName ?? "v01") · \(material.production?.review ?? "待审核")")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("保留此版本") {
                            saving = true
                            Task {
                                defer { saving = false }
                                do { try await store.confirmMaterial(material.id) }
                                catch { self.error = error.localizedDescription }
                            }
                        }.disabled(!store.canWrite)
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }.padding(20).frame(width: 960, height: 540)
            .disabled(saving).interactiveDismissDisabled()
    }
}
