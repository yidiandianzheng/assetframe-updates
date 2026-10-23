import AppKit
import Foundation

@main
struct CodexGenerationIntakeSelfTest {
    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default
        let supportRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: supportRoot) }

        let store = AssetStore(rootURL: supportRoot)
        await waitUntil { !store.isLoadingProject }
        let project = store.currentProject
        let projectRoot = store.currentProjectRootURL
        let inbox = projectRoot.appendingPathComponent(
            CodexGenerationIntake.inboxDirectoryName,
            isDirectory: true
        )
        await waitUntil {
            fileManager.fileExists(
                atPath: inbox.appendingPathComponent(CodexGenerationIntake.contextFilename).path
            )
            && fileManager.fileExists(
                atPath: supportRoot.appendingPathComponent(CodexGenerationIntake.globalContextFilename).path
            )
        }
        precondition(
            fileManager.fileExists(
                atPath: supportRoot.appendingPathComponent(
                    CodexGenerationIntake.globalContextFilename
                ).path
            ),
            "当前项目上下文必须同时写到固定的 Application Support 入口"
        )

        let firstBatchDirectory = inbox
            .appendingPathComponent("2026-07-30/角色资产/G260730-143512", isDirectory: true)
        try fileManager.createDirectory(at: firstBatchDirectory, withIntermediateDirectories: true)
        let firstFilename = "人物_桑枝_基础_G260730-143512_R01_C01.png"
        let secondFilename = "人物_桑枝_基础_G260730-143512_R01_C02.png"
        let firstURL = firstBatchDirectory.appendingPathComponent(firstFilename)
        let secondURL = firstBatchDirectory.appendingPathComponent(secondFilename)
        try writePNG(to: firstURL, color: .systemRed)
        try writePNG(to: secondURL, color: .systemBlue)
        let firstHash = CodexGenerationIntake.fileSHA256(at: firstURL)
        let secondHash = CodexGenerationIntake.fileSHA256(at: secondURL)
        precondition(firstHash != nil && secondHash != nil && firstHash != secondHash)

        let firstBatchID = "G260730-143512"
        let firstManifest = CodexGenerationManifest(
            schemaVersion: 1,
            projectID: project.id,
            batchID: firstBatchID,
            taskID: "codex-task-001",
            taskTitle: "桑枝基础角色卡",
            generationPlatform: "Codex",
            modelName: "gpt-image-test",
            prompt: "成年女性角色桑枝，基础角色设定图，纯白无缝背景。",
            promptHash: nil,
            operation: .create,
            parentBatchID: nil,
            parentAssetID: nil,
            parentFingerprint: nil,
            intendedType: .person,
            entityName: "桑枝",
            variantName: "基础",
            createdAt: .now,
            candidates: [
                GenerationCandidateRecord(
                    id: "CODEX-CANDIDATE-001",
                    relativePath: relativePath(firstURL, root: projectRoot),
                    candidateIndex: 1,
                    iteration: 1,
                    preferredName: "桑枝｜基础｜角色设定图",
                    assetType: .person,
                    category: .project,
                    purpose: .multiAngle,
                    tags: ["成年女性", "角色卡", "成年女性"],
                    sha256: firstHash,
                    generatedAt: .now
                ),
                GenerationCandidateRecord(
                    id: "CODEX-CANDIDATE-002",
                    relativePath: relativePath(secondURL, root: projectRoot),
                    candidateIndex: 2,
                    iteration: 1,
                    preferredName: "桑枝｜基础｜角色设定图",
                    assetType: .person,
                    category: .project,
                    purpose: .multiAngle,
                    tags: ["角色卡"],
                    sha256: secondHash,
                    generatedAt: .now
                )
            ]
        )
        try writeManifest(firstManifest, to: firstBatchDirectory)
        await store.refreshCodexInbox(showToast: false)
        await waitUntil {
            store.pendingImports.count(where: { $0.generationProvenance?.batchID == firstBatchID }) == 2
        }

        let firstItems = store.pendingImports.filter {
            $0.generationProvenance?.batchID == firstBatchID
        }
        precondition(firstItems.map(\.generationProvenance?.candidateIndex) == [1, 2])
        precondition(firstItems.allSatisfy { $0.stagedPath == $0.originalSourcePath })
        precondition(firstItems[0].name == "桑枝｜基础｜角色设定图")
        precondition(firstItems[0].suggestedType == .person)
        precondition(firstItems[0].suggestedPurpose == .multiAngle)
        precondition(firstItems[0].normalizedManualTags == ["成年女性", "角色卡"])
        precondition(store.generationBatches.first(where: { $0.id == firstBatchID })?.prompt == firstManifest.prompt)

        let firstItemID = firstItems[0].id
        store.updatePendingImport(firstItemID, preferredName: "桑枝｜基础｜四宫格母版")
        var renamedManifest = firstManifest
        renamedManifest.candidates[0].preferredName = "后台不得覆盖人工名称"
        try writeManifest(renamedManifest, to: firstBatchDirectory)
        await store.refreshCodexInbox(showToast: false)
        precondition(
            store.pendingImport(withID: firstItemID)?.name == "桑枝｜基础｜四宫格母版",
            "manifest 重扫不得覆盖人工名称"
        )

        store.confirmPendingImports([firstItemID])
        await waitUntil {
            !store.isImporting
                && store.pendingImport(withID: firstItemID) == nil
                && store.assets.contains(where: { $0.generationProvenance?.candidateID == firstItemID })
        }
        guard let imported = store.assets.first(where: {
            $0.generationProvenance?.candidateID == firstItemID
        }) else {
            preconditionFailure("Codex 候选必须能确认进入正式资产库")
        }
        precondition(imported.name == "桑枝｜基础｜四宫格母版")
        precondition(imported.generationPlatform == "Codex")
        precondition(imported.promptSource.contains(firstBatchID))
        precondition(imported.purpose == .multiAngle)
        precondition(imported.generationProvenance?.contentSHA256 == firstHash)
        precondition(fileManager.fileExists(atPath: firstURL.path), "正式入库不得移动 Codex 原始候选")
        precondition(imported.importSourcePath == nil, "正式资产不得保留第二个展示路径")
        precondition(
            URL(fileURLWithPath: imported.imagePath).resolvingSymlinksInPath().path
                == firstURL.resolvingSymlinksInPath().path,
            "确认后必须原位引用 Codex 候选"
        )

        let secondBatchDirectory = inbox
            .appendingPathComponent("2026-07-30/角色资产/G260730-150000", isDirectory: true)
        try fileManager.createDirectory(at: secondBatchDirectory, withIntermediateDirectories: true)
        let editedURL = secondBatchDirectory
            .appendingPathComponent("人物_桑枝_战损_G260730-150000_R02_C01.png")
        let duplicateEditURL = secondBatchDirectory
            .appendingPathComponent("人物_桑枝_战损_G260730-150000_R02_C02.png")
        try writePNG(to: editedURL, color: .systemGreen)
        try fileManager.copyItem(at: editedURL, to: duplicateEditURL)
        let editedHash = CodexGenerationIntake.fileSHA256(at: editedURL)
        let secondBatchID = "G260730-150000"
        let secondManifest = CodexGenerationManifest(
            schemaVersion: 1,
            projectID: project.id,
            batchID: secondBatchID,
            taskID: "codex-task-001",
            taskTitle: "桑枝战损改图",
            generationPlatform: "Codex",
            modelName: "gpt-image-test",
            prompt: "保持桑枝身份和构图，只增加可控战损。",
            promptHash: nil,
            operation: .edit,
            parentBatchID: firstBatchID,
            parentAssetID: imported.id,
            parentFingerprint: firstHash,
            intendedType: .person,
            entityName: "桑枝",
            variantName: "战损",
            createdAt: .now,
            candidates: [
                GenerationCandidateRecord(
                    id: "CODEX-CANDIDATE-003",
                    relativePath: relativePath(editedURL, root: projectRoot),
                    candidateIndex: 1,
                    iteration: 2,
                    preferredName: nil,
                    assetType: nil,
                    category: nil,
                    purpose: nil,
                    tags: ["战损"],
                    sha256: editedHash,
                    generatedAt: nil
                ),
                GenerationCandidateRecord(
                    id: "CODEX-CANDIDATE-004",
                    relativePath: relativePath(duplicateEditURL, root: projectRoot),
                    candidateIndex: 2,
                    iteration: 2,
                    preferredName: nil,
                    assetType: nil,
                    category: nil,
                    purpose: nil,
                    tags: ["战损"],
                    sha256: editedHash,
                    generatedAt: nil
                )
            ]
        )
        try writeManifest(secondManifest, to: secondBatchDirectory)
        let directScan = CodexGenerationIntake.scan(
            project: project,
            projectRoot: projectRoot,
            existingPending: store.pendingImports,
            existingAssets: store.assets
        )
        precondition(directScan.pendingItems.count == 1)
        precondition(directScan.duplicateCount == 1, "相同内容改名后必须按 SHA-256 去重")
        await store.refreshCodexInbox(showToast: false)
        await waitUntil {
            store.pendingImports.contains {
                $0.generationProvenance?.batchID == secondBatchID
            }
        }
        guard let edited = store.pendingImports.first(where: {
            $0.generationProvenance?.batchID == secondBatchID
        }) else {
            preconditionFailure("改图批次应进入待导入")
        }
        precondition(edited.name == "桑枝｜战损")
        precondition(edited.generationProvenance?.operation == .edit)
        precondition(edited.generationProvenance?.parentBatchID == firstBatchID)
        precondition(edited.generationProvenance?.parentAssetID == imported.id)
        precondition(edited.generationProvenance?.parentFingerprint == firstHash)

        let duplicateBatchDirectory = inbox
            .appendingPathComponent("2026-07-30/角色资产/G260730-160000", isDirectory: true)
        try fileManager.createDirectory(at: duplicateBatchDirectory, withIntermediateDirectories: true)
        let duplicateSourceURL = duplicateBatchDirectory
            .appendingPathComponent("人物_桑枝_基础_G260730-160000_R03_C01.png")
        try fileManager.copyItem(at: firstURL, to: duplicateSourceURL)
        let duplicateManifest = CodexGenerationManifest(
            schemaVersion: 1,
            projectID: project.id,
            batchID: "G260730-160000",
            taskID: "codex-task-001",
            taskTitle: "桑枝重复生成",
            generationPlatform: "Codex",
            modelName: "gpt-image-test",
            prompt: "重复内容",
            promptHash: nil,
            operation: .regenerate,
            parentBatchID: firstBatchID,
            parentAssetID: imported.id,
            parentFingerprint: firstHash,
            intendedType: .person,
            entityName: "桑枝",
            variantName: "基础",
            createdAt: .now,
            candidates: [
                GenerationCandidateRecord(
                    id: "CODEX-CANDIDATE-005",
                    relativePath: relativePath(duplicateSourceURL, root: projectRoot),
                    candidateIndex: 1,
                    iteration: 3,
                    preferredName: nil,
                    assetType: nil,
                    category: nil,
                    purpose: nil,
                    tags: nil,
                    sha256: firstHash,
                    generatedAt: nil
                )
            ]
        )
        try writeManifest(duplicateManifest, to: duplicateBatchDirectory)
        let countBeforeDuplicateRefresh = store.pendingImports.count
        await store.refreshCodexInbox(showToast: false)
        precondition(
            store.pendingImports.count == countBeforeDuplicateRefresh,
            "正式资产中的相同内容不得再次进入待导入"
        )

        var wrongProjectManifest = duplicateManifest
        wrongProjectManifest.batchID = "G260730-WRONG"
        wrongProjectManifest.projectID = "other-project"
        try writeManifest(
            wrongProjectManifest,
            to: duplicateBatchDirectory,
            filename: ".assetframe-generation-wrong.json"
        )
        let wrongProjectScan = CodexGenerationIntake.scan(
            project: ProjectRecord(
                id: "other-project",
                name: "其他项目",
                rootPath: projectRoot.path,
                bookmarkData: nil,
                databasePath: project.databasePath,
                isLegacy: false,
                lastOpenedAt: .now
            ),
            projectRoot: projectRoot,
            existingPending: [],
            existingAssets: []
        )
        precondition(wrongProjectScan.pendingItems.isEmpty, "项目 ID 不匹配时不得跨项目接收")

        await store.flushCurrentProject()
        let reloaded = AssetStore(rootURL: supportRoot)
        await waitUntil {
            !reloaded.isLoadingProject
                && reloaded.assets.contains(where: { $0.generationProvenance?.candidateID == firstItemID })
        }
        precondition(reloaded.generationBatches.contains { $0.id == firstBatchID })
        precondition(
            reloaded.assets.first(where: {
                $0.generationProvenance?.candidateID == firstItemID
            })?.generationProvenance?.contentSHA256 == firstHash
        )

        print("CodexGenerationIntakeSelfTest passed")
    }

    private static func writeManifest(
        _ manifest: CodexGenerationManifest,
        to directory: URL,
        filename: String = CodexGenerationIntake.manifestFilename
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent(filename),
            options: .atomic
        )
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private static func writePNG(to url: URL, color: NSColor) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 320,
            pixelsHigh: 480,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "CodexGenerationIntakeSelfTest", code: 1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 480).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CodexGenerationIntakeSelfTest", code: 2)
        }
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out waiting for Codex generation intake")
    }
}
