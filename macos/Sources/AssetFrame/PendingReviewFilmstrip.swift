import SwiftUI

struct PendingReviewFilmstrip: View {
    let items: [PendingImportItem]
    let currentID: String?
    let onSelect: (String) -> Void
    let onSetStatus: (String, PendingReviewStatus) -> Void
    let onRevealOriginal: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 9) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item.id)
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                AssetThumbnail(
                                    asset: item.previewAsset,
                                    size: CGSize(width: 108, height: 74),
                                    contentMode: .fit
                                )
                                Image(systemName: item.effectiveReviewStatus.systemImage)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(
                                        .white,
                                        statusColor(item.effectiveReviewStatus)
                                    )
                                    .padding(5)
                            }
                            .padding(3)
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(
                                        currentID == item.id ? Color.accentColor : Color.secondary.opacity(0.2),
                                        lineWidth: currentID == item.id ? 3 : 1
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                        .accessibilityLabel(
                            "\(item.originalFilename)，\(item.effectiveReviewStatus.displayName)"
                        )
                        .accessibilityValue(currentID == item.id ? "当前图片" : "")
                        .contextMenu {
                            if item.effectiveReviewStatus == .discarded {
                                Button("取消废片标记", systemImage: "arrow.uturn.backward") {
                                    onSetStatus(item.id, .unreviewed)
                                }
                            } else {
                                Button("标为废片（暂不删除）", systemImage: "xmark.circle") {
                                    onSetStatus(item.id, .discarded)
                                }
                            }
                            if item.effectiveReviewStatus != .kept {
                                Button("标为保留", systemImage: "checkmark.circle") {
                                    onSetStatus(item.id, .kept)
                                }
                            }
                            Divider()
                            Button("打开原图位置", systemImage: "folder") {
                                onRevealOriginal(item.id)
                            }
                            Divider()
                            Button("反馈这里…", systemImage: "square.and.pencil") {
                                NotificationCenter.default.post(name: .recordOptimizationFeedback, object: nil)
                            }
                            Button("查看反馈与建议", systemImage: "note.text") {
                                NotificationCenter.default.post(name: .showOptimizationNotes, object: nil)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .onAppear {
                if let currentID { proxy.scrollTo(currentID, anchor: .center) }
            }
            .onChange(of: currentID) { _, newID in
                if let newID {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
        .frame(height: 102)
    }

    private func statusColor(_ status: PendingReviewStatus) -> Color {
        switch status {
        case .unreviewed: .secondary
        case .kept: .green
        case .discarded: .red
        }
    }
}
