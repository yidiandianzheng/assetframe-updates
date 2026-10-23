import AppKit
import Foundation

/// Rare-format fallback used only after the bounded ImageIO preview path fails.
enum MaterialThumbnailFallback {
    static func load(path: String) -> NSImage? {
        NSImage(contentsOf: URL(fileURLWithPath: path))
    }
}
