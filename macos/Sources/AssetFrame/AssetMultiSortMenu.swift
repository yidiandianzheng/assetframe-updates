import SwiftUI

struct AssetMultiSortMenu: View {
    @Binding var sort: AssetSortConfiguration
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("排序规则 \(sort.criteria.count)", systemImage: "arrow.up.arrow.down")
        }
        .help("设置多个排序条件及其优先级")
        .accessibilityLabel("排序规则，当前有\(sort.criteria.count)个条件")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AssetSortEditor(sort: $sort, dismiss: dismiss)
        }
    }

    private func dismiss() {
        isPresented = false
    }
}
