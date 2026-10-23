import Foundation

@main
struct AssetPreviewSessionSelfTest {
    static func main() {
        var assets = (1...9).map { makeAsset(id: "A\($0)") }
        assets[7].isSourceMissing = true
        assets[8].deletedAt = .now

        let stack = AssetStack(
            id: "STACK-1",
            name: "顾婉宁 · 穿越后古代装",
            coverAssetID: "A2",
            memberAssetIDs: ["A4", "A2", "A8", "A1", "A9", "A3", "A6", "A5", "A7"],
            createdAt: .now,
            updatedAt: .now,
            candidateDecisions: [
                "A4": .reference,
                "A2": .reference,
                "A8": .unused,
                "A1": .main
            ]
        )

        guard let session = AssetPreviewSession.group(stack: stack, assets: assets, projectID: "PROJECT") else {
            preconditionFailure("有效组图应生成预览会话")
        }
        precondition(session.isGroup)
        precondition(session.projectID == "PROJECT")
        precondition(session.items.map(\.id) == ["A2", "A4", "A8", "A1", "A3", "A6", "A5", "A7"], "首选图必须排第一，其余候选保持 memberAssetIDs 相对顺序")
        precondition(session.preferredAssetID == "A2")
        precondition(session.initialIndex == 0, "组图必须从首选图打开")
        precondition(session.items.first(where: { $0.id == "A8" })?.asset.sourceMissing == true, "源文件缺失的位置不得被跳过")
        precondition(session.items.first(where: { $0.id == "A8" })?.statusText == "淘汰")
        precondition(session.items.first(where: { $0.id == "A3" })?.statusText == "待裁定")

        var coverOnly = stack
        coverOnly.candidateDecisions = [:]
        guard let coverSession = AssetPreviewSession.group(stack: coverOnly, assets: assets, projectID: "PROJECT") else {
            preconditionFailure("封面回退会话生成失败")
        }
        precondition(coverSession.items.first?.id == "A2" && coverSession.initialIndex == 0, "没有主图时仍应把首选图排第一")

        var missingCover = stack
        missingCover.coverAssetID = "A9"
        guard let fallbackSession = AssetPreviewSession.group(stack: missingCover, assets: assets, projectID: "PROJECT") else {
            preconditionFailure("失效首选图回退会话生成失败")
        }
        precondition(fallbackSession.preferredAssetID == "A1", "首选图已删除时应回退正式主图")
        precondition(fallbackSession.items.map(\.id) == ["A1", "A4", "A2", "A8", "A3", "A6", "A5", "A7"])

        let promoted = AssetPreviewSession.promotingPreferred("A6", in: session.items)
        precondition(promoted.map(\.id) == ["A6", "A2", "A4", "A8", "A1", "A3", "A5", "A7"], "右键重设后只能提升目标，不能打乱其余候选")

        let oneAssetStack = AssetStack(
            id: "STACK-ONE",
            name: "单张形态",
            coverAssetID: "A1",
            memberAssetIDs: ["A1"],
            createdAt: .now,
            updatedAt: .now
        )
        let oneAssetSession = AssetPreviewSession.group(stack: oneAssetStack, assets: assets, projectID: "PROJECT")
        precondition(oneAssetSession?.isGroup == true && oneAssetSession?.items.count == 1, "只有一张的形态仍应进入组图查看器")

        let single = AssetPreviewSession.single(asset: assets[0], projectID: "PROJECT")
        precondition(!single.isGroup && single.items.count == 1 && single.initialIndex == 0 && single.preferredAssetID == nil)

        print("AssetPreviewSessionSelfTest passed")
    }

    private static func makeAsset(id: String) -> AssetItem {
        var asset = PendingImportItem(
            id: id,
            stagedPath: "/tmp/\(id).png",
            originalSourcePath: "/tmp/\(id).png",
            originalFilename: "\(id).png",
            sourceFileID: "FILE-\(id)",
            sourceFileSize: 1,
            sourceModifiedAt: .now,
            pixelWidth: 4096,
            pixelHeight: 2304,
            suggestedType: .person,
            category: .project,
            createdAt: .now
        ).previewAsset
        asset.id = id
        asset.name = "照片 \(id)"
        asset.projectID = "PROJECT"
        return asset
    }
}
