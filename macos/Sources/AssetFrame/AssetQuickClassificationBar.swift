import SwiftUI

struct AssetQuickClassificationBar: View {
    let selectedCount: Int
    let selectedType: AssetType?
    let onSelectType: (AssetType) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("快速分类", systemImage: "tag.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(AssetType.allCases) { type in
                        Button {
                            onSelectType(type)
                        } label: {
                            HStack(spacing: 5) {
                                Text(type.symbol)
                                    .font(.caption.monospaced())
                                Text(type.rawValue)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                selectedType == type
                                    ? Color.accentColor.opacity(0.16)
                                    : Color(nsColor: .controlBackgroundColor),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selectedType == type ? Color.accentColor : Color.secondary)
                        .accessibilityLabel("将已选 \(selectedCount) 项分类为\(type.rawValue)")
                    }
                }
                .padding(.vertical, 5)
            }
            .scrollIndicators(.hidden)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(.bar)
    }
}
