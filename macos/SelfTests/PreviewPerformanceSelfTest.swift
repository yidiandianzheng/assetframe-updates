import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct PreviewPerformanceSelfTest {
    private struct Sample {
        let name: String
        let request: PreviewImageRequest
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("assetframe-preview-performance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let samples = try makeSamples(in: root)
        for sample in samples {
            var coldTimes: [Double] = []
            for index in 0..<10 {
                // A new path guarantees a cold memory/disk cache on both old and new pipelines.
                let coldURL = root.appendingPathComponent("cold-\(sample.name)-\(index)." + (sample.request.path as NSString).pathExtension)
                try FileManager.default.copyItem(atPath: sample.request.path, toPath: coldURL.path)
                let coldStart = DispatchTime.now().uptimeNanoseconds
                let request = PreviewImageRequest(
                    path: coldURL.path, sourceIdentity: "\(sample.request.sourceIdentity)|cold-\(index)",
                    sourceWidth: sample.request.sourceWidth, sourceHeight: sample.request.sourceHeight
                )
                _ = PreviewImagePipeline.shared.load(
                    request: request, viewportSize: CGSize(width: 1_440, height: 900),
                    backingScale: 2, fullResolution: false
                )
                coldTimes.append(elapsedMilliseconds(since: coldStart))
            }

            var warmTimes: [Double] = []
            for _ in 0..<30 {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = PreviewImagePipeline.shared.load(
                    request: sample.request, viewportSize: CGSize(width: 1_440, height: 900),
                    backingScale: 2, fullResolution: false
                )
                precondition(result.image != nil, "\(sample.name) 预览解码失败")
                warmTimes.append(elapsedMilliseconds(since: start))
            }

            let fullStart = DispatchTime.now().uptimeNanoseconds
            let full = PreviewImagePipeline.shared.load(
                request: sample.request, viewportSize: CGSize(width: 1_440, height: 900),
                backingScale: 2, fullResolution: true
            )
            precondition(full.image != nil, "\(sample.name) 原图解码失败")
            let fullMilliseconds = elapsedMilliseconds(since: fullStart)
            let coldP95 = percentile95(coldTimes)
            let warmP95 = percentile95(warmTimes)
            let status = coldP95 <= 500 && warmP95 <= 150 ? "PASS" : "WARN"
            print(String(format: "%@ cold_p95=%.1fms warm_p95=%.1fms full=%.1fms [%@]", sample.name, coldP95, warmP95, fullMilliseconds, status))
        }
        print("Preview performance benchmark completed (local synthetic 4K JPEG/PNG/HEIC; inspect PASS/WARN per codec)")
    }

    private static func makeSamples(in root: URL) throws -> [Sample] {
        let width = 4_096
        let height = 2_160
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else {
            throw NSError(domain: "PreviewPerformanceSelfTest", code: 1)
        }
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let definitions: [(String, UTType, CGFloat)] = [
            ("sample.png", .png, 1), ("sample.jpg", .jpeg, 0.82), ("sample.heic", .heic, 0.82)
        ]
        var samples: [Sample] = []
        for (name, type, quality) in definitions {
            let url = root.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                if type == .heic { print("HEIC encoder unavailable; skipped") ; continue }
                throw NSError(domain: "PreviewPerformanceSelfTest", code: 2)
            }
            let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "PreviewPerformanceSelfTest", code: 3) }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let identity = "\(url.path)|\(attributes[.size] ?? 0)|\(attributes[.modificationDate] ?? 0)"
            samples.append(Sample(name: name, request: PreviewImageRequest(
                path: url.path, sourceIdentity: identity, sourceWidth: width, sourceHeight: height
            )))
        }
        return samples
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }
}
