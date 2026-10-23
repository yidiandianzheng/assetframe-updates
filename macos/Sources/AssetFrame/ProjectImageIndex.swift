import CryptoKit
import Foundation
import ImageIO
import Vision

struct ProjectImageIndexRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var path: String
    var relativePath: String
    var filename: String
    var folderPath: String
    var fileID: String
    var fileSize: Int64
    var sourceCreatedAt: Date? = nil
    var modifiedAt: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var inferredType: AssetType
    var visionType: AssetType?
    var visionLabels: [String]
    var visionConfidence: Double?
    var analyzedAt: Date?
    var featurePrintData: Data? = nil

    var effectiveType: AssetType {
        if inferredType != .unclassified { return inferredType }
        return visionConfidence ?? 0 >= 0.42 ? (visionType ?? .unclassified) : .unclassified
    }

    var resolutionLabel: String {
        ResolutionLabel.label(width: pixelWidth, height: pixelHeight)
    }

    var dimensionText: String {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return "尺寸待识别" }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    var searchableText: String {
        [filename, relativePath, folderPath, effectiveType.rawValue, visionLabels.joined(separator: " ")]
            .joined(separator: " ")
    }

    func previewAsset(projectID: String, projectName: String) -> AssetItem {
        AssetItem(
            id: "INDEX-\(id)",
            name: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent,
            type: effectiveType,
            imagePath: path,
            originalFilename: filename,
            decision: .pending,
            note: "",
            reuse: .b,
            project: projectName,
            episodes: [],
            candidatePlan: .none,
            version: "v01",
            purpose: .pending,
            category: .project,
            qaResult: .pending,
            productionStatus: .pendingAcceptance,
            assetDescription: visionLabels.prefix(4).joined(separator: "·"),
            repairReason: "",
            fingerprint: "",
            shapeState: "",
            promptSource: "",
            generationPlatform: "",
            position: CanvasPoint(x: 0, y: 0),
            createdAt: modifiedAt ?? .distantPast,
            projectID: projectID,
            sourceRelativePath: relativePath,
            sourceFileID: fileID,
            sourceFileSize: fileSize,
            sourceCreatedAt: sourceCreatedAt,
            sourceModifiedAt: modifiedAt,
            isSourceMissing: !FileManager.default.fileExists(atPath: path),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            tags: visionLabels
        )
    }
}

struct ProjectImageIndexProgressState: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case scanning, recognizing, completed, failed }
    var phase: Phase
    var processed: Int
    var total: Int
    var message: String
    var fraction: Double { total > 0 ? min(1, Double(processed) / Double(total)) : 0 }
}

enum ProjectImageIndexer {
    static let supportedExtensions = Set(["png", "jpg", "jpeg", "webp", "heic", "tif", "tiff"])
    private static let managedDirectories = Set([
        "00_向量时刻待导入",
        "01_向量时刻资产库",
        CodexGenerationIntake.inboxDirectoryName
    ])
    private static let featurePrintCache = FeaturePrintObservationCache()

    nonisolated static func scan(root: URL, existing: [ProjectImageIndexRecord]) -> [ProjectImageIndexRecord] {
        let existingByFileID = Dictionary(
            existing.filter { !$0.fileID.isEmpty }.map { ($0.fileID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingByPath = Dictionary(
            existing.map { (URL(fileURLWithPath: $0.path).standardizedFileURL.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isHiddenKey, .fileResourceIdentifierKey,
            .fileSizeKey, .creationDateKey, .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let rootPath = root.standardizedFileURL.path
        var records: [ProjectImageIndexRecord] = []
        while let url = enumerator.nextObject() as? URL {
            let relative = relativePath(of: url, rootPath: rootPath)
            if let first = relative.split(separator: "/").first, managedDirectories.contains(String(first)) {
                enumerator.skipDescendants()
                continue
            }
            guard supportedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isHidden != true else { continue }

            let standardized = url.standardizedFileURL
            let fileID = values.fileResourceIdentifier.map { String(describing: $0) } ?? standardized.path
            let fileSize = Int64(values.fileSize ?? 0)
            let modifiedAt = values.contentModificationDate
            let previous = existingByFileID[fileID] ?? existingByPath[standardized.path]
            let unchanged = previous?.fileSize == fileSize && previous?.modifiedAt == modifiedAt
            let dimensions = unchanged
                ? (previous?.pixelWidth, previous?.pixelHeight)
                : imageDimensions(at: standardized)
            let filename = standardized.lastPathComponent
            let folder = URL(fileURLWithPath: relative).deletingLastPathComponent().path
            let type = inferType(from: "\(relative) \(filename)")
            records.append(ProjectImageIndexRecord(
                id: stableID(fileID: fileID, path: standardized.path),
                path: standardized.path,
                relativePath: relative,
                filename: filename,
                folderPath: folder == "." ? "" : folder,
                fileID: fileID,
                fileSize: fileSize,
                sourceCreatedAt: values.creationDate,
                modifiedAt: modifiedAt,
                pixelWidth: dimensions.0,
                pixelHeight: dimensions.1,
                inferredType: type,
                visionType: unchanged ? previous?.visionType : nil,
                visionLabels: unchanged ? (previous?.visionLabels ?? []) : [],
                visionConfidence: unchanged ? previous?.visionConfidence : nil,
                analyzedAt: unchanged ? previous?.analyzedAt : nil,
                featurePrintData: unchanged ? previous?.featurePrintData : nil
            ))
        }
        return records.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    nonisolated static func recognize(_ record: ProjectImageIndexRecord) -> ProjectImageIndexRecord {
        guard FileManager.default.fileExists(atPath: record.path) else { return record }
        var copy = record
        copy.analyzedAt = .now
        let result = LocalImageClassifier.classify(atPath: record.path, generateFeaturePrint: true)
        copy.visionLabels = result.labels
        copy.visionType = result.type
        copy.visionConfidence = result.confidence
        copy.featurePrintData = result.featurePrintData
        return copy
    }

    nonisolated static func featurePrintData(atPath path: String) -> Data? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return autoreleasepool {
            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
            guard (try? handler.perform([request])) != nil,
                  let observation = request.results?.first else { return nil }
            return try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
        }
    }

    nonisolated static func featurePrintDistance(_ lhs: Data?, _ rhs: Data?) -> Float? {
        guard let lhs, let rhs,
              let left = featurePrintCache.observation(from: lhs),
              let right = featurePrintCache.observation(from: rhs) else { return nil }
        var distance: Float = 0
        guard (try? left.computeDistance(&distance, to: right)) != nil else { return nil }
        return distance
    }

    nonisolated static func inferType(from text: String) -> AssetType {
        let value = text.lowercased()
        let groups: [(AssetType, [String])] = [
            (.person, ["人物", "角色", "男主", "女主", "主角", "立绘", "头像", "人像", "character", "portrait", "person"]),
            (.creature, ["生物", "怪物", "灵兽", "妖兽", "creature", "monster", "animal"]),
            (.scene, ["场景", "环境", "街道", "室内", "外景", "建筑", "城", "房间", "scene", "environment", "landscape", "building"]),
            (.venue, ["场地", "地点", "venue", "location"]),
            (.prop, ["道具", "武器", "剑", "袋", "书", "手镯", "prop", "weapon", "object"]),
            (.cover, ["封面", "cover"]),
            (.publishCover, ["发布封面", "poster", "thumbnail"])
        ]
        for (type, keywords) in groups where keywords.contains(where: value.contains) { return type }
        return .unclassified
    }

    private nonisolated static func imageDimensions(at url: URL) -> (Int?, Int?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return (nil, nil) }
        return (
            (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        )
    }

    private nonisolated static func relativePath(of url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private nonisolated static func stableID(fileID: String, path: String) -> String {
        let raw = fileID.isEmpty ? path : "\(fileID)|\(path)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private final class FeaturePrintObservationCache: @unchecked Sendable {
    private let cache = NSCache<NSString, VNFeaturePrintObservation>()

    init() { cache.countLimit = 12_000 }

    func observation(from data: Data) -> VNFeaturePrintObservation? {
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let decoded = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self,
            from: data
        ) else { return nil }
        cache.setObject(decoded, forKey: key)
        return decoded
    }
}
