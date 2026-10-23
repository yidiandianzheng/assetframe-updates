import Foundation

@main
struct FilenameAssetClassifierSelfTest {
    static func main() {
        assertClassification("人物_顾婉宁_S级_4K_v04.png", type: .person, category: .project, evidence: "人物")
        assertClassification("/项目/场景/室内/大厅_v02.jpg", type: .scene, category: .project, evidence: "场景")
        assertClassification("通用_固定视觉_logo_蓝色.png", type: .fixedSymbol, category: .common, evidence: "logo")
        assertClassification("发布封面_竖版_v03.png", type: .publishCover, category: .project, evidence: "发布封面")
        assertClassification("产品_茶叶包装_正面.png", type: .product, category: .project, evidence: "产品")
        assertClassification("道具_黑金花契_v01.png", type: .prop, category: .project, evidence: "道具")

        let unknown = FilenameAssetClassifier.classify(path: "IMG_9827.png")
        precondition(unknown.type == .unclassified)
        precondition(unknown.category == .pending)
        precondition(unknown.evidence.isEmpty)

        print("FilenameAssetClassifierSelfTest passed")
    }

    private static func assertClassification(
        _ path: String,
        type: AssetType,
        category: AssetCategory,
        evidence: String
    ) {
        let result = FilenameAssetClassifier.classify(path: path)
        precondition(result.type == type, "\(path) 应识别为 \(type.rawValue)")
        precondition(result.category == category)
        precondition(result.evidence.contains(evidence))
    }
}
