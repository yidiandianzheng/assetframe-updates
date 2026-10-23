import SwiftUI

struct ShapeFilterPopover: View {
    @Binding var filter: AssetFilter
    let counts: [AssetAspectRatioFilterOption: Int]
    @State private var customWidth: Double
    @State private var customHeight: Double

    init(filter: Binding<AssetFilter>, counts: [AssetAspectRatioFilterOption: Int]) {
        _filter = filter
        self.counts = counts
        let ratio = filter.wrappedValue.customAspectRatio ?? 2.39
        _customWidth = State(initialValue: ratio)
        _customHeight = State(initialValue: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("形状与画幅", systemImage: "aspectratio")
                    .font(.headline)
                    .foregroundStyle(GraphiteTheme.panelText)
                Spacer()
                if !filter.aspectRatios.isEmpty {
                    Button("清除", systemImage: "xmark.circle", action: clear)
                        .buttonStyle(.borderless)
                        .foregroundStyle(GraphiteTheme.accent)
                }
            }

            VStack(spacing: 2) {
                ForEach(standardOptions) { option in
                    optionRow(option)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("自定比例")
                    .font(.subheadline)
                    .bold()
                HStack(spacing: 7) {
                    TextField("宽", value: $customWidth, format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 68)
                    Text(":").foregroundStyle(GraphiteTheme.panelSecondaryText)
                    TextField("高", value: $customHeight, format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 68)
                    Button("应用") { applyCustomRatio() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!customRatioIsValid)
                }
                Text("例如 2.39:1；允许约 3.5% 的图片像素偏差。")
                    .font(.caption)
                    .foregroundStyle(GraphiteTheme.panelSecondaryText)
            }

            Text("方向与精确画幅可同时选择，匹配任意一项即会显示。")
                .font(.caption)
                .foregroundStyle(GraphiteTheme.panelSecondaryText)
        }
        .padding(16)
        .frame(width: 280)
        .background(GraphiteTheme.inspector)
        .foregroundStyle(GraphiteTheme.panelText)
    }

    private var standardOptions: [AssetAspectRatioFilterOption] {
        AssetAspectRatioFilterOption.allCases.filter { $0 != .custom }
    }

    private var customRatioIsValid: Bool {
        customWidth.isFinite && customHeight.isFinite && customWidth > 0 && customHeight > 0
    }

    private func optionRow(_ option: AssetAspectRatioFilterOption) -> some View {
        let selected = filter.aspectRatios.contains(option)
        return Button {
            toggle(option)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? GraphiteTheme.accent : GraphiteTheme.panelSecondaryText)
                    .frame(width: 16)
                Image(systemName: icon(for: option))
                    .foregroundStyle(GraphiteTheme.panelSecondaryText)
                    .frame(width: 18)
                Text(option.rawValue)
                    .font(.callout)
                    .foregroundStyle(GraphiteTheme.panelText)
                Spacer()
                Text(counts[option, default: 0], format: .number)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(GraphiteTheme.panelSecondaryText)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .background(selected ? GraphiteTheme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.rawValue)，\(counts[option, default: 0]) 项")
        .accessibilityValue(selected ? "已选择" : "未选择")
    }

    private func toggle(_ option: AssetAspectRatioFilterOption) {
        if filter.aspectRatios.contains(option) {
            filter.aspectRatios.remove(option)
        } else {
            filter.aspectRatios.insert(option)
        }
    }

    private func applyCustomRatio() {
        guard customRatioIsValid else { return }
        filter.customAspectRatio = customWidth / customHeight
        filter.aspectRatios.insert(.custom)
    }

    private func clear() {
        filter.aspectRatios.removeAll()
    }

    private func icon(for option: AssetAspectRatioFilterOption) -> String {
        switch option {
        case .landscape, .fourThree, .sixteenNine: "rectangle"
        case .portrait, .threeFour, .nineSixteen: "rectangle.portrait"
        case .square: "square"
        case .panoramic: "rectangle.ratio.16.to.9"
        case .custom: "slider.horizontal.3"
        }
    }
}
