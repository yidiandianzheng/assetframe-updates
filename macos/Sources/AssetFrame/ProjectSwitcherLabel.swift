import SwiftUI

struct ProjectSwitcherLabel: View {
    let projectName: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder.fill")
                .font(.body)
                .foregroundStyle(.blue)
                .frame(width: 24, height: 24)
                .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))

            Text(projectName)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Image(systemName: "chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 210, idealWidth: 220, maxWidth: 240, minHeight: 42)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("切换项目，当前项目是 \(projectName)")
    }
}
