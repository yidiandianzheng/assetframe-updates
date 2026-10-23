import AppKit
import SwiftUI

struct OptimizationFeedbackCapture: NSViewRepresentable {
    let isEnabled: Bool
    var consumesRightClick = false
    let onCapture: (NormalizedRect) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FeedbackCaptureNSView {
        let view = FeedbackCaptureNSView()
        context.coordinator.hostView = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: FeedbackCaptureNSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.consumesRightClick = consumesRightClick
        context.coordinator.onCapture = onCapture
    }

    static func dismantleNSView(_ nsView: FeedbackCaptureNSView, coordinator: Coordinator) {
        coordinator.uninstallMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var hostView: FeedbackCaptureNSView?
        var isEnabled = false
        var consumesRightClick = false
        var onCapture: ((NormalizedRect) -> Void)?
        private var monitor: Any?

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self, self.isEnabled, let hostView = self.hostView,
                      let window = hostView.window, event.window === window else { return event }
                let point = hostView.convert(event.locationInWindow, from: nil)
                guard hostView.bounds.contains(point) else { return event }
                let rect = self.targetRect(at: point, windowPoint: event.locationInWindow, in: hostView)
                self.onCapture?(self.normalized(rect, in: hostView.bounds.size))
                return self.consumesRightClick ? nil : event
            }
        }

        func uninstallMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func targetRect(at point: CGPoint, windowPoint: CGPoint, in hostView: NSView) -> CGRect {
            if let contentView = hostView.window?.contentView,
               let hitView = contentView.hitTest(contentView.convert(windowPoint, from: nil)) {
                var candidate: NSView? = hitView
                while let view = candidate {
                    let converted = hostView.convert(view.bounds, from: view)
                    let area = converted.width * converted.height
                    let hostArea = max(1, hostView.bounds.width * hostView.bounds.height)
                    if converted.width >= 44, converted.height >= 28, area / hostArea <= 0.32 {
                        return converted.insetBy(dx: -12, dy: -12).intersection(hostView.bounds)
                    }
                    candidate = view.superview
                }
            }

            let width = min(360, max(180, hostView.bounds.width * 0.24))
            let height = min(220, max(110, hostView.bounds.height * 0.20))
            let x = min(max(0, point.x - width / 2), max(0, hostView.bounds.width - width))
            let y = min(max(0, point.y - height / 2), max(0, hostView.bounds.height - height))
            return CGRect(x: x, y: y, width: width, height: height)
        }

        private func normalized(_ rect: CGRect, in size: CGSize) -> NormalizedRect {
            let width = max(1, size.width)
            let height = max(1, size.height)
            return NormalizedRect(
                x: max(0, min(1, rect.minX / width)),
                y: max(0, min(1, rect.minY / height)),
                width: max(0.01, min(1, rect.width / width)),
                height: max(0.01, min(1, rect.height / height))
            )
        }
    }
}

@MainActor
final class FeedbackCaptureNSView: NSView {
    override var isFlipped: Bool { true }
}

struct OptimizationFeedbackHighlights: View {
    let notes: [OptimizationNote]
    let draft: OptimizationNoteDraft?
    let isEnabled: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if isEnabled {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                        marker(rect: note.region.rect(in: proxy.size), number: index + 1, isDraft: false)
                    }
                }
                if let draft {
                    marker(rect: draft.region.rect(in: proxy.size), number: nil, isDraft: true)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func marker(rect: CGRect, number: Int?, isDraft: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.orange.opacity(isDraft ? 0.13 : 0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: isDraft ? 3 : 2, dash: isDraft ? [] : [6, 4]))
            }
            .overlay(alignment: .topLeading) {
                if let number {
                    Text("\(number)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(.orange, in: Circle())
                        .offset(x: -8, y: -8)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }
}

struct OptimizationNoteEditor: View {
    let draft: OptimizationNoteDraft
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("记录优化建议", systemImage: "scope")
                .font(.title3.weight(.semibold))
            Text("已重点标记“\(draft.viewName)”中的右键区域。写下希望怎么改，保存后会进入优化建议清单。")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("例如：这里的按钮太挤，希望缩小间距", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(4...8)
            HStack {
                Text("记录版本：\(AppVersion.display)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onCancel)
                Button("保存优化建议") { onSave(text) }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

struct OptimizationNotesView: View {
    let notes: [OptimizationNote]
    let onStatusChange: (OptimizationNote, OptimizationNoteStatus) -> Void
    let onDelete: (OptimizationNote) -> Void
    @State private var statusFilter: OptimizationNoteStatus?

    private var visibleNotes: [OptimizationNote] {
        guard let statusFilter else { return notes }
        return notes.filter { $0.effectiveStatus == statusFilter }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("优化建议").font(.title2.weight(.semibold))
                    Text("右键标记的界面备忘 · \(notes.count) 条")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("处理状态", selection: $statusFilter) {
                    Text("全部状态").tag(nil as OptimizationNoteStatus?)
                    ForEach(OptimizationNoteStatus.allCases) { status in
                        Text(status.rawValue).tag(status as OptimizationNoteStatus?)
                    }
                }
                .frame(width: 150)
            }
            .padding(20)
            Divider()
            if notes.isEmpty {
                ContentUnavailableView("还没有优化建议", systemImage: "note.text", description: Text("在任意界面位置点击右键，选择“记录优化建议备注”"))
            } else if visibleNotes.isEmpty {
                ContentUnavailableView("这个状态还没有建议", systemImage: "line.3.horizontal.decrease.circle")
            } else {
                List(visibleNotes) { note in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "scope").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(note.note).font(.body)
                            Text("\(note.projectName) · \(note.viewName) · \(note.version) · \(note.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("处理状态", selection: statusBinding(for: note)) {
                            ForEach(OptimizationNoteStatus.allCases) { status in Text(status.rawValue).tag(status) }
                        }
                        .labelsHidden()
                        .frame(width: 125)
                        Button("复制给 AI", systemImage: "doc.on.doc") { copyForAI(note) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("复制这条建议，交给 AI 处理")
                        Button("删除优化建议", systemImage: "trash", role: .destructive) { onDelete(note) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 520)
    }

    private func statusBinding(for note: OptimizationNote) -> Binding<OptimizationNoteStatus> {
        Binding(
            get: { note.effectiveStatus },
            set: { onStatusChange(note, $0) }
        )
    }

    private func copyForAI(_ note: OptimizationNote) {
        let text = """
        【向量时刻资产·优化建议】
        项目：\(note.projectName)
        界面：\(note.viewName)
        记录版本：\(note.version)
        当前状态：\(note.effectiveStatus.rawValue)
        建议：\(note.note)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
