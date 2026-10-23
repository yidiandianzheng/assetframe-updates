import Foundation

@main
struct VisionAPILiveSmokeTest {
    static func main() async throws {
        let appDefaults = UserDefaults(suiteName: "com.yidiandian.assetframe") ?? .standard
        guard let configuration = VisionAPISettings.storedConfiguration(defaults: appDefaults) else {
            throw NSError(
                domain: "AssetFrame.VisionAPILiveSmokeTest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "软件尚未在 Keychain 保存完整视觉 API 配置"]
            )
        }
        try await OpenAICompatibleVisionClient().testConnection(configuration: configuration)
        print("视觉 API 真实看图测试通过")
        print("模型：\(configuration.model)")

        if let samplePath = ProcessInfo.processInfo.environment["ASSETFRAME_VISION_SAMPLE_PATH"],
           FileManager.default.fileExists(atPath: samplePath) {
            let sampleURL = URL(fileURLWithPath: samplePath)
            let suggestion = try await OpenAICompatibleVisionClient().analyze(
                input: VisionAnalysisInput(
                    itemID: "LIVE-SAMPLE",
                    imagePath: samplePath,
                    filename: sampleURL.lastPathComponent,
                    relativePath: sampleURL.lastPathComponent,
                    currentType: .unclassified,
                    localVisionLabels: []
                ),
                configuration: configuration
            )
            print("真实图片分类：\(suggestion.assetType.rawValue) · \(suggestion.proposedName)")
            print("标签：\(suggestion.normalizedTags.joined(separator: "、"))")
        }
    }
}
