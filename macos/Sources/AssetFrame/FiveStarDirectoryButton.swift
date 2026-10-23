import SwiftUI

struct FiveStarDirectoryButton: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let helpText: String
    var indentation: CGFloat = 0
    var systemImage: String? = nil
    let action: () -> Void

    private var iconName: String {
        systemImage ?? (indentation > 0 ? "star.fill" : "square.stack.3d.up.fill")
    }

    private var iconColor: Color {
        if systemImage != nil { return isSelected ? .accentColor : .secondary }
        return indentation > 0 ? .yellow : (isSelected ? .accentColor : .secondary)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 16)
                Text(title)
                Spacer()
                Text(count, format: .number)
                    .foregroundStyle(.tertiary)
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .padding(.leading, 7 + indentation)
            .padding(.trailing, 7)
            .padding(.vertical, 5)
            .background(
                isSelected ? Color.accentColor.opacity(0.13) : .clear,
                in: .rect(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(count) 项")
        .help(helpText)
    }
}
