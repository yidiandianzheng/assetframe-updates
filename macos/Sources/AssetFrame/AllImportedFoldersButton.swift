import SwiftUI

struct AllImportedFoldersButton: View {
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text("已链接文件夹资产")
                Spacer()
                Text(count, format: .number)
                    .foregroundStyle(.tertiary)
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                isSelected ? Color.accentColor.opacity(0.13) : .clear,
                in: .rect(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("已链接文件夹资产，\(count) 项")
        .help("汇总当前项目全部已链接文件夹及其子目录中的照片")
    }
}
