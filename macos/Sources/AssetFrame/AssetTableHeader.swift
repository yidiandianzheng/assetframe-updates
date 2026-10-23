import SwiftUI

struct AssetTableHeader: View {
    let fields: [AssetTableField]
    let imageScale: AssetTableImageScale
    let minimumWidth: CGFloat

    private var tableWidth: CGFloat {
        fields.reduce(0) { $0 + $1.width(imageScale: imageScale) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(fields) { field in
                Label(field.title, systemImage: field.systemImage)
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(width: field.width(imageScale: imageScale), height: 42, alignment: .leading)
                    .overlay(alignment: .trailing) { Divider() }
            }
        }
        .frame(width: max(tableWidth, minimumWidth), alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}
