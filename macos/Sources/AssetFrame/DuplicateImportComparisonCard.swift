import SwiftUI

struct DuplicateImportComparisonCard: View {
    let title: String
    let systemImage: String
    let asset: AssetItem
    let filename: String
    let path: String
    let dimensionText: String
    let fileSizeText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(title == "已存在" ? .secondary : GraphiteTheme.accent)

            AssetThumbnail(
                asset: asset,
                size: CGSize(width: 276, height: 238),
                contentMode: .fit,
                showsLoadingStatus: true
            )
            .frame(maxWidth: .infinity)

            Text(filename)
                .font(.body.weight(.medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .help(filename)

            HStack(spacing: 6) {
                Text(dimensionText)
                Text("·")
                Text(fileSizeText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            Text(path)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(path)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GraphiteTheme.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(GraphiteTheme.panelStroke, lineWidth: 1)
        }
    }
}
