import SwiftUI

struct GalleryThumbnailSizeControl: View {
    @Binding var width: Double
    let compact: Bool

    private let minimumWidth = 132.0
    private let maximumWidth = 320.0

    var body: some View {
        HStack(spacing: compact ? 5 : 7) {
            Button("缩小缩略图", systemImage: compact ? "minus" : "rectangle.grid.3x2", action: decreaseSize)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            Slider(value: $width, in: minimumWidth...maximumWidth, step: 4)
                .frame(width: compact ? 72 : 104)
                .accessibilityLabel("缩略图大小")
                .accessibilityValue("\(Int(width))")

            Button("放大缩略图", systemImage: compact ? "plus" : "rectangle.grid.1x2", action: increaseSize)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .frame(height: 34)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
        .help("调整画册缩略图大小")
    }

    private func decreaseSize() {
        width = max(minimumWidth, width - 24)
    }

    private func increaseSize() {
        width = min(maximumWidth, width + 24)
    }
}
