import Foundation

@main
struct GlobalFiveStarStoreSelfTest {
    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("assetframe-global-five-star-\(UUID().uuidString)", isDirectory: true)
        let firstRoot = root.appendingPathComponent("项目甲", isDirectory: true)
        let secondRoot = root.appendingPathComponent("项目乙", isDirectory: true)
        let thirdRoot = root.appendingPathComponent("项目丙", isDirectory: true)
        try fileManager.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thirdRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let firstDatabase = root.appendingPathComponent("Projects/first/project.sqlite")
        let secondDatabase = root.appendingPathComponent("Projects/second/project.sqlite")
        let thirdDatabase = root.appendingPathComponent("Projects/third/project.sqlite")
        let firstProject = project(id: "first", name: "项目甲", root: firstRoot, database: firstDatabase)
        let secondProject = project(id: "second", name: "项目乙", root: secondRoot, database: secondDatabase)
        let thirdProject = project(id: "third", name: "项目丙", root: thirdRoot, database: thirdDatabase)

        var firstFive = asset(id: "A-1", projectID: firstProject.id, root: firstRoot, fingerprint: "same-image", rating: 5)
        firstFive.name = "跨项目人物"
        firstFive.isMasterAsset = true
        var duplicateFive = asset(id: "B-1", projectID: secondProject.id, root: secondRoot, fingerprint: "same-image", rating: 5)
        duplicateFive.name = "同图不同项目名称"
        let projectOnlyFive = asset(id: "B-5", projectID: secondProject.id, root: secondRoot, fingerprint: "project-only", rating: 5)
        var fourStar = asset(id: "B-4", projectID: secondProject.id, root: secondRoot, fingerprint: "four-star", rating: 4)
        fourStar.isMasterAsset = true

        try await ProjectDatabase(url: firstDatabase).replace(with: snapshot([firstFive]))
        try await ProjectDatabase(url: secondDatabase).replace(with: snapshot([duplicateFive, projectOnlyFive, fourStar]))
        try await ProjectDatabase(url: thirdDatabase).replace(with: snapshot([]))

        let store = GlobalFiveStarStore(rootURL: root)
        await store.refresh(
            projects: [firstProject, secondProject, thirdProject],
            currentProjectID: firstProject.id,
            currentAssets: [firstFive]
        )

        precondition(store.records.count == 3, "索引必须同时保留项目五星和不限评分的通用资产")
        let record = try require(store.records.first { $0.asset.fingerprint == "same-image" }, "通用五星记录应存在")
        precondition(record.galleryAsset.id == record.id, "瀑布流卡片必须使用全局去重ID，不能退回来源项目ID")
        precondition(record.galleryAsset.pixelWidth == record.asset.pixelWidth && record.galleryAsset.pixelHeight == record.asset.pixelHeight, "瀑布流必须保留原图比例元数据")
        precondition(Set(record.sources.map(\.projectID)) == [firstProject.id, secondProject.id])
        precondition(store.count(scope: .currentProject, projectID: firstProject.id) == 1)
        precondition(store.count(scope: .currentProject, projectID: secondProject.id) == 2)
        precondition(store.count(scope: .currentProject, projectID: thirdProject.id) == 0)
        precondition(store.count(scope: .allProjects, projectID: thirdProject.id) == 2)
        precondition(
            Set(store.records(scope: .allProjects, projectID: thirdProject.id, search: "", type: nil).map(\.asset.fingerprint)) == ["same-image", "four-star"],
            "通用资产只要求明确加入通用库，不得被五星门槛限制"
        )
        precondition(store.count(scope: .currentProject, projectID: firstProject.id, category: .people) == 1)
        precondition(store.count(scope: .currentProject, projectID: firstProject.id, category: .scenes) == 0)
        precondition(store.records(scope: .currentProject, projectID: firstProject.id, search: "", type: nil, category: .people).count == 1)

        store.addLink(recordID: record.id, projectID: thirdProject.id)
        precondition(store.count(scope: .currentProject, projectID: thirdProject.id) == 1, "全局五星引用后必须进入当前项目五星视图")
        precondition(store.records.count == 3, "建立项目引用不得复制全局资产记录")

        let reopened = GlobalFiveStarStore(rootURL: root)
        await reopened.refresh(
            projects: [firstProject, secondProject, thirdProject],
            currentProjectID: thirdProject.id,
            currentAssets: []
        )
        precondition(reopened.count(scope: .currentProject, projectID: thirdProject.id) == 1, "项目引用必须跨重启持久化")
        reopened.removeLink(recordID: record.id, projectID: thirdProject.id)
        precondition(reopened.count(scope: .currentProject, projectID: thirdProject.id) == 0)
        precondition(fileManager.fileExists(atPath: firstFive.imagePath), "取消项目引用不得删除原图")

        firstFive.rating = 4
        duplicateFive.rating = 4
        try await ProjectDatabase(url: firstDatabase).replace(with: snapshot([firstFive]))
        try await ProjectDatabase(url: secondDatabase).replace(with: snapshot([duplicateFive, projectOnlyFive, fourStar]))
        await reopened.refresh(
            projects: [firstProject, secondProject, thirdProject],
            currentProjectID: firstProject.id,
            currentAssets: [firstFive]
        )
        precondition(reopened.count(scope: .allProjects, projectID: firstProject.id) == 2, "通用来源降星后仍应保留；评分与通用范围必须独立")
        precondition(reopened.count(scope: .currentProject, projectID: secondProject.id) == 1, "项目专用五星仍应保留在当前项目五星")

        print("GlobalFiveStarStoreSelfTest passed")
    }

    private static func snapshot(_ assets: [AssetItem]) -> ProjectSnapshot {
        ProjectSnapshot(library: LibraryData(assets: assets, groups: [], relations: []), exportNames: [:])
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw NSError(domain: "GlobalFiveStarStoreSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return value
    }

    private static func project(id: String, name: String, root: URL, database: URL) -> ProjectRecord {
        ProjectRecord(
            id: id,
            name: name,
            rootPath: root.path,
            bookmarkData: nil,
            databasePath: database.path,
            isLegacy: false,
            lastOpenedAt: .now
        )
    }

    private static func asset(
        id: String,
        projectID: String,
        root: URL,
        fingerprint: String,
        rating: Int
    ) -> AssetItem {
        let file = root.appendingPathComponent("\(id).png")
        try? Data([0x89, 0x50, 0x4e, 0x47, UInt8(rating)]).write(to: file)
        var asset = PendingImportItem(
            id: id,
            stagedPath: file.path,
            originalSourcePath: file.path,
            originalFilename: file.lastPathComponent,
            sourceFileID: id,
            sourceFileSize: 5,
            sourceModifiedAt: .now,
            pixelWidth: 1024,
            pixelHeight: 1024,
            suggestedType: .person,
            category: .project,
            createdAt: .now
        ).previewAsset
        asset.id = id
        asset.projectID = projectID
        asset.fingerprint = fingerprint
        asset.rating = rating
        return asset
    }
}
