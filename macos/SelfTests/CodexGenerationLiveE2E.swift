import Foundation

@main
struct CodexGenerationLiveE2E {
    @MainActor
    static func main() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["ASSETFRAME_REAL_IMAGE_PATH"],
              FileManager.default.fileExists(atPath: sourcePath) else {
            preconditionFailure("ASSETFRAME_REAL_IMAGE_PATH 必须指向真实生成图片")
        }

        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let supportRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: supportRoot) }

        let store = AssetStore(rootURL: supportRoot)
        await waitUntil { !store.isLoadingProject }
        let projectRoot = store.currentProjectRootURL
        let batchID = "G-LIVE-\(UUID().uuidString.prefix(8))"
        let batchDirectory = projectRoot
            .appendingPathComponent(CodexGenerationIntake.inboxDirectoryName, isDirectory: true)
            .appendingPathComponent("真实E2E/Codex/\(batchID)", isDirectory: true)
        try fileManager.createDirectory(at: batchDirectory, withIntermediateDirectories: true)

        let fileExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        let candidateURL = batchDirectory
            .appendingPathComponent("道具_蓝色测试方块_基础_\(batchID)_R01_C01.\(fileExtension)")
        try fileManager.copyItem(at: sourceURL, to: candidateURL)
        guard let contentHash = CodexGenerationIntake.fileSHA256(at: candidateURL) else {
            preconditionFailure("无法读取真实生成图片")
        }

        let candidateID = "LIVE-\(UUID().uuidString)"
        let manifest = CodexGenerationManifest(
            schemaVersion: 1,
            projectID: store.currentProject.id,
            batchID: batchID,
            taskID: "codex-live-e2e",
            taskTitle: "AssetFrame Codex真实生图验收",
            generationPlatform: "Codex",
            modelName: ProcessInfo.processInfo.environment["ASSETFRAME_REAL_MODEL"] ?? "实际模型待标注",
            prompt: ProcessInfo.processInfo.environment["ASSETFRAME_REAL_PROMPT"]
                ?? "蓝色测试方块，纯白无缝背景。",
            promptHash: nil,
            operation: .create,
            parentBatchID: nil,
            parentAssetID: nil,
            parentFingerprint: nil,
            intendedType: .prop,
            entityName: "蓝色测试方块",
            variantName: "基础",
            createdAt: .now,
            candidates: [
                GenerationCandidateRecord(
                    id: candidateID,
                    relativePath: relativePath(candidateURL, root: projectRoot),
                    candidateIndex: 1,
                    iteration: 1,
                    preferredName: "蓝色测试方块｜基础｜E2E测试图",
                    assetType: .prop,
                    category: .temporary,
                    purpose: .propSingle,
                    tags: ["Codex真实生图", "E2E"],
                    sha256: contentHash,
                    generatedAt: .now
                )
            ]
        )
        try writeManifest(manifest, to: batchDirectory)
        await store.refreshCodexInbox(showToast: false)
        await waitUntil {
            store.pendingImports.contains {
                $0.generationProvenance?.candidateID == candidateID
            }
        }
        guard let pending = store.pendingImports.first(where: {
            $0.generationProvenance?.candidateID == candidateID
        }) else {
            preconditionFailure("真实生成图没有进入 Codex 候选区")
        }
        precondition((pending.pixelWidth ?? 0) > 0 && (pending.pixelHeight ?? 0) > 0)
        precondition(pending.generationProvenance?.contentSHA256 == contentHash)

        store.confirmPendingImports([pending.id])
        await waitUntil {
            !store.isImporting
                && store.assets.contains(where: {
                    $0.generationProvenance?.candidateID == candidateID
                })
        }
        guard let asset = store.assets.first(where: {
            $0.generationProvenance?.candidateID == candidateID
        }) else {
            preconditionFailure("真实生成图没有进入正式资产库")
        }
        precondition(fileManager.fileExists(atPath: candidateURL.path), "候选原图不得被移动")
        precondition(
            URL(fileURLWithPath: asset.imagePath).resolvingSymlinksInPath().path
                == candidateURL.resolvingSymlinksInPath().path,
            "正式资产必须原位引用候选图"
        )

        guard let variantID = store.createAssetVariant(
            assetIDs: [asset.id],
            entityID: nil,
            entityName: "蓝色测试方块",
            type: .prop,
            variantName: "基础",
            suggestedCoverID: asset.id
        ) else {
            preconditionFailure("无法建立真实生图形态")
        }
        store.setVariantDecision(variantID, assetID: asset.id, decision: .main)
        store.updateVariantMetadata(
            variantID,
            entityName: "蓝色测试方块",
            variantName: "基础",
            keyDifference: "蓝色方块，纯白无缝背景",
            doNotMix: "非蓝色或带复杂背景版本"
        )
        precondition(store.variantLockIssues(variantID).isEmpty)
        store.lockVariant(variantID)
        store.addVariantToExportLibrary(variantID)

        let exportRoot = supportRoot.appendingPathComponent("Exports", isDirectory: true)
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        store.exportLibrary(to: exportRoot)
        await waitUntil {
            store.exportProgress?.phase == .completed || store.exportProgress?.phase == .failed
        }
        precondition(store.exportProgress?.phase == .completed)
        guard let packagePath = store.exportProgress?.resultPath else {
            preconditionFailure("真实生成图没有形成导出包")
        }
        let packageURL = URL(fileURLWithPath: packagePath)
        precondition(
            fileManager.fileExists(atPath: packageURL.appendingPathComponent("资产调用总表.csv").path)
        )
        precondition(
            fileManager.fileExists(atPath: packageURL.appendingPathComponent("Hotdesk调用说明.md").path)
        )
        let exportedFiles = try fileManager.subpathsOfDirectory(atPath: packageURL.path)
        precondition(exportedFiles.contains { $0.contains("_MAIN.") })

        print(
            "CodexGenerationLiveE2E passed · "
                + "\(pending.pixelWidth ?? 0)×\(pending.pixelHeight ?? 0) · "
                + "\(contentHash.prefix(12)) · 临时项目已隔离"
        )
    }

    private static func writeManifest(_ manifest: CodexGenerationManifest, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent(CodexGenerationIntake.manifestFilename),
            options: .atomic
        )
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<800 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out waiting for real Codex image E2E")
    }
}
