import Foundation

@main
struct ProjectImageIndexSelfTest {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("人物资产/顾婉宁", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let imageURL = root.appendingPathComponent("人物资产/顾婉宁/顾婉宁_基础.png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZQmcAAAAASUVORK5CYII=")!
        try png.write(to: imageURL)
        let records = ProjectImageIndexer.scan(root: root, existing: [])
        precondition(records.count == 1)
        precondition(records[0].inferredType == .person)
        precondition(records[0].relativePath.contains("顾婉宁"))

        let database = ProjectDatabase(url: root.appendingPathComponent("project.sqlite"))
        try await database.replaceProjectImageIndex(records)
        let restored = try await database.loadProjectImageIndex()
        precondition(restored.count == records.count)
        precondition(restored[0].id == records[0].id)
        precondition(restored[0].path == records[0].path)
        precondition(restored[0].inferredType == records[0].inferredType)

        let candidate = ScriptAssetCandidate(
            id: "C1", name: "顾婉宁", type: .person, reuse: .s,
            appearances: ["第1集"], evidence: "基础白衣形态", note: "主角",
            status: .pending, formName: "基础", isRequired: true
        )
        let matches = ScriptAssetMatcher.matches(
            candidate: candidate, scope: .project, search: "顾婉宁",
            projectID: "P1", projectName: "测试", assets: [], variants: [], entities: [],
            projectImages: records
        )
        precondition(matches.count == 1)
        precondition(matches[0].source.sourceLabel == "项目原图")
        precondition(matches[0].reasons.contains("名称匹配"))

        let preview = records[0].previewAsset(projectID: "P1", projectName: "测试")
        let syntheticMatches = [
            ScriptAssetMatch(
                id: "HIGH-SCORE", source: .projectFile(recordID: "R1", path: "/tmp/其他人.png"),
                title: "其他人高相似图", subtitle: "本机识图", pathText: "其他人.png",
                type: .person, score: 99, reasons: ["类型一致", "外观高度相似"], previewAsset: preview
            ),
            ScriptAssetMatch(
                id: "NAME", source: .projectFile(recordID: "R2", path: "/tmp/顾婉宁.png"),
                title: "顾婉宁", subtitle: "项目原图", pathText: "顾婉宁.png",
                type: .person, score: 80, reasons: ["类型一致", "名称匹配"], previewAsset: preview
            ),
            ScriptAssetMatch(
                id: "NAME-FORM", source: .projectFile(recordID: "R3", path: "/tmp/顾婉宁_穿越前_现代装.png"),
                title: "顾婉宁_穿越前_现代装", subtitle: "项目原图", pathText: "顾婉宁_穿越前_现代装.png",
                type: .person, score: 75, reasons: ["类型一致", "名称匹配", "形态匹配"], previewAsset: preview
            )
        ]
        precondition(ScriptAssetMatcher.sorted(syntheticMatches, mode: .balanced).map(\.id) == ["HIGH-SCORE", "NAME", "NAME-FORM"])
        precondition(ScriptAssetMatcher.sorted(syntheticMatches, mode: .nameFirst).map(\.id) == ["NAME-FORM", "NAME", "HIGH-SCORE"])

        print("ProjectImageIndexSelfTest passed")
    }
}
