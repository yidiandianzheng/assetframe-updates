import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VisionImagePreprocessor {
    static let maximumPixelSize = 1_280
    static let jpegQuality = 0.82

    struct PreparedImage: Sendable {
        var data: Data
        var mimeType: String
        var pixelWidth: Int
        var pixelHeight: Int

        var dataURL: String {
            "data:\(mimeType);base64,\(data.base64EncodedString())"
        }
    }

    nonisolated static func prepare(atPath path: String) throws -> PreparedImage {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw VisionAPIClientError.unreadableImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw VisionAPIClientError.unreadableImage
        }
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                data,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw VisionAPIClientError.imageEncodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw VisionAPIClientError.imageEncodingFailed
        }
        return PreparedImage(
            data: data as Data,
            mimeType: "image/jpeg",
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    nonisolated static func connectionTestImage() throws -> PreparedImage {
        let width = 320
        let height = 180
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw VisionAPIClientError.imageEncodingFailed
        }
        context.setFillColor(CGColor(red: 0.9, green: 0.08, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0.05, green: 0.2, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        guard let image = context.makeImage(),
              let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                data,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw VisionAPIClientError.imageEncodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw VisionAPIClientError.imageEncodingFailed
        }
        return PreparedImage(
            data: data as Data,
            mimeType: "image/jpeg",
            pixelWidth: width,
            pixelHeight: height
        )
    }
}
