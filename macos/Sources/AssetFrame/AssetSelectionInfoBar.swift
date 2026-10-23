import SwiftUI

struct AssetSelectionInfoBar: View {
    let asset: AssetItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(asset.originalFilename)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(asset.originalFilename)

            Divider()
                .frame(height: 12)

            Text(asset.dimensionText)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Divider()
                .frame(height: 12)

            if let fileSize = asset.sourceFileSize, fileSize >= 0 {
                Text(fileSize, format: .byteCount(style: .file))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("大小待识别")
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
        .accessibilityElement(children: .combine)
    }
}
