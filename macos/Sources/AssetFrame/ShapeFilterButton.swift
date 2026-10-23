import SwiftUI

struct ShapeFilterButton: View {
    @Binding var filter: AssetFilter
    let counts: [AssetAspectRatioFilterOption: Int]
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(title, systemImage: "aspectratio")
                .font(.callout)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按图片方向和精确画幅多选筛选")
        .accessibilityLabel("形状筛选，\(title)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ShapeFilterPopover(filter: $filter, counts: counts)
        }
    }

    private var isActive: Bool { !filter.aspectRatios.isEmpty }

    private var title: String {
        if filter.aspectRatios.isEmpty { return "形状" }
        if filter.aspectRatios.count == 1 { return filter.aspectRatios.first?.rawValue ?? "形状" }
        return "形状 \(filter.aspectRatios.count)"
    }
}
