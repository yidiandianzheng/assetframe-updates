import AppKit
import Foundation

@main
struct AssetDeliverySelfTest {
    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        var seedAssets: [AssetItem] = []
        for index in 1...8 {
            let url = sources.appendingPathComponent("candidate-\(index).png")
            try Data([0x89, 0x50, 0x4e, 0x47, UInt8(index), 0xaa, 0xbb]).write(to: url)
            var asset = PendingImportItem(
                id: "A\(index)", stagedPath: url.path, originalSourcePath: url.path,
                originalFilename: url.lastPathComponent, sourceFileID: "F\(index)", sourceFileSize: 7,
                sourceModifiedAt: Date(), pixelWidth: 2048, pixelHeight: 2048,
                suggestedType: .person, category: .project, createdAt: Date()
            ).previewAsset
            asset.id = "A\(index)"
            asset.type = .person
            asset.reuse = .s
            asset.episodes = ["第1集", "第2集"]
            seedAssets.append(asset)
        }
        let scriptCandidate = ScriptAssetCandidate(
            id: "SCRIPT-CANDIDATE-1", name: "桑枝", type: .person, reuse: .s,
            appearances: ["第1集第2场"], evidence: "桑枝进入镇北城", note: "",
            status: .pending, formName: "战损", isRequired: true
        )
        let scriptRecord = ScriptExtractionRecord(
            id: "SCRIPT-1", sourceName: "第001集.md", sourcePath: "/tmp/第001集.md",
            createdAt: .now, textFingerprint: "script", candidates: [scriptCandidate]
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let library = LibraryData(assets: seedAssets, groups: [], relations: [], scriptExtractions: [scriptRecord])
        try encoder.encode(library).write(to: root.appendingPathComponent("library.json"))

        let store = AssetStore(rootURL: root)
        await waitUntil { !store.isLoadingProject }
        store.attachDroppedSources(
            seedAssets.map { .libraryAsset(projectID: store.currentProject.id, assetID: $0.id) },
            extractionID: scriptRecord.id,
            candidateID: scriptCandidate.id
        )
        guard let draftedCandidate = store.scriptExtractions.first?.candidates.first,
              let variantID = draftedCandidate.draftVariantID,
              let draftedVariant = store.stack(withID: variantID) else { preconditionFailure("拖图形态组创建失败") }
        precondition(draftedVariant.coverAssetID == "A1", "第一张拖入图片必须是建议封面")
        precondition(draftedVariant.mainAssetID == nil, "建议封面不能越权成为正式主图")
        precondition(draftedVariant.pendingAssetIDs.count == 8)

        let originalMemberOrder = draftedVariant.memberAssetIDs
        precondition(store.setStackCover(variantID, assetID: "A5"), "组内候选应可重设首选图")
        guard let preferredVariant = store.stack(withID: variantID) else { preconditionFailure("重设首选图后形态丢失") }
        precondition(preferredVariant.coverAssetID == "A5")
        precondition(preferredVariant.mainAssetID == nil, "重设首选图不得越权成为正式主图")
        precondition(preferredVariant.memberAssetIDs == originalMemberOrder, "重设首选图不得改写候选持久化顺序")
        await store.flushCurrentProject()
        let preferredSnapshot = try await ProjectDatabase(url: URL(fileURLWithPath: store.currentProject.databasePath)).load()
        precondition(preferredSnapshot.library.assetStacks?.first(where: { $0.id == variantID })?.coverAssetID == "A5", "首选图必须持久化")

        store.addScriptCandidateForm(extractionID: scriptRecord.id, candidateID: scriptCandidate.id)
        guard let secondForm = store.scriptExtractions.first?.candidates.first(where: { $0.id != scriptCandidate.id }) else {
            preconditionFailure("新增形态失败")
        }
        precondition(secondForm.name == "桑枝" && secondForm.draftVariantID == nil && secondForm.linkedVariantID == nil)
        let ninthURL = sources.appendingPathComponent("candidate-9.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x09]).write(to: ninthURL)
        store.attachDroppedSources([.fileURL(ninthURL)], extractionID: scriptRecord.id, candidateID: secondForm.id)
        await waitUntil { !store.isImporting }
        guard let refreshedSecond = store.scriptExtractions.first?.candidates.first(where: { $0.id == secondForm.id }),
              let singleVariantID = refreshedSecond.draftVariantID,
              let singleVariant = store.stack(withID: singleVariantID) else { preconditionFailure("单张拖入候选形态失败") }
        precondition(singleVariant.count == 1 && singleVariant.coverAssetID == singleVariant.memberAssetIDs.first)
        precondition(singleVariant.mainAssetID == nil)

        let knownCandidateIDs = Set(store.scriptExtractions.first?.candidates.map(\.id) ?? [])
        store.addScriptCandidateForm(extractionID: scriptRecord.id, candidateID: scriptCandidate.id)
        guard let quickCandidate = store.scriptExtractions.first?.candidates.first(where: { !knownCandidateIDs.contains($0.id) }) else {
            preconditionFailure("快速采用测试形态创建失败")
        }
        let quickURL = sources.appendingPathComponent("candidate-10.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x0a]).write(to: quickURL)
        store.quickAdoptScriptSources(
            [.fileURL(quickURL)], extractionID: scriptRecord.id, candidateID: quickCandidate.id
        )
        await waitUntil { !store.isImporting }
        guard let quickLinked = store.scriptExtractions.first?.candidates.first(where: { $0.id == quickCandidate.id }),
              let quickVariantID = quickLinked.linkedVariantID,
              let quickVariant = store.stack(withID: quickVariantID) else {
            preconditionFailure("快速采用并绑定失败")
        }
        precondition(quickVariant.isLocked && quickVariant.mainAssetID != nil)
        precondition(quickLinked.effectiveLinkState == .linked)

        precondition(store.variantLockIssues(variantID).contains("必须选择 1 张主图"))
        store.setVariantDecision(variantID, assetID: "A1", decision: .main)
        store.setVariantDecision(variantID, assetID: "A2", decision: .reference)
        store.setVariantDecision(variantID, assetID: "A3", decision: .reference)
        store.setVariantDecision(variantID, assetID: "A4", decision: .reference)
        precondition(store.stack(withID: variantID)?.supplementAssetIDs.count == 2, "第三张补图必须被拒绝")
        store.updateVariantMetadata(
            variantID, entityName: "桑枝", variantName: "战损",
            keyDifference: "左肩衣袍破损，额角持续伤痕", doNotMix: "基础白衣无伤版"
        )
        precondition(store.variantLockIssues(variantID).isEmpty)
        store.lockVariant(variantID)
        guard let locked = store.stack(withID: variantID) else { preconditionFailure("锁定后形态丢失") }
        precondition(locked.isLocked && locked.mainAssetID == "A1")
        precondition(locked.supplementAssetIDs == ["A2", "A3"])
        precondition(locked.unusedAssetIDs.count == 5)
        precondition(locked.effectiveCallCode.hasPrefix("R001-F01_桑枝_战损"))
        let linkedCandidate = store.scriptExtractions.first?.candidates.first(where: { $0.id == scriptCandidate.id })
        precondition(linkedCandidate?.linkedVariantID == variantID && linkedCandidate?.effectiveLinkState == .linked)

        store.addVariantToExportLibrary(variantID)
        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        try fileManager.createDirectory(at: exports, withIntermediateDirectories: true)
        store.exportLibrary(to: exports)
        await waitUntil { store.exportProgress?.phase == .completed || store.exportProgress?.phase == .failed }
        precondition(store.exportProgress?.phase == .completed)
        let packageURL = URL(fileURLWithPath: store.exportProgress!.resultPath!)
        precondition(packageURL.lastPathComponent.hasSuffix("_v001"))
        let shapeFolder = packageURL.appendingPathComponent("人物资产/\(locked.effectiveCallCode)", isDirectory: true)
        let delivered = try fileManager.contentsOfDirectory(at: shapeFolder, includingPropertiesForKeys: nil)
        precondition(delivered.count == 3, "交付包只能包含一张主图与两张补图")
        precondition(delivered.contains { $0.lastPathComponent.contains("_MAIN.") })
        precondition(!delivered.contains { $0.lastPathComponent.contains("candidate-4") })
        let mainDelivered = delivered.first { $0.lastPathComponent.contains("_MAIN.") }!
        let deliveredData = try Data(contentsOf: mainDelivered)
        let sourceData = try Data(contentsOf: sources.appendingPathComponent("candidate-1.png"))
        precondition(deliveredData == sourceData)
        let manifestURL = packageURL.appendingPathComponent("资产调用总表.csv")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        precondition(manifest.contains("项目,调用编号,资产类型,资产名称,形态名称"))
        precondition(manifest.contains("Hotdesk调用说明") && manifest.contains("不得混用"))
        precondition(fileManager.fileExists(atPath: packageURL.appendingPathComponent("Hotdesk调用说明.md").path))

        var matrix = CSVDocument.parse(manifest)
        let keyIndex = matrix[0].firstIndex(of: "形态关键区别")!
        matrix[1][keyIndex] = "左肩破损清晰，额角伤痕必须保留"
        let editableCSV = matrix.map { $0.map(csvEscape).joined(separator: ",") }.joined(separator: "\n")
        let editableURL = root.appendingPathComponent("飞书回导.csv")
        try editableCSV.write(to: editableURL, atomically: true, encoding: .utf8)
        store.previewFeishuCSV(at: editableURL)
        await waitUntil { store.feishuImportPreview != nil }
        precondition(store.feishuImportPreview?.errors.isEmpty == true)
        precondition(store.feishuImportPreview?.changes.contains(where: { $0.field == "形态关键区别" }) == true)
        store.applyFeishuImport()
        precondition(store.stack(withID: variantID)?.keyDifference == "左肩破损清晰，额角伤痕必须保留")
        precondition(store.stack(withID: variantID)?.requiresExport == true)

        var protectedMatrix = CSVDocument.parse(manifest)
        let mainIndex = protectedMatrix[0].firstIndex(of: "主图文件名")!
        protectedMatrix[1][mainIndex] = "tampered.png"
        let protectedCSV = protectedMatrix.map { $0.map(csvEscape).joined(separator: ",") }.joined(separator: "\n")
        let protectedURL = root.appendingPathComponent("非法回导.csv")
        try protectedCSV.write(to: protectedURL, atomically: true, encoding: .utf8)
        store.previewFeishuCSV(at: protectedURL)
        await waitUntil { store.feishuImportPreview?.sourceURL == protectedURL }
        precondition(store.feishuImportPreview?.errors.contains(where: { $0.contains("受保护字段") }) == true)
        store.cancelFeishuImport()

        store.setVariantDecision(variantID, assetID: "A4", decision: .main)
        let revised = store.stack(withID: variantID)!
        precondition(revised.mainAssetID == "A4" && revised.versionNumber == 2)
        precondition(revised.effectiveCallCode == locked.effectiveCallCode, "更换主图不能改变调用编号")
        store.exportLibrary(to: exports)
        await waitUntil { store.exportProgress?.deliveryVersion == "v002" && (store.exportProgress?.phase == .completed || store.exportProgress?.phase == .failed) }
        precondition(store.exportProgress?.phase == .completed)
        precondition(fileManager.fileExists(atPath: packageURL.path), "新导出不得覆盖旧交付包")

        await store.flushCurrentProject()
        let snapshot = try await ProjectDatabase(url: URL(fileURLWithPath: store.currentProject.databasePath)).load()
        precondition(snapshot.library.assetEntities?.count == 1)
        precondition(snapshot.library.assetStacks?.first(where: { $0.id == variantID })?.mainAssetID == "A4")
        precondition(snapshot.library.scriptExtractions?.first?.candidates.count == 3)
        precondition(snapshot.exportVariantIDs.contains(variantID))

        let csvURL = root.appendingPathComponent("write-check.csv")
        try AssetStore.writeCSV("调用编号,资产名称\nR001,桑枝", to: csvURL)
        let writtenCSV = try String(contentsOf: csvURL, encoding: .utf8)
        precondition(writtenCSV.contains("R001,桑枝"))
        do {
            try AssetStore.writeCSV("不可写入目录", to: root)
            preconditionFailure("CSV写入失败时不得误报成功")
        } catch {
            // 目录不是文件；抛错即证明 UI 可以进入失败提示分支。
        }
        print("AssetDeliverySelfTest passed")
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<800 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out")
    }

    private static func csvEscape(_ value: String) -> String {
        value.contains(",") || value.contains("\n") || value.contains("\"")
            ? "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
            : value
    }
}
