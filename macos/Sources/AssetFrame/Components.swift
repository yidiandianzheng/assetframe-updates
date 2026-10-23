import AppKit
import SwiftUI

struct AssetThumbnail: View {
    let asset: AssetItem
    var size: CGSize = CGSize(width: 54, height: 54)
    var contentMode: ContentMode = .fill
    var backgroundColor: Color = .white
    var opensPreview = false
    var showsOverlays = true
    var showsLoadingStatus = false
    @State private var isLoading = true
    @State private var image: NSImage?
    @State private var requestID: UUID?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .padding(contentMode == .fit ? 4 : 0)
            } else {
                ZStack {
                    LinearGradient(colors: placeholderColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(asset.type.symbol)
                        .font(.system(size: min(size.width, size.height) * 0.28, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                        .padding(8)
                        .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomLeading) {
            if showsOverlays && asset.sourceMissing {
                Label("源文件缺失", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(.orange, in: Capsule())
                    .padding(5)
            }
        }
        .overlay(alignment: .topLeading) {
            if showsOverlays && asset.resolutionLabel != "待识别" {
                Text(asset.resolutionLabel)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(resolutionColor, in: Capsule())
                    .padding(5)
            }
        }
        .overlay {
            if showsLoadingStatus && image == nil {
                VStack(spacing: 8) {
                    if isLoading { ProgressView().controlSize(.small) }
                    Text(isLoading ? "正在读取预览…" : "预览暂不可用，请在 Finder 中检查文件")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: openPreview)
        .accessibilityLabel("素材缩略图，\(asset.name)")
        .accessibilityHint(opensPreview ? "双击或使用预览操作打开高清原图" : "")
        .accessibilityAction(named: "预览高清原图", openPreview)
        .help(opensPreview ? "双击预览高清原图" : "")
        .onAppear(perform: load)
        .onChange(of: identity) { _, _ in load() }
        .onDisappear { ThumbnailPipeline.shared.cancel(requestID); requestID = nil }
    }

    private var identity: String { "\(asset.imagePath)|\(asset.sourceModifiedAt?.timeIntervalSince1970 ?? 0)|\(size.width)x\(size.height)" }

    private func openPreview() {
        guard opensPreview else { return }
        NotificationCenter.default.post(name: .previewAssetImage, object: nil, userInfo: ["id": asset.id])
    }

    private func load() {
        ThumbnailPipeline.shared.cancel(requestID)
        image = nil
        isLoading = true
        requestID = ThumbnailPipeline.shared.request(asset: asset, size: size) { loaded in
            image = loaded
            isLoading = false
        }
    }

    private var placeholderColors: [Color] {
        switch asset.type {
        case .person, .creature: return [Color(red: 0.79, green: 0.86, blue: 0.82), Color(red: 0.48, green: 0.62, blue: 0.55)]
        case .venue, .scene: return [Color(red: 0.84, green: 0.84, blue: 0.77), Color(red: 0.49, green: 0.57, blue: 0.53)]
        case .prop: return [Color(red: 0.88, green: 0.82, blue: 0.75), Color(red: 0.63, green: 0.51, blue: 0.42)]
        case .product, .cover, .publishCover, .fixedSymbol, .boundStructure: return [Color(red: 0.77, green: 0.83, blue: 0.89), Color(red: 0.42, green: 0.52, blue: 0.64)]
        case .unclassified: return [Color.gray.opacity(0.55), Color.gray.opacity(0.82)]
        }
    }

    private var resolutionColor: Color {
        switch asset.resolutionLabel { case "4K": .purple; case "2K": .blue; case "1K": .green; default: .orange }
    }
}

struct StatusPill: View {
    let status: UserDecision
    var body: some View {
        Text(status.rawValue)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }
    private var color: Color {
        switch status {
        case .confirmed: return Color(red: 0.23, green: 0.48, blue: 0.39)
        case .pending: return Color(red: 0.65, green: 0.44, blue: 0.12)
        case .rejected: return Color(red: 0.67, green: 0.25, blue: 0.16)
        }
    }
}

struct ImportProgressCard: View {
    let progress: ImportProgressState
    let canDismiss: Bool
    let onDismiss: () -> Void
    var onCancel: (() -> Void)? = nil
    var job: ImportJobProgress? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if progress.phase != .completed, let onCancel {
                    Button("停止", action: onCancel)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("停止本次读取；已经建立的索引会保留")
                }
                if canDismiss {
                    Button(action: onDismiss) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("关闭")
                }
            }

            if progress.phase == .scanning {
                ProgressView().controlSize(.small)
            } else {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let job, !job.finished {
                    Text(job.waiting(at: context.date) ? "正在等待：\(job.stage)" : "已用 \(Int(context.date.timeIntervalSince(job.startedAt))) 秒")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if progress.phase == .importing {
                VStack(alignment: .leading, spacing: 3) {
                    Text(progress.currentFilename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(remainingTimeText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 14) {
                importStat(statLabels.0, value: progress.processed)
                importStat(statLabels.1, value: progress.imported)
                importStat(statLabels.2, value: progress.skipped)
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(width: 330)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("图片导入进度")
    }

    @ViewBuilder private var statusIcon: some View {
        if progress.phase == .completed {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 25))
                .foregroundStyle(.green)
        } else {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.12))
                Image(systemName: progress.phase == .scanning ? "doc.text.magnifyingglass" : "photo.on.rectangle.angled")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }.frame(width: 28, height: 28)
        }
    }

    private var title: String {
        switch progress.kind {
        case .projectScan:
            switch progress.phase { case .scanning: "正在扫描项目文件夹"; case .importing: "正在建立原位索引"; case .completed: "项目扫描完成" }
        case .pendingStage:
            switch progress.phase { case .scanning: "正在扫描所选图片"; case .importing: "正在建立原位索引"; case .completed: "已加入待确认" }
        case .confirmImport:
            switch progress.phase { case .scanning: "正在准备入库"; case .importing: "正在确认入库"; case .completed: "确认导入完成" }
        case .imageImport:
            switch progress.phase { case .scanning: "正在扫描图片"; case .importing: "正在导入图片"; case .completed: "导入完成" }
        }
    }

    private var subtitle: String {
        switch progress.kind {
        case .projectScan, .pendingStage:
            switch progress.phase {
            case .scanning: "后台检查图片，不移动、不删除原文件"
            case .importing: progress.total == 0 ? "没有找到支持的图片" : "\(progress.processed) / \(progress.total)"
            case .completed: progress.imported > 0 ? "已索引 \(progress.imported) 项，原文件未复制" : "没有新图片，重复项已跳过"
            }
        case .confirmImport:
            switch progress.phase { case .scanning: "正在确认资产信息"; case .importing: "\(progress.processed) / \(progress.total)"; case .completed: progress.skipped == 0 ? "已登记为正式资产" : "失败项仍保留在待确认区" }
        case .imageImport:
            switch progress.phase { case .scanning: "正在确认文件数量和格式"; case .importing: progress.total == 0 ? "没有找到支持的图片" : "\(progress.processed) / \(progress.total)"; case .completed: progress.skipped == 0 ? "已成功加入资料库" : "重复或无效文件已自动跳过" }
        }
    }

    private var statLabels: (String, String, String) {
        switch progress.kind {
        case .projectScan, .pendingStage: return ("已检查", "待导入", "已跳过")
        case .confirmImport: return ("已处理", "已入库", "未完成")
        case .imageImport: return ("已处理", "已导入", "已跳过")
        }
    }

    private var remainingTimeText: String {
        guard let seconds = progress.estimatedRemainingSeconds else {
            return "正在估算剩余时间…"
        }
        if seconds < 10 { return "即将完成" }
        let rounded = Int(seconds.rounded(.up))
        if rounded < 60 { return "预计剩余约 \(rounded) 秒" }
        let minutes = rounded / 60
        if minutes < 60 { return "预计剩余约 \(minutes) 分钟" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0
            ? "预计剩余约 \(hours) 小时"
            : "预计剩余约 \(hours) 小时 \(remainingMinutes) 分钟"
    }

    private func importStat(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.system(size: 14, weight: .semibold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Owns the progress observation boundary so frequent updates redraw only the
/// small progress card instead of the complete `ContentView` workspace.
struct ImportProgressOverlay: View {
    @ObservedObject var controller: ImportProgressController
    let isImporting: Bool
    let reduceMotion: Bool
    let onDismiss: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Group {
            if let progress = controller.state {
                ImportProgressCard(
                    progress: progress,
                    canDismiss: !isImporting,
                    onDismiss: onDismiss,
                    onCancel: isImporting && (progress.kind == .projectScan || progress.kind == .pendingStage)
                        ? onCancel
                        : nil,
                    job: controller.job
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: controller.state?.id)
    }
}

struct ExportProgressCard: View {
    let progress: ExportProgressState
    let canDismiss: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(progress.message.isEmpty ? subtitle : progress.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if canDismiss { Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(.secondary) }
            }
            ProgressView(value: progress.fraction).progressViewStyle(.linear)
            if !progress.currentFilename.isEmpty { Text(progress.currentFilename).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            HStack(spacing: 16) { stat("已处理", progress.processed); stat("成功", progress.succeeded); stat("失败", progress.failed); Spacer() }
            if let path = progress.resultPath {
                Button("在 Finder 中查看") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    .controlSize(.small)
            }
        }
        .padding(16).frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 7)
    }

    private var title: String { switch progress.phase { case .validating: "正在检查导出库"; case .exporting: "正在导出资产"; case .completed: "导出完成"; case .failed: "导出未完成" } }
    private var subtitle: String { progress.total == 0 ? "没有可导出的素材" : "\(progress.processed) / \(progress.total)" }
    private var icon: String { switch progress.phase { case .completed: "checkmark.circle.fill"; case .failed: "exclamationmark.triangle.fill"; default: "shippingbox.fill" } }
    private var iconColor: Color { switch progress.phase { case .completed: .green; case .failed: .orange; default: .accentColor } }
    private func stat(_ title: String, _ value: Int) -> some View { VStack(alignment: .leading, spacing: 2) { Text("\(value)").font(.system(size: 14, weight: .semibold)); Text(title).font(.caption2).foregroundStyle(.secondary) } }
}

struct DropOverlay: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 38, weight: .light))
            Text("松开即可导入文件或文件夹")
                .font(.headline)
            Text("文件夹连同子文件夹导入素材总库；原文件保留原位")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [8, 6])).padding(14))
    }
}
