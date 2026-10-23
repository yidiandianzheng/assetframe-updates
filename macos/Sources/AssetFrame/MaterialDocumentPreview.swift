import SwiftUI
import PDFKit
import Quartz

/// Render visible PDF pages natively; other documents use the embedded system
/// provider, keeping navigation and Escape in the asset-library window.
struct MaterialDocumentPreview: View {
    static func usesDocumentPreview(_ material: MaterialRecord) -> Bool {
        let ext = material.sourcePath.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        return material.kind != .image || ["psd", "psb", "ai", "eps", "pdf"].contains(ext)
    }
    let material: MaterialRecord
    @State private var document: PDFPreviewDocument?
    @State private var issue: String?
    private var url: URL? { material.sourcePath.map { URL(fileURLWithPath: $0) } }
    var body: some View {
        VStack(spacing: 8) {
            if let url {
                if url.pathExtension.lowercased() == "pdf" {
                    if let document {
                        Text("PDF · \(document.value.pageCount) 页").font(.caption).foregroundStyle(.secondary)
                        MaterialPDFSurface(document: document.value)
                    } else if let issue { ContentUnavailableView(issue, systemImage: "doc.badge.ellipsis") }
                    else { ProgressView("正在读取PDF…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                } else {
                    MaterialQuickLookSurface(url: url)
                    Text("此格式由系统预览；不支持时可打开原文件。").font(.caption).foregroundStyle(.secondary)
                }
            } else { ContentUnavailableView("原文件不可用", systemImage: "doc.badge.ellipsis") }
        }
        .task(id: url?.path) {
            document = nil; issue = nil
            guard let url, url.pathExtension.lowercased() == "pdf" else { return }
            let worker = Task.detached(priority: .userInitiated) { () -> PDFPreviewDocument? in
                guard !Task.isCancelled else { return nil }
                return PDFPreviewDocument.load(url)
            }
            let value = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            document = value
            if value == nil { issue = "PDF不可读取、已加密或超过256MB" }
        }
    }
}

/// Constructed by one worker, then exclusively owned by the main-thread view.
final class PDFPreviewDocument: @unchecked Sendable {
    let value: PDFDocument
    init(_ value: PDFDocument) { self.value = value }
    static func load(_ url: URL) -> PDFPreviewDocument? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 256 * 1024 * 1024,
              let value = PDFDocument(url: url), value.pageCount > 0, !value.isLocked else { return nil }
        return PDFPreviewDocument(value)
    }
}
private struct MaterialPDFSurface: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true; view.displayMode = .singlePageContinuous; view.displaysPageBreaks = true
        view.setAccessibilityLabel("PDF原文预览"); view.document = document
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
    static func dismantleNSView(_ view: PDFView, coordinator: ()) { view.document = nil }
}
private struct MaterialQuickLookSurface: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else { return NSTextField(labelWithString: "系统预览暂不可用") }
        view.autostarts = false; view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? QLPreviewView else { return }
        if view.previewItem?.previewItemURL?.path != url.path { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        guard let view = view as? QLPreviewView else { return }
        view.previewItem = nil; view.close()
    }
}
