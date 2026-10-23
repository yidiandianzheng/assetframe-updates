// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AssetFrame",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AssetFrame", targets: ["AssetFrame"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "AssetFrame",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/AssetFrame",
            // These experimental, disconnected workflows were committed without
            // their backing store implementations.  Keep them in source for
            // future completion, but do not let unfinished screens block the
            // production asset-library application.
            exclude: [
                "LibraryAuditView.swift",
                // “待导入”和“快速筛图”曾是同一队列的两个界面。
                // 产品只保留快速筛图，旧列表源码留作迁移证据但不再进入正式 App。
                "PendingImportView.swift",
                "PendingReviewView.swift",
                "ShortcutSettingsView.swift",
                "PendingReviewActionBar.swift",
                "PendingReviewClassificationPanel.swift",
                "PendingReviewFilmstrip.swift",
                "PendingReviewHeader.swift",
                "PendingReviewPreview.swift",
                "PendingReviewTypeFilterBar.swift",
                "PendingAISuggestionView.swift",
                "PendingImportListSnapshot.swift",
                "ScriptAssetPickerView.swift",
                "ScriptBreakdownView.swift"
            ]
        )
    ]
)
