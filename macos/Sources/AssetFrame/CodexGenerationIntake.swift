import CryptoKit
import Foundation
import ImageIO

enum CodexGenerationIntake {
    struct ScanResult: Sendable {
        var pendingItems: [PendingImportItem]
        var batches: [GenerationBatchRecord]
        var duplicateCount: Int
        var invalidCount: Int
    }

    static let inboxDirectoryName = "02_向量时刻Codex生成候选"
    static let manifestFilename = ".assetframe-generation.json"
    static let contextFilename = ".assetframe-project.json"
    static let globalContextFilename = "codex-current-project.json"
    static let instructionsFilename = "Codex生成图保存说明.md"
    static let namingPattern = "类型_主体_形态_GyyMMdd-HHmmss_R迭代_C候选序号"

    static func scan(
        project: ProjectRecord,
        projectRoot: URL,
        existingPending: [PendingImportItem],
        existingAssets: [AssetItem]
    ) -> ScanResult {
        let inbox = projectRoot.appendingPathComponent(inboxDirectoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: inbox.path),
              let enumerator = FileManager.default.enumerator(
                at: inbox,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
              ) else {
            return ScanResult(pendingItems: [], batches: [], duplicateCount: 0, invalidCount: 0)
        }

        let projectRootPath = projectRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let inboxPath = inbox.resolvingSymlinksInPath().standardizedFileURL.path
        let existingHashes = Set(
            existingPending.compactMap(\.generationProvenance?.contentSHA256)
                + existingAssets.compactMap(\.generationProvenance?.contentSHA256)
        )
        let existingCandidateIDs = Set(
            existingPending.compactMap(\.generationProvenance?.candidateID)
                + existingAssets.compactMap(\.generationProvenance?.candidateID)
        )
        var scannedHashes: Set<String> = []
        var pendingItems: [PendingImportItem] = []
        var batchesByID: [String: GenerationBatchRecord] = [:]
        var duplicateCount = 0
        var invalidCount = 0

        while let manifestURL = enumerator.nextObject() as? URL {
            guard manifestURL.lastPathComponent == manifestFilename else { continue }
            guard let manifest = decodeManifest(at: manifestURL),
                  manifest.schemaVersion == 1,
                  manifest.projectID == project.id,
                  !manifest.batchID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !manifest.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                invalidCount += 1
                continue
            }

            let manifestRelativePath = relativePath(of: manifestURL, rootPath: projectRootPath)
            let promptHash = normalizedHash(manifest.promptHash) ?? sha256(Data(manifest.prompt.utf8))
            batchesByID[manifest.batchID] = GenerationBatchRecord(
                id: manifest.batchID,
                projectID: manifest.projectID,
                taskID: cleaned(manifest.taskID),
                taskTitle: manifest.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                generationPlatform: manifest.generationPlatform.trimmingCharacters(in: .whitespacesAndNewlines),
                modelName: cleaned(manifest.modelName),
                prompt: manifest.prompt,
                promptHash: promptHash,
                operation: manifest.operation,
                parentBatchID: cleaned(manifest.parentBatchID),
                parentAssetID: cleaned(manifest.parentAssetID),
                parentFingerprint: normalizedHash(manifest.parentFingerprint),
                intendedType: manifest.intendedType,
                entityName: cleaned(manifest.entityName),
                variantName: cleaned(manifest.variantName),
                createdAt: manifest.createdAt,
                manifestRelativePath: manifestRelativePath
            )

            for candidate in manifest.candidates.sorted(by: candidateSort) {
                if existingCandidateIDs.contains(candidate.id) { continue }
                guard candidate.candidateIndex > 0, candidate.iteration > 0,
                      let candidateURL = validatedCandidateURL(
                        relativePath: candidate.relativePath,
                        projectRoot: projectRoot,
                        inboxPath: inboxPath
                      ),
                      let metadata = metadata(for: candidateURL, projectRootPath: projectRootPath),
                      let contentHash = fileSHA256(at: candidateURL) else {
                    invalidCount += 1
                    continue
                }
                if let expectedHash = normalizedHash(candidate.sha256), expectedHash != contentHash {
                    invalidCount += 1
                    continue
                }
                if existingHashes.contains(contentHash) { continue }
                guard scannedHashes.insert(contentHash).inserted else {
                    duplicateCount += 1
                    continue
                }

                let type = candidate.assetType
                    ?? manifest.intendedType
                    ?? inferredType(filename: candidateURL.lastPathComponent)
                let name = preferredName(
                    candidate: candidate,
                    manifest: manifest,
                    fallbackURL: candidateURL
                )
                let provenance = GenerationProvenance(
                    batchID: manifest.batchID,
                    candidateID: candidate.id,
                    taskID: cleaned(manifest.taskID),
                    taskTitle: manifest.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                    generationPlatform: manifest.generationPlatform.trimmingCharacters(in: .whitespacesAndNewlines),
                    modelName: cleaned(manifest.modelName),
                    operation: manifest.operation,
                    candidateIndex: candidate.candidateIndex,
                    iteration: candidate.iteration,
                    contentSHA256: contentHash,
                    parentBatchID: cleaned(manifest.parentBatchID),
                    parentAssetID: cleaned(manifest.parentAssetID),
                    parentFingerprint: normalizedHash(manifest.parentFingerprint),
                    generatedAt: candidate.generatedAt ?? manifest.createdAt,
                    manifestRelativePath: manifestRelativePath
                )
                pendingItems.append(PendingImportItem(
                    id: candidate.id,
                    stagedPath: candidateURL.path,
                    originalSourcePath: candidateURL.path,
                    originalFilename: candidateURL.lastPathComponent,
                    sourceFileID: metadata.fileID,
                    sourceFileSize: metadata.fileSize,
                    sourceCreatedAt: metadata.createdAt,
                    sourceModifiedAt: metadata.modifiedAt,
                    pixelWidth: metadata.pixelWidth,
                    pixelHeight: metadata.pixelHeight,
                    suggestedType: type,
                    category: candidate.category ?? .project,
                    createdAt: provenance.generatedAt,
                    preferredName: name,
                    manualTags: normalizedTags(candidate.tags ?? []),
                    suggestedPurpose: candidate.purpose,
                    generationProvenance: provenance,
                    wasPreferredNameManuallyEdited: false
                ))
            }
        }

        return ScanResult(
            pendingItems: pendingItems.sorted { $0.createdAt < $1.createdAt },
            batches: batchesByID.values.sorted { $0.createdAt < $1.createdAt },
            duplicateCount: duplicateCount,
            invalidCount: invalidCount
        )
    }

    static func writeProjectContext(
        project: ProjectRecord,
        projectRoot: URL,
        applicationSupportRoot: URL
    ) throws {
        let inbox = projectRoot.appendingPathComponent(inboxDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let context = CodexGenerationProjectContext(
            schemaVersion: 1,
            projectID: project.id,
            projectName: project.name,
            projectRootPath: projectRoot.path,
            inboxPath: inbox.path,
            inboxRelativePath: inboxDirectoryName,
            manifestFilename: manifestFilename,
            namingPattern: namingPattern,
            updatedAt: .now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(context)
        try data.write(to: inbox.appendingPathComponent(contextFilename), options: .atomic)
        try data.write(
            to: applicationSupportRoot.appendingPathComponent(globalContextFilename),
            options: .atomic
        )
        try Data(instructions(project: project).utf8).write(
            to: inbox.appendingPathComponent(instructionsFilename),
            options: .atomic
        )
    }

    static func promptHash(_ prompt: String) -> String {
        sha256(Data(prompt.utf8))
    }

    static func fileSHA256(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct CandidateMetadata {
        var fileID: String
        var fileSize: Int64
        var createdAt: Date?
        var modifiedAt: Date?
        var pixelWidth: Int?
        var pixelHeight: Int?
    }

    private static func decodeManifest(at url: URL) -> CodexGenerationManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodexGenerationManifest.self, from: data)
    }

    private static func validatedCandidateURL(
        relativePath: String,
        projectRoot: URL,
        inboxPath: String
    ) -> URL? {
        let cleanedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedPath.isEmpty, !cleanedPath.hasPrefix("/") else { return nil }
        let candidateURL = projectRoot
            .appendingPathComponent(cleanedPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard candidateURL.path.hasPrefix(inboxPath + "/"),
              FileManager.default.fileExists(atPath: candidateURL.path) else { return nil }
        return candidateURL
    }

    private static func metadata(for url: URL, projectRootPath: String) -> CandidateMetadata? {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileResourceIdentifierKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true else { return nil }
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let properties = source.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        }
        return CandidateMetadata(
            fileID: values.fileResourceIdentifier.map { String(describing: $0) } ?? url.path,
            fileSize: Int64(values.fileSize ?? 0),
            createdAt: values.creationDate,
            modifiedAt: values.contentModificationDate,
            pixelWidth: (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            pixelHeight: (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        )
    }

    private static func preferredName(
        candidate: GenerationCandidateRecord,
        manifest: CodexGenerationManifest,
        fallbackURL: URL
    ) -> String {
        if let value = cleaned(candidate.preferredName) { return value }
        let parts = [
            cleaned(manifest.entityName),
            cleaned(manifest.variantName),
            candidate.purpose?.rawValue
        ].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: "｜") }
        return fallbackURL.deletingPathExtension().lastPathComponent
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        Array(Set(tags.compactMap(cleaned))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private static func inferredType(filename: String) -> AssetType {
        FilenameAssetClassifier.classify(path: filename).type
    }

    private static func relativePath(of url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleanedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanedValue.isEmpty ? nil : cleanedValue
    }

    private static func normalizedHash(_ value: String?) -> String? {
        cleaned(value)?.lowercased()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func candidateSort(
        lhs: GenerationCandidateRecord,
        rhs: GenerationCandidateRecord
    ) -> Bool {
        if lhs.iteration != rhs.iteration { return lhs.iteration < rhs.iteration }
        return lhs.candidateIndex < rhs.candidateIndex
    }

    private static func instructions(project: ProjectRecord) -> String {
        """
        # Codex 生成图保存协议

        当前 AssetFrame 项目：\(project.name)

        项目 ID：`\(project.id)`

        Codex 完成一次图片生成后：

        1. 在本目录下建立 `日期/任务名/批次ID/`。
        2. 图片命名使用 `类型_主体_形态_GyyMMdd-HHmmss_R迭代_C候选序号`。
        3. 原图只新增、不覆盖、不重命名。
        4. 在批次目录原子写入 `\(manifestFilename)`；候选路径必须是项目根目录内的相对路径。
        5. 不把候选直接写入 `01_向量时刻资产库`，正式入库仍由用户确认。

        manifest 的 `schemaVersion` 固定为 `1`，`projectID` 必须与上方项目 ID 完全一致。
        `operation` 只能使用 `create`、`edit`、`regenerate`、`upscale`。
        每个 candidate 必须提供稳定唯一的 `id`、`relativePath`、`candidateIndex` 和 `iteration`。
        建议同时写入 `sha256`；改图、重生成或超分时写入父批次、父资产或父图指纹。

        软件只读取这份本地协议，不上传图片、提示词或绝对路径。
        """
    }
}
