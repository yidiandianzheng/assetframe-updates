import Foundation

@main
struct DeepSeekAIClientSelfTest {
    static func main() throws {
        let content = """
        {"items":[
          {"id":"A","proposedName":"青绿微灵下品灵石","assetType":"道具","styleTags":["仙侠","仙侠",""],"summary":"根据文件名建议为道具资产","confidence":1.4},
          {"id":"B","proposedName":"无效","assetType":"不存在类型","styleTags":[],"summary":"","confidence":0.5},
          {"id":"C","proposedName":"越界id","assetType":"人物","styleTags":[],"summary":"","confidence":0.5}
        ]}
        """
        let suggestions = try DeepSeekAIClient.decodeSuggestions(content: content, allowedIDs: ["A", "B"])
        precondition(suggestions.count == 1)
        precondition(suggestions[0].itemID == "A")
        precondition(suggestions[0].assetType == .prop)
        precondition(suggestions[0].styleTags == ["仙侠"])
        precondition(suggestions[0].confidence == 1)

        let external = PendingImportItem(
            id: "EXTERNAL", stagedPath: "/tmp/staged.png",
            originalSourcePath: "/Users/private/客户甲/未公开角色.png",
            originalFilename: "未公开角色.png", sourceFileID: "external", sourceFileSize: 8,
            sourceModifiedAt: nil, pixelWidth: 2048, pixelHeight: 2048,
            suggestedType: .person, category: .project, createdAt: .now
        )
        let internalItem = PendingImportItem(
            id: "INTERNAL", stagedPath: "/tmp/staged-2.png",
            originalSourcePath: "/tmp/AssetProject/人物/桑枝.png",
            originalFilename: "桑枝.png", sourceFileID: "internal", sourceFileSize: 8,
            sourceModifiedAt: nil, pixelWidth: 4096, pixelHeight: 4096,
            suggestedType: .person, category: .project, createdAt: .now
        )
        let payload = try DeepSeekAIClient.requestPayload(
            items: [external, internalItem],
            projectRoot: URL(fileURLWithPath: "/tmp/AssetProject")
        )
        precondition(!payload.contains("/Users/private"), "外部绝对路径不得进入AI请求")
        precondition(!payload.contains("/tmp/AssetProject"), "项目根绝对路径不得进入AI请求")
        precondition(!payload.contains("staged.png"), "待导入副本路径不得进入AI请求")
        let payloadData = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: Any]]
        let internalPayload = payloadData?.first { $0["id"] as? String == "INTERNAL" }
        let externalPayload = payloadData?.first { $0["id"] as? String == "EXTERNAL" }
        precondition(internalPayload?["relativePath"] as? String == "人物/桑枝.png", "项目内路径应缩成相对路径")
        precondition(externalPayload?["relativePath"] == nil, "项目外路径提示应为空")

        precondition(DeepSeekEndpointPolicy.accepts(baseURL: "https://api.deepseek.com"))
        precondition(
            DeepSeekEndpointPolicy.chatCompletionsURL(from: "https://api.deepseek.com")?.absoluteString ==
                "https://api.deepseek.com/chat/completions"
        )
        precondition(
            DeepSeekEndpointPolicy.chatCompletionsURL(from: "https://relay.example.com/v1")?.absoluteString ==
                "https://relay.example.com/v1/chat/completions"
        )
        precondition(DeepSeekEndpointPolicy.accepts(baseURL: "http://127.0.0.1:11434/v1"))
        precondition(DeepSeekEndpointPolicy.accepts(baseURL: "http://localhost:11434/v1"))
        precondition(!DeepSeekEndpointPolicy.accepts(baseURL: "http://api.deepseek.com"), "外部API不得明文发送密钥")
        precondition(!DeepSeekEndpointPolicy.accepts(baseURL: "https://user:password@relay.example.com"))
        precondition(!DeepSeekEndpointPolicy.accepts(baseURL: "https://relay.example.com/v1?key=secret"))
        print("DeepSeek AI JSON 解析自测通过")
    }
}
