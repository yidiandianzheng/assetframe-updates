import SwiftUI

enum AppSurfaceTokens {
    @MainActor static var canvas: Color { GraphiteTheme.canvas }
    @MainActor static var toolbar: Color { GraphiteTheme.toolbar }
    @MainActor static var card: Color { GraphiteTheme.card }
    @MainActor static var assetWell: Color { GraphiteTheme.assetWell }
    @MainActor static var primaryText: Color { Color(nsColor: .labelColor) }
    @MainActor static var secondaryText: Color { Color(nsColor: .secondaryLabelColor) }
    @MainActor static var separator: Color { Color(nsColor: .separatorColor) }
}

struct QueryAwareEmptyState: View {
    enum Kind: String, CaseIterable, Equatable {
        case emptyLibrary
        case noSearchResults
        case noFilterResults
        case missingSource
        case loadFailure
    }

    let kind: Kind
    var clearQuery: (() -> Void)? = nil
    var primaryActionTitle: String? = nil
    var primaryAction: (() -> Void)? = nil
    var secondaryActionTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            if let clearQuery, kind == .noSearchResults || kind == .noFilterResults {
                Button("清除搜索和筛选", action: clearQuery)
            }
            if let primaryActionTitle, let primaryAction {
                Button(primaryActionTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
            }
            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle, action: secondaryAction)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var title: String {
        switch kind {
        case .emptyLibrary: "还没有素材"
        case .noSearchResults: "没有匹配的搜索结果"
        case .noFilterResults: "当前筛选没有结果"
        case .missingSource: "源文件不可用"
        case .loadFailure: "素材加载失败"
        }
    }

    private var description: String {
        switch kind {
        case .emptyLibrary: "导入或链接素材后会显示在这里。"
        case .noSearchResults: "换一个关键词，或清除当前搜索。"
        case .noFilterResults: "放宽类型、格式、比例、评分或来源筛选。"
        case .missingSource: "重新连接原文件位置后即可继续使用。"
        case .loadFailure: "数据未能读取，请检查存储位置后重试。"
        }
    }

    private var systemImage: String {
        switch kind {
        case .emptyLibrary: "square.stack.3d.up"
        case .noSearchResults: "magnifyingglass"
        case .noFilterResults: "line.3.horizontal.decrease.circle"
        case .missingSource: "exclamationmark.triangle"
        case .loadFailure: "externaldrive.badge.exclamationmark"
        }
    }
}

struct ResponsiveCommandBar<Expanded: View, Compact: View>: View {
    @ViewBuilder let expanded: () -> Expanded
    @ViewBuilder let compact: () -> Compact

    var body: some View {
        ViewThatFits(in: .horizontal) {
            expanded()
            compact()
        }
    }
}

struct ContextualWorkspaceToolbar<Content: View>: View {
    let searchContext: WorkspaceSearchContext
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 16)
            .background(AppSurfaceTokens.toolbar)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(searchContext.supportsSearch ? "当前工作区工具栏，支持搜索" : "当前工作区工具栏")
    }
}

struct AppStatusPresenter: View {
    enum Kind { case success, failure, destructive }
    let message: String
    var kind: Kind = .success

    var body: some View {
        Label(message, systemImage: icon)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.thickMaterial, in: Capsule())
            .accessibilityLabel(message)
    }

    private var icon: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .destructive: "trash.fill"
        }
    }
}
