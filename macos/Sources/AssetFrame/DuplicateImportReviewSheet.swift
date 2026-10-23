import SwiftUI

struct DuplicateImportReviewSheet: View {
    let candidates: [DuplicateImportCandidate]
    let onConfirm: (UUID, DuplicateImportDecision, Bool) -> Void
    let onRevealInFinder: () -> Void
    let onDismiss: () -> Void

    @State private var decision: DuplicateImportDecision = .useExisting
    @State private var applyToAll = false
    @State private var selectedID: UUID?

    private var candidate: DuplicateImportCandidate? {
        candidates.first { $0.id == selectedID } ?? candidates.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                queueList
                Divider()
                if let candidate {
                    comparison(candidate)
                } else {
                    ContentUnavailableView("没有待处理重复项", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            decisionArea
        }
        .frame(width: 980, height: 680)
        .background(GraphiteTheme.canvas)
        .onAppear { selectedID = candidate?.id }
        .onChange(of: candidates.map(\.id)) { _, ids in
            if let selectedID, ids.contains(selectedID) { return }
            self.selectedID = ids.first
            decision = .useExisting
            applyToAll = false
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(GraphiteTheme.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("重复素材（\(candidates.count)）")
                    .font(.headline)
                Text("导入已完成。集中处理内容完全相同、位置不同的图片，软件不会删除任何原图。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("关闭", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("暂存并稍后处理")
        }
        .padding(18)
    }

    private var queueList: some View {
        List(candidates, selection: $selectedID) { item in
            VStack(alignment: .leading, spacing: 4) {
                Text(item.incomingFilename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.dimensionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(item.id)
            .padding(.vertical, 3)
        }
        .frame(width: 230)
        .accessibilityLabel("待处理重复素材列表")
    }

    private func comparison(_ candidate: DuplicateImportCandidate) -> some View {
        HStack(spacing: 16) {
            DuplicateImportComparisonCard(
                title: "已存在",
                systemImage: "checkmark.circle.fill",
                asset: candidate.existingPreviewAsset,
                filename: candidate.existingFilename,
                path: candidate.existingPath,
                dimensionText: candidate.dimensionText,
                fileSizeText: candidate.fileSizeText
            )

            Image(systemName: "equal.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("内容完全相同")

            DuplicateImportComparisonCard(
                title: "新文件",
                systemImage: "plus.circle.fill",
                asset: candidate.incomingPreviewAsset,
                filename: candidate.incomingFilename,
                path: candidate.incomingPath,
                dimensionText: candidate.dimensionText,
                fileSizeText: candidate.fileSizeText
            )
        }
        .padding(18)
        .frame(maxHeight: .infinity)
    }

    private var decisionArea: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                decisionButton(
                    .useExisting,
                    title: "使用现有文件",
                    detail: "跳过新文件的重复登记",
                    systemImage: "checkmark.circle"
                )
                decisionButton(
                    .keepBoth,
                    title: "保留两者",
                    detail: "把新文件也加入待筛选队列",
                    systemImage: "square.on.square"
                )
            }

            HStack(spacing: 12) {
                Toggle("全部应用（\(candidates.count)）", isOn: $applyToAll)
                    .toggleStyle(.checkbox)
                    .disabled(candidates.count < 2)

                Spacer()

                Button("在 Finder 中查看", systemImage: "folder", action: onRevealInFinder)
                    .buttonStyle(.bordered)
                Button(candidates.count > 1 && !applyToAll ? "确认并看下一组" : "确认", action: confirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(candidate == nil)
            }
        }
        .padding(18)
        .background(GraphiteTheme.toolbar)
    }

    private func decisionButton(
        _ value: DuplicateImportDecision,
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        Button(action: { decision = value }) {
            HStack(spacing: 10) {
                Image(systemName: decision == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(decision == value ? GraphiteTheme.accent : .secondary)
                    .accessibilityHidden(true)
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(decision == value ? "已选择" : "未选择")
        .frame(maxWidth: .infinity)
        .background(decision == value ? GraphiteTheme.accent.opacity(0.12) : GraphiteTheme.card.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(decision == value ? GraphiteTheme.accent : GraphiteTheme.panelStroke, lineWidth: 1)
        }
    }

    private func confirm() {
        guard let candidate else { return }
        onConfirm(candidate.id, decision, applyToAll)
    }
}
