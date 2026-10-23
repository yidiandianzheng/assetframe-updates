import Foundation

@main
struct ScriptAssetChecklistSelfTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mainURL = root.appendingPathComponent("sangzhi.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: mainURL)
        var main = PendingImportItem(
            id: "MAIN-1", stagedPath: mainURL.path, originalSourcePath: mainURL.path,
            originalFilename: mainURL.lastPathComponent, sourceFileID: "main", sourceFileSize: 4,
            sourceModifiedAt: .now, pixelWidth: 2048, pixelHeight: 2048,
            suggestedType: .person, category: .project, createdAt: .now
        ).previewAsset
        main.id = "MAIN-1"
        main.name = "桑枝基础主图"

        let entity = AssetEntityRecord(
            id: "ENTITY-1", code: "R001", name: "桑枝", type: .person,
            createdAt: .now, updatedAt: .now
        )
        let variant = AssetVariantRecord(
            id: "VARIANT-1", name: "桑枝 · 基础", coverAssetID: main.id,
            memberAssetIDs: [main.id], createdAt: .now, updatedAt: .now,
            entityID: entity.id, callCode: "R001-F01_桑枝_基础", variantName: "基础",
            candidateDecisions: [main.id: .main], keyDifference: "白衣基础形态",
            doNotMix: "战损形态", lockedAt: .now, assetVersion: 1
        )
        let linked = ScriptAssetCandidate(
            id: "C1", name: "桑枝", type: .person, reuse: .s,
            appearances: ["第1集第2场", "镜头3"], evidence: "桑枝进入镇北城", note: "主角",
            status: .confirmed, formName: "基础", isRequired: true,
            linkedVariantID: variant.id, linkState: .linked, reviewedAt: .now
        )
        let missing = ScriptAssetCandidate(
            id: "C2", name: "镇北城", type: .scene, reuse: .a,
            appearances: ["第1集第2场"], evidence: "荒废镇北城全景", note: "需要制作夜景",
            status: .confirmed, formName: "夜景", isRequired: true,
            linkedVariantID: nil, linkState: .missing, reviewedAt: .now
        )
        let excluded = ScriptAssetCandidate(
            id: "C3", name: "茶杯", type: .prop, reuse: .c,
            appearances: ["第1集第2场"], evidence: "桌上茶杯", note: "一次性小道具",
            status: .ignored, formName: "标准", isRequired: false
        )
        let record = ScriptExtractionRecord(
            id: "SCRIPT-1", sourceName: "第001集_分镜.md", sourcePath: "/tmp/第001集_分镜.md",
            createdAt: .now, textFingerprint: "abc", candidates: [linked, missing, excluded]
        )
        let project = ProjectRecord(
            id: "PROJECT-1", name: "流放镇北", rootPath: root.path, bookmarkData: nil,
            databasePath: root.appendingPathComponent("project.sqlite").path,
            isLegacy: false, lastOpenedAt: .now
        )
        let csv = AssetStore.scriptAssetChecklistCSV(
            record: record, variants: [variant], entities: [entity], assets: [main], project: project
        )
        precondition(csv.contains("项目,来源文件,需要使用,资产类型,剧本资产名称,剧本形态"))
        precondition(csv.contains("R001-F01_桑枝_基础"))
        precondition(csv.contains("_v01_MAIN.png"))
        precondition(csv.contains("镇北城") && csv.contains("待补图"))
        precondition(!csv.contains("茶杯"), "未勾选的普通小道具不得进入确认表")
        precondition(AssetStore.scriptAssetType(.person, matches: .creature))
        precondition(AssetStore.scriptAssetType(.scene, matches: .venue))
        precondition(!AssetStore.scriptAssetType(.person, matches: .prop))

        let legacyJSON = #"{"id":"OLD","name":"旧角色","type":"人物","reuse":"A","appearances":["第1集"],"evidence":"原文","note":"","status":"待确认"}"#
        let legacy = try JSONDecoder().decode(ScriptAssetCandidate.self, from: Data(legacyJSON.utf8))
        precondition(legacy.isRequiredForProduction)
        precondition(legacy.effectiveFormName == "基础")
        precondition(legacy.effectiveLinkState == .pending)
        precondition(legacy.draftVariantID == nil)

        print("ScriptAssetChecklistSelfTest passed")
    }
}
