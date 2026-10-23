import SwiftUI

struct PendingReviewHeader: View {
    let currentPosition: Int
    let totalCount: Int
    let allItemCount: Int
    let keptCount: Int
    let discardedCount: Int
    let unreviewedCount: Int
    let isShowingDiscardedOnly: Bool
    let aiEligibleCount: Int
    let aiPendingSuggestionCount: Int
    let isAIAnalyzing: Bool
    let onAIOrganize: () -> Void
    let onShowAIReview: () -> Void
    let onKeepAllUnreviewed: () -> Void
    let onToggleDiscardedOnly: () -> Void
    let onImportKept: () -> Void
    let onTrashDiscarded: () -> Void
    let actionsDisabled: Bool
    @State private var showsKeepAllConfirmation = false
    @State private var showsTrashConfirmation = false

    var body: some View {
        ResponsiveCommandBar {
            expandedBar
        } compact: {
            compactBar
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .confirmationDialog(
            "当前批次全部通过？",
            isPresented: $showsKeepAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("将待判断 \(unreviewedCount) 张标为保留", action: onKeepAllUnreviewed)
            Button("取消", role: .cancel) {}
        } message: {
            Text("只处理当前批次中的待判断图片；已保留和废片保持不变，不会直接入库、删除文件或改动原图。")
        }
        .confirmationDialog(
            "统一删除已标记的废片？",
            isPresented: $showsTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("移到系统废纸篓 \(discardedCount) 张", role: .destructive, action: onTrashDiscarded)
            Button("取消", role: .cancel) {}
        } message: {
            Text("会逐张核验原文件，再移到 macOS 系统废纸篓。原图缺失、内容变化或无法验证的图片不会删除，会继续留在待确认区。")
        }
    }

    private var expandedBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("快速筛图")
                    .font(.title2.bold())
                Text("当前 \(currentPosition) / \(totalCount) · 已保留 \(keptCount) · 废片 \(discardedCount) · 待判断 \(unreviewedCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Label("废片仅标记，统一删除时才处理文件", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(
                isAIAnalyzing ? "AI 分析中…" : "AI 看图整理 \(aiEligibleCount) 张",
                systemImage: "sparkles.rectangle.stack",
                action: onAIOrganize
            )
            .disabled(actionsDisabled || isAIAnalyzing || aiEligibleCount == 0)
            .help("仅分析当前批次仍为待分类的图片；发送 1280px 预览到已配置的视觉 API")
            if aiPendingSuggestionCount > 0 {
                Button("AI 待确认 \(aiPendingSuggestionCount)", systemImage: "checkmark.bubble", action: onShowAIReview)
                    .tint(.orange)
            }
            Button("全部通过 \(unreviewedCount) 张", systemImage: "checkmark.circle.fill") {
                showsKeepAllConfirmation = true
            }
            .tint(.green)
            .disabled(actionsDisabled || isShowingDiscardedOnly || unreviewedCount == 0)
            .help("将当前批次的待判断图片全部标为保留，不会直接入库")
            Button(
                isShowingDiscardedOnly ? "查看全部 \(allItemCount) 张" : "查看废片 \(discardedCount) 张",
                systemImage: isShowingDiscardedOnly ? "rectangle.stack" : "eye",
                action: onToggleDiscardedOnly
            )
            .disabled(actionsDisabled || (!isShowingDiscardedOnly && discardedCount == 0))
            .accessibilityValue(isShowingDiscardedOnly ? "正在只显示废片" : "正在显示全部图片")
            .help(isShowingDiscardedOnly ? "返回当前批次的全部图片" : "只浏览当前批次中已标记的废片")
            Button("统一删除废片 \(discardedCount) 张", systemImage: "trash", role: .destructive) {
                showsTrashConfirmation = true
            }
            .disabled(actionsDisabled || discardedCount == 0)
            Button("完成筛图并入库 \(keptCount) 张", systemImage: "tray.and.arrow.down.fill", action: onImportKept)
                .buttonStyle(.borderedProminent)
                .disabled(actionsDisabled || keptCount == 0)
        }
    }

    private var compactBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("快速筛图").font(.headline)
                Text("\(currentPosition)/\(totalCount) · 保留 \(keptCount) · 废片 \(discardedCount) · 待判断 \(unreviewedCount)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Menu("筛图操作", systemImage: "ellipsis.circle") {
                Button("AI 看图整理 \(aiEligibleCount) 张", systemImage: "sparkles.rectangle.stack", action: onAIOrganize)
                    .disabled(actionsDisabled || isAIAnalyzing || aiEligibleCount == 0)
                if aiPendingSuggestionCount > 0 {
                    Button("AI 待确认 \(aiPendingSuggestionCount)", systemImage: "checkmark.bubble", action: onShowAIReview)
                }
                Divider()
                Button("全部通过 \(unreviewedCount) 张", systemImage: "checkmark.circle.fill") { showsKeepAllConfirmation = true }
                    .disabled(actionsDisabled || isShowingDiscardedOnly || unreviewedCount == 0)
                Button(isShowingDiscardedOnly ? "查看全部 \(allItemCount) 张" : "查看废片 \(discardedCount) 张", systemImage: "eye", action: onToggleDiscardedOnly)
                    .disabled(actionsDisabled || (!isShowingDiscardedOnly && discardedCount == 0))
                Button("统一删除废片 \(discardedCount) 张", systemImage: "trash", role: .destructive) { showsTrashConfirmation = true }
                    .disabled(actionsDisabled || discardedCount == 0)
            }
            Button("入库 \(keptCount)", systemImage: "tray.and.arrow.down.fill", action: onImportKept)
                .buttonStyle(.borderedProminent)
                .disabled(actionsDisabled || keptCount == 0)
        }
    }
}
