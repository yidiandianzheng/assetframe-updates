import SwiftUI

struct FileFormatFilterButton: View {
    @Binding var selectedFormats: Set<String>
    let counts: [String: Int]
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(title, systemImage: "doc.badge.ellipsis")
                .font(.callout)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按当前范围内实际存在的文件格式多选筛选")
        .accessibilityLabel("文件格式筛选，\(title)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            FileFormatFilterPopover(selectedFormats: $selectedFormats, counts: counts)
        }
    }

    private var isActive: Bool { !selectedFormats.isEmpty }

    private var title: String {
        if selectedFormats.isEmpty { return "格式" }
        if selectedFormats.count == 1 { return selectedFormats.first?.uppercased() ?? "格式" }
        return "格式 \(selectedFormats.count)"
    }
}
