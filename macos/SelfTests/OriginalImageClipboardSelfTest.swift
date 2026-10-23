import AppKit
import Foundation

@main
struct OriginalImageClipboardSelfTest {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OriginalImageClipboardSelfTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("original.png")
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 6,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            preconditionFailure("必须创建测试位图")
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            preconditionFailure("必须生成测试 PNG")
        }
        try png.write(to: url)

        let pasteboard = NSPasteboard(name: .init("assetframe.original-image.self-test"))
        try OriginalImageClipboard.copyImage(at: url, to: pasteboard)
        let types = Set(pasteboard.types ?? [])
        precondition(types.contains(.fileURL), "剪贴板必须包含原文件 URL")
        precondition(types.contains(.png), "剪贴板必须保留原始 PNG 编码")
        precondition(types.contains(.tiff), "剪贴板必须提供通用无损图像备用格式")
        precondition(pasteboard.data(forType: .png) == png, "PNG 数据必须与原图字节一致")

        let backgroundPasteboard = NSPasteboard(name: .init("assetframe.original-image.background.self-test"))
        try await OriginalImageClipboard.copyImageInBackground(at: url, to: backgroundPasteboard)
        let backgroundTypes = Set(backgroundPasteboard.types ?? [])
        precondition(backgroundTypes.contains(.fileURL), "后台复制必须包含原文件 URL")
        precondition(backgroundTypes.contains(.png), "后台复制必须保留原始 PNG 编码")
        precondition(backgroundTypes.contains(.tiff), "后台复制必须提供 TIFF 备用格式")
        precondition(backgroundPasteboard.data(forType: .png) == png, "后台复制不能改变原图字节")

        print("OriginalImageClipboardSelfTest passed")
    }
}
