import SwiftUI

struct AssetTableGroupHeader: View {
    let title: String
    let count: Int
    let width: CGFloat
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .bold()
            Text("\(count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: 36)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}
