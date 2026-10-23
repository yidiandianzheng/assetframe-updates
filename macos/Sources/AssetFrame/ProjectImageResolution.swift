import Foundation
import ImageIO

struct ProjectImageResolution: Sendable, Equatable {
    var width: Int
    var height: Int
    var label: String { "分辨率：\(width) × \(height) 像素" }
    static func read(path: String) -> Self? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return .init(width: width, height: height)
    }
}
