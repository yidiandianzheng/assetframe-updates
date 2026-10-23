import SwiftUI

struct PendingAIReviewSheet: View {
    @ObservedObject var store: AssetStore
    let scopedIDs: [String]
    let onReanalyze: ([String]) -> Void
    let onClose: () -> Void

    @State private var selectedIDs: Set<String> = []

    private var pendingItems: [PendingImportItem] {
        let scope = Set(scopedIDs)
        return store.pendingImports.filter {
            scope.contains($0.id) && $0.aiVisionSuggestion?.effectiveDecision == .pending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            progress
            content
            Divider()
            actionBar
        }
        .frame(minWidth: 860, minHeight: 620)
        .onAppear {
            if selectedIDs.isEmpty { selectedIDs = Set(pendingItems.map(\.id)) }
        }
        .onChange(of: pendingItems.map(\.id)) { _, ids in
            selectedIDs.formIntersection(ids)
        }
    }

    private var header: some View {
        let adoption = store.aiSuggestionAdoptionSummary
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("AI 待确认")
                    .font(.title2)
                    .bold()
                Text("建议只会在你采纳后写入软件元数据；不会移动、改名或删除原文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if adoption.reviewed > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("人工采纳率 \(adoption.adoptionRate, format: .percent.precision(.fractionLength(0)))")
                        .font(.headline)
                    Text("直接采纳 \(adoption.acceptedWithoutChanges) · 修改后采纳 \(adoption.acceptedAfterEditing) · 忽略 \(adoption.ignored)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Button("关闭", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(18)
    }

    @ViewBuilder private var progress: some View {
        if let progress = store.pendingAIClassificationProgress {
            HStack(spacing: 10) {
                if progress.phase == .analyzing {
                    ProgressView(value: progress.fraction)
                        .frame(width: 160)
                } else {
                    Image(systemName: progress.phase == .completed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(progress.phase == .completed ? Color.green : Color.orange)
                }
                Text(progress.message)
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
                Button(progress.phase == .analyzing ? "取消" : "收起") {
                    if progress.phase == .analyzing {
                        store.cancelPendingAIClassification()
                    } else {
                        store.dismissPendingAIClassificationProgress()
                    }
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()
        }
    }

    @ViewBuilder private var content: some View {
        if pendingItems.isEmpty {
            ContentUnavailableView(
                store.pendingAIClassificationProgress?.phase == .analyzing ? "正在生成建议" : "没有待确认的 AI 建议",
                systemImage: "sparkles.rectangle.stack",
                description: Text("完成分析后，类型、名称和标签建议会出现在这里。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedIDs) {
                ForEach(pendingItems) { item in
                    if let suggestion = item.aiVisionSuggestion {
                        PendingAIReviewRow(
                            item: item,
                            suggestion: suggestion,
                            onApply: { name, type, tags in
                                store.updatePendingAISuggestion(
                                    itemID: item.id,
                                    proposedName: name,
                                    assetType: type,
                                    tags: tags
                                )
                                _ = store.applyPendingAISuggestions([item.id])
                            },
                            onIgnore: { _ = store.ignorePendingAISuggestions([item.id]) }
                        )
                        .tag(item.id)
                    }
                }
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Button(selectedIDs.count == pendingItems.count ? "取消全选" : "全选") {
                selectedIDs = selectedIDs.count == pendingItems.count ? [] : Set(pendingItems.map(\.id))
            }
            .disabled(pendingItems.isEmpty)
            Text("已选 \(selectedIDs.count) / \(pendingItems.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("重新分析所选", systemImage: "arrow.clockwise") {
                onReanalyze(Array(selectedIDs))
            }
            .disabled(selectedIDs.isEmpty || store.pendingAIClassificationProgress?.phase == .analyzing)
            Button("忽略所选", systemImage: "eye.slash") {
                _ = store.ignorePendingAISuggestions(selectedIDs)
            }
            .disabled(selectedIDs.isEmpty)
            Button("采纳所选", systemImage: "checkmark.circle.fill") {
                _ = store.applyPendingAISuggestions(selectedIDs)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedIDs.isEmpty)
        }
        .buttonStyle(.bordered)
        .padding(16)
        .background(.bar)
    }
}
