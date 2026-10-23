import SwiftUI

struct MaterialKindFilterButton: View {
    @Binding var selectedKinds: Set<MaterialKind>
    @Binding var selectedFormats: Set<String>
    let counts: [MaterialKind: Int]

    var body: some View {
        Menu(title, systemImage: "line.3.horizontal.decrease.circle") {
            Button("全部类型", systemImage: selectedKinds.isEmpty ? "checkmark" : "square.grid.2x2") {
                selectedKinds.removeAll()
                selectedFormats.removeAll()
            }
            Divider()
            Section("快速查看") {
                exclusiveButton(.image, title: "只看图片")
                exclusiveButton(.video, title: "只看视频")
                exclusiveButton(.audio, title: "只看音频")
            }
            Divider()
            Section("组合选择") {
                ForEach(MaterialKind.allCases) { kind in
                    Button {
                        toggle(kind)
                    } label: {
                        Label(
                            "\(kind.rawValue)（\(counts[kind, default: 0])）",
                            systemImage: selectedKinds.contains(kind) ? "checkmark.circle.fill" : kind.systemImage
                        )
                    }
                }
            }
        }
        .help("按图片、视频、音频等素材类型筛选")
        .accessibilityLabel("素材类型筛选，\(title)")
    }

    private var title: String {
        if selectedKinds.isEmpty { return "全部类型" }
        if selectedKinds.count == 1 { return selectedKinds.first?.rawValue ?? "类型" }
        return "类型 \(selectedKinds.count)"
    }

    private func toggle(_ kind: MaterialKind) {
        if selectedKinds.contains(kind) {
            selectedKinds.remove(kind)
        } else {
            selectedKinds.insert(kind)
        }
    }

    @ViewBuilder private func exclusiveButton(_ kind: MaterialKind, title: String) -> some View {
        Button {
            selectedKinds = [kind]
            selectedFormats.removeAll()
        } label: {
            Label(
                "\(title)（\(counts[kind, default: 0])）",
                systemImage: selectedKinds == [kind] ? "checkmark.circle.fill" : kind.systemImage
            )
        }
    }
}
