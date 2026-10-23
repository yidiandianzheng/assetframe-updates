import AppKit
import SwiftUI

/// Installed only while the inline preview exists. The hidden collection may
/// still be first responder, so intercept navigation before responder dispatch.
struct PreviewEscapeHandler: NSViewRepresentable {
    let onExit: () -> Void
    var onNavigate: ((Int) -> Void)? = nil

    func makeNSView(context: Context) -> PreviewEscapeView {
        let view = PreviewEscapeView()
        view.onExit = onExit
        view.onNavigate = onNavigate
        return view
    }

    func updateNSView(_ view: PreviewEscapeView, context: Context) {
        view.onExit = onExit
        view.onNavigate = onNavigate
    }

    static func dismantleNSView(_ view: PreviewEscapeView, coordinator: ()) {
        view.stopMonitoring()
        view.onExit = nil
        view.onNavigate = nil
    }
}

@MainActor
final class PreviewEscapeView: NSView {
    var onExit: (() -> Void)?
    var onNavigate: ((Int) -> Void)?
    private var monitor: Any?

    static func navigationStep(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, textEditing: Bool) -> Int? {
        guard !textEditing, modifiers.intersection([.command, .option, .control, .shift]).isEmpty else { return nil }
        switch keyCode {
        case 123: return -1
        case 124: return 1
        default: return nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, let window = self.window,
                      window.isKeyWindow, event.window === window,
                      window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
                if event.keyCode == 53,
                   event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                   let onExit = self.onExit {
                    onExit()
                    return true
                }
                let textEditing = window.firstResponder is NSTextView || window.firstResponder is NSTextField
                guard let step = Self.navigationStep(keyCode: event.keyCode, modifiers: event.modifierFlags, textEditing: textEditing),
                      let onNavigate = self.onNavigate else { return false }
                onNavigate(step)
                return true
            }
            return handled ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
