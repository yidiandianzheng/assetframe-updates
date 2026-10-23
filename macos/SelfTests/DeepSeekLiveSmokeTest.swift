import Foundation

@main
struct DeepSeekLiveSmokeTest {
    static func main() async throws {
        guard ProcessInfo.processInfo.environment["ASSETFRAME_RUN_LIVE_DEEPSEEK"] == "1" else {
            print("未设置 ASSETFRAME_RUN_LIVE_DEEPSEEK=1，跳过真实API冒烟测试")
            return
        }
        guard let fastConfiguration = DeepSeekAPISettings.storedConfiguration(for: .pendingImport),
              let deepConfiguration = DeepSeekAPISettings.storedConfiguration(for: .scriptExtraction) else {
            throw NSError(
                domain: "AssetFrame.DeepSeekLiveSmokeTest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "软件尚未在 Keychain 保存完整 DeepSeek 配置"]
            )
        }

        let projectRoot = URL(fileURLWithPath: "/tmp/AssetFrameSyntheticProject")
        let item = PendingImportItem(
            id: "SYNTHETIC-IMPORT",
            stagedPath: "/tmp/AssetFrameSyntheticProject/00_向量时刻待导入/桑枝基础造型.png",
            originalSourcePath: "/tmp/AssetFrameSyntheticProject/人物/桑枝基础造型.png",
            originalFilename: "桑枝基础造型.png",
            sourceFileID: "synthetic",
            sourceFileSize: 128,
            sourceModifiedAt: nil,
            pixelWidth: 4096,
            pixelHeight: 4096,
            suggestedType: .person,
            category: .project,
            createdAt: .now
        )
        let importSuggestions = try await DeepSeekAIClient.analyze(
            items: [item],
            projectRoot: projectRoot,
            configuration: fastConfiguration
        )
        precondition(importSuggestions.contains { $0.itemID == item.id })

        let script = """
        第1集第1场，现代出租屋。林砚穿粉色长袖睡衣，湿发披散。
        第1集第2场，林砚穿越到古代矿营，此后长期穿深灰粗布工衣；她与现代状态保持同一张脸。
        第1集第3场，阿禾刚被流放时右腕没有手镯，怀抱旧包袱。
        第8集第2场，阿禾后期长期佩戴黑铁罪籍手镯，在矿营共同劳作。
        """
        let scriptCandidates = try await ScriptAssetExtractionClient.extract(
            text: script,
            sourceName: "虚构测试剧本.md",
            configuration: deepConfiguration
        ) { _, _ in }
        precondition(!scriptCandidates.isEmpty)
        let linForms = Set(scriptCandidates.filter { $0.name == "林砚" }.map(\.effectiveFormName))
        let aheForms = Set(scriptCandidates.filter { $0.name == "阿禾" }.map(\.effectiveFormName))
        precondition(linForms.count == 2, "穿越前后必须拆成两个稳定形态")
        precondition(aheForms.count == 2, "持续佩戴标志变化必须拆成两个稳定形态")

        print("DeepSeek真实API冒烟测试通过")
        print("快速模型：\(fastConfiguration.model)；返回\(importSuggestions.count)项整理建议")
        print("深度模型：\(deepConfiguration.model)；林砚形态：\(linForms.sorted())；阿禾形态：\(aheForms.sorted())")
    }
}
