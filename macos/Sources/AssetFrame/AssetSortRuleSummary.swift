import SwiftUI

struct AssetSortRuleSummary: View {
    let criteria: [AssetSortCriterion]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(Array(criteria.enumerated()), id: \.element.id) { index, criterion in
                    HStack(spacing: 3) {
                        Text(priorityLabel(at: index))
                            .fontWeight(.semibold)
                            .foregroundStyle(index == 0 ? GraphiteTheme.panelText : GraphiteTheme.panelSecondaryText)
                        Text("\(criterion.field.rawValue) \(criterion.directionLabel)")
                            .foregroundStyle(GraphiteTheme.panelSecondaryText)
                    }

                    if index < criteria.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(GraphiteTheme.panelMutedText)
                            .accessibilityHidden(true)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .scrollIndicators(.hidden)
        .font(.caption)
        .help(accessibilitySummary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("当前排序规则，\(accessibilitySummary)")
    }

    private var accessibilitySummary: String {
        criteria.enumerated().map { index, criterion in
            "\(priorityLabel(at: index))\(criterion.field.rawValue)\(criterion.directionLabel)"
        }.joined(separator: "，")
    }

    private func priorityLabel(at index: Int) -> String {
        if index == 0 { return "主要：" }
        if index == 1 { return "其次：" }
        if index == criteria.count - 1 { return "最后：" }
        return "第 \(index + 1) 项："
    }
}
