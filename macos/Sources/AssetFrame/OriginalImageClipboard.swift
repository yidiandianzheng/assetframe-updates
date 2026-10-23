import AppKit
import UniformTypeIdentifiers

enum OriginalImageClipboardError: LocalizedError {
    case missingFile
    case unreadableImage
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .missingFile: "原图文件已移动或磁盘未连接"
        case .unreadableImage: "无法读取原图数据"
        case .writeFailed: "无法写入系统剪贴板"
        }
    }
}

private struct OriginalImageClipboardPayload: Sendable {
    let fileURL: String
    let originalData: Data
    let originalTypeIdentifier: String?
    let tiffData: Data
}

@MainActor
enum OriginalImageClipboard {
    /// 同时提供原文件、原始编码和 TIFF 备用表示，兼容文件粘贴与图片粘贴。
    static func copyImage(at url: URL, to pasteboard: NSPasteboard = .general) throws {
        try write(makePayload(at: url), to: pasteboard)
    }

    /// Read and convert large originals away from the UI thread, then publish
    /// the prepared representations to the system pasteboard on the main actor.
    static func copyImageInBackground(at url: URL, to pasteboard: NSPasteboard = .general) async throws {
        let payload = try await Task.detached(priority: .userInitiated) {
            try makePayload(at: url)
        }.value
        try write(payload, to: pasteboard)
    }

    nonisolated private static func makePayload(at url: URL) throws -> OriginalImageClipboardPayload {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OriginalImageClipboardError.missingFile
        }
        guard let originalData = try? Data(contentsOf: url, options: .mappedIfSafe),
              let image = NSImage(data: originalData),
              let tiffData = image.tiffRepresentation else {
            throw OriginalImageClipboardError.unreadableImage
        }
        let identifier = UTType(filenameExtension: url.pathExtension)
            .flatMap { $0.conforms(to: .image) ? $0.identifier : nil }
        return OriginalImageClipboardPayload(
            fileURL: url.absoluteString,
            originalData: originalData,
            originalTypeIdentifier: identifier,
            tiffData: tiffData
        )
    }

    private static func write(_ payload: OriginalImageClipboardPayload, to pasteboard: NSPasteboard) throws {
        let item = NSPasteboardItem()
        item.setString(payload.fileURL, forType: .fileURL)
        if let identifier = payload.originalTypeIdentifier {
            item.setData(payload.originalData, forType: NSPasteboard.PasteboardType(identifier))
        }
        item.setData(payload.tiffData, forType: .tiff)

        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw OriginalImageClipboardError.writeFailed
        }
    }
}
