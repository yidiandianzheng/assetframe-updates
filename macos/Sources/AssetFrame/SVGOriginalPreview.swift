import SwiftUI
import WebKit

struct SVGOriginalPreview: View {
    let url: URL
    @Binding var magnification: CGFloat
    let fitToken: UUID
    @State private var document: SVGDocument?
    @State private var issue: String?
    var body: some View {
        Group {
            if let document { SVGWebSurface(document: document, zoom: $magnification, fitToken: fitToken) }
            else if let issue { ContentUnavailableView("无法预览SVG", systemImage: "doc.badge.exclamationmark", description: Text(issue)) }
            else { ProgressView("正在读取SVG…") }
        }
        .task(id: url) {
            document = nil; issue = nil
            let worker = Task.detached(priority: .userInitiated) { try SVGDocument.load(url) }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }; document = value
            } catch { if !Task.isCancelled { issue = "文件无效、过大或包含不支持的实体声明" } }
        }
    }
}

private struct SVGWebSurface: NSViewRepresentable {
    let document: SVGDocument
    @Binding var zoom: CGFloat
    let fitToken: UUID
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = ResizingSVGWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.size = document.size
        context.coordinator.setZoom = { value in Task { @MainActor in zoom = value } }
        view.onResize = { [weak view, weak coordinator = context.coordinator] in if let view { coordinator?.fit(view) } }
        view.loadHTMLString(document.html(), baseURL: nil)
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.fitToken != fitToken { coordinator.fitToken = fitToken; coordinator.keepsFitted = true; coordinator.fit(view) }
        else if abs(view.pageZoom - zoom) > 0.001 { coordinator.keepsFitted = false; view.pageZoom = min(8, max(0.05, zoom)) }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var fitToken: UUID?
        var size = CGSize(width: 1000, height: 1000)
        var keepsFitted = true
        var setZoom: ((CGFloat) -> Void)?
        func fit(_ view: WKWebView) {
            guard keepsFitted, view.bounds.width > 1, view.bounds.height > 1 else { return }
            let value = min(8, max(0.05, min(view.bounds.width / size.width, view.bounds.height / size.height)))
            view.pageZoom = value; setZoom?(value)
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.request.url?.scheme == "about" && action.navigationType == .other ? .allow : .cancel
        }
    }
}

private final class ResizingSVGWebView: WKWebView {
    var onResize: (() -> Void)?
    override func layout() { super.layout(); onResize?() }
}
