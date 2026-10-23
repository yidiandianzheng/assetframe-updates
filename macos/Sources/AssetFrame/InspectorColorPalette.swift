import SwiftUI

struct InspectorColorPalette: View {
    let colors: [AssetDominantColor]
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 7) {
            if colors.isEmpty {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在提取素材主色")
                } else {
                    Label("颜色待识别", systemImage: "paintpalette")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                ForEach(colors) { color in
                    Circle()
                        .fill(swiftUIColor(color))
                        .frame(width: 18, height: 18)
                        .overlay {
                            Circle().stroke(.primary.opacity(0.22), lineWidth: 1)
                        }
                        .accessibilityElement()
                        .accessibilityLabel("素材主色 \(color.hex)")
                        .help(color.hex)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("素材主色板")
    }

    private func swiftUIColor(_ color: AssetDominantColor) -> Color {
        Color(
            red: Double(color.red) / 255,
            green: Double(color.green) / 255,
            blue: Double(color.blue) / 255
        )
    }
}
