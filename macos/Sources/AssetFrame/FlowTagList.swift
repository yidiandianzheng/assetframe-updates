import SwiftUI

struct FlowTagList: View {
    let tags: [String]
    let onRemove: (String) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    onRemove(tag)
                } label: {
                    Label(tag, systemImage: "xmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("移除标签“\(tag)”")
            }
        }
    }
}
