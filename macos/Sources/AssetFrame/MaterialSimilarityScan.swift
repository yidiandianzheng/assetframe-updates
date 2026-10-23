import Foundation
import ImageIO
import CoreGraphics
import CryptoKit

/// Non-destructive candidates, not an instruction to delete or merge versions.
enum MaterialSimilarityScan {
    struct Group: Identifiable, Sendable {
        var id: String
        var materialIDs: [String]
        var reason: String
    }
    struct Result: Sendable {
        var groups: [Group] = []
        var inspectedImages = 0
        var unsupportedImages = 0
        var truncated = false
    }
    static func scan(_ materials: [MaterialRecord], includeVisual: Bool) -> Result {
        let live = materials.filter { $0.deletedAt == nil }
        var result = Result()
        let exact = Dictionary(grouping: live.filter {
            let hash = $0.contentFingerprint ?? $0.fingerprint
            return hash.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }, by: { $0.kind.rawValue + "|" + ($0.contentFingerprint ?? $0.fingerprint) })
        for (key, records) in exact.sorted(by: { $0.key < $1.key }) where records.count > 1 {
            if result.groups.count >= 200 { result.truncated = true; break }
            result.groups.append(Group(id: "exact|" + key, materialIDs: records.map(\.id).sorted(), reason: "已保存内容指纹相同；整理前应复核原文件"))
        }
        guard includeVisual else { return result }
        let images = live.filter { $0.kind == .image }
        result.truncated = result.truncated || images.count > 1000
        var hashes: [(id: String, hash: UInt64, ratio: Double)] = []
        for record in images.prefix(1000) {
            guard !Task.isCancelled else { result.truncated = true; break }
            result.inspectedImages += 1
            guard let path = record.sourcePath, ImportResumeRecord.availableLocally(URL(fileURLWithPath: path)),
                  let value = visualHash(URL(fileURLWithPath: path)) else { result.unsupportedImages += 1; continue }
            // A bounded pair scan over small integer hashes, not full decoded images.
            let matches = hashes.filter { candidate in
                abs(log(max(0.001, value.ratio) / max(0.001, candidate.ratio))) < 0.14 &&
                (candidate.hash ^ value.hash).nonzeroBitCount <= 6
            }.prefix(12)
            for match in matches {
                let ids = [match.id, record.id].sorted()
                let key = "visual|" + ids.joined(separator: "|")
                if result.groups.count < 200 { result.groups.append(Group(id: key, materialIDs: ids, reason: "画面结构相近，需人工比较；不保证内容相同")) }
            }
            hashes.append((record.id, value.hash, value.ratio))
        }
        return result
    }
    struct VisualHash: Codable, Sendable { var hash: UInt64; var ratio: Double }
    static func visualHash(_ url: URL) -> VisualHash? {
        guard !Task.isCancelled, let info = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = info.fileSize, size <= 256 * 1024 * 1024 else { return nil }
        let identity = "dhash-v1|\(url.path)|\(size)|\(info.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let cache = SSDPreviewCache.directory("SimilarityHashes").appendingPathComponent(key + ".json")
        if let data = try? Data(contentsOf: cache), let value = try? JSONDecoder().decode(VisualHash.self, from: data) {
            SSDPreviewCache.recordAccess(cache); return value
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        let valid = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8)); return true
        }
        guard valid, !Task.isCancelled,
              let after = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), after.fileSize == info.fileSize, after.contentModificationDate == info.contentModificationDate else { return nil }
        var hash: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 { if pixels[y*9+x] > pixels[y*9+x+1] { hash |= 1 << (y*8+x) } } }
        let value = VisualHash(hash: hash, ratio: Double(image.width) / Double(max(1, image.height)))
        if let data = try? JSONEncoder().encode(value) { _ = SSDPreviewCache.write(data, to: cache) }
        return value
    }
}
