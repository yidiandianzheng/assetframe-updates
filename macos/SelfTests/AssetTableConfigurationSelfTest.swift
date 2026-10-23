import Foundation

@main
struct AssetTableConfigurationSelfTest {
    static func main() {
        precondition(AssetTableViewPreset.all.fields.count == 13)
        precondition(AssetTableViewPreset.review.fields.contains(.decision))
        precondition(!AssetTableViewPreset.review.fields.contains(.episodes))
        precondition(AssetTableViewPreset.production.fields.contains(.qaResult))
        precondition(AssetTableViewPreset.quality.fields.contains(.sourceStatus))
        precondition(AssetTableViewPreset.review.defaultGroup == .decision)
        precondition(AssetTableViewPreset.production.defaultGroup == .type)

        let assets = [
            makeAsset(id: "A", type: .person, decision: .confirmed, reuse: .s, sourceMissing: false),
            makeAsset(id: "B", type: .prop, decision: .pending, reuse: .a, sourceMissing: false),
            makeAsset(id: "C", type: .prop, decision: .pending, reuse: .a, sourceMissing: true)
        ]

        let typeSections = AssetTableGroupOption.type.sections(from: assets)
        precondition(typeSections.count == 2)
        precondition(typeSections.first(where: { $0.title == AssetType.prop.rawValue })?.assets.count == 2)

        let sourceSections = AssetTableGroupOption.sourceStatus.sections(from: assets)
        precondition(sourceSections.count == 2)
        precondition(sourceSections.first(where: { $0.title == "源文件缺失" })?.assets.count == 1)

        let ungrouped = AssetTableGroupOption.none.sections(from: assets)
        precondition(ungrouped.count == 1 && ungrouped[0].assets.count == 3)

        print("AssetTableConfigurationSelfTest passed")
    }

    private static func makeAsset(
        id: String,
        type: AssetType,
        decision: UserDecision,
        reuse: ReuseGrade,
        sourceMissing: Bool
    ) -> AssetItem {
        var asset = PendingImportItem(
            id: id,
            stagedPath: "/tmp/\(id).png",
            originalSourcePath: "/tmp/\(id).png",
            originalFilename: "\(id).png",
            sourceFileID: id,
            sourceFileSize: 1,
            sourceModifiedAt: nil,
            pixelWidth: 1024,
            pixelHeight: 1024,
            suggestedType: type,
            category: .project,
            createdAt: .now
        ).previewAsset
        asset.id = id
        asset.type = type
        asset.decision = decision
        asset.reuse = reuse
        asset.isSourceMissing = sourceMissing
        return asset
    }
}
