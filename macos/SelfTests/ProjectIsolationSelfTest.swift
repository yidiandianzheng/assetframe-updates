import Foundation

@main
struct ProjectIsolationSelfTest {
    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectFolder = root.appendingPathComponent("流放镇北", isDirectory: true)
        let otherFolder = root.appendingPathComponent("豌豆", isDirectory: true)
        let externalFolder = root.appendingPathComponent("其他项目原图", isDirectory: true)
        try fileManager.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: externalFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let projectsDirectory = root.appendingPathComponent("Projects", isDirectory: true)
        let correctDatabaseURL = projectsDirectory.appendingPathComponent("correct/project.sqlite")
        let duplicateDatabaseURL = projectsDirectory.appendingPathComponent("duplicate/project.sqlite")
        let otherDatabaseURL = projectsDirectory.appendingPathComponent("other/project.sqlite")

        try await ProjectDatabase(url: correctDatabaseURL).replace(with: snapshot(
            asset: makeAsset(id: "NORTH-1", name: "镇北资产", projectID: "correct", imageRoot: projectFolder)
        ))
        try await ProjectDatabase(url: duplicateDatabaseURL).replace(with: ProjectSnapshot(
            library: LibraryData(
                assets: [
                    makeAsset(id: "WRONG-1", name: "豌豆资产 1", projectID: "duplicate", imageRoot: externalFolder),
                    makeAsset(id: "WRONG-2", name: "豌豆资产 2", projectID: "duplicate", imageRoot: externalFolder)
                ],
                groups: [],
                relations: []
            ),
            exportNames: [:]
        ))
        try await ProjectDatabase(url: otherDatabaseURL).replace(with: snapshot(
            asset: makeAsset(id: "PEA-1", name: "豌豆资产", projectID: "other", imageRoot: otherFolder)
        ))

        let progressRecorder = DatabaseProgressRecorder()
        let progressSnapshot = try await ProjectDatabase(url: correctDatabaseURL).load {
            progressRecorder.append($0)
        }
        let databaseProgress = progressRecorder.values()
        precondition(progressSnapshot.library.assets.map(\.id) == ["NORTH-1"])
        precondition(databaseProgress.first == ProjectDatabaseLoadProgress(completed: 0, total: 1))
        precondition(databaseProgress.last == ProjectDatabaseLoadProgress(completed: 1, total: 1))
        precondition(zip(databaseProgress, databaseProgress.dropFirst()).allSatisfy { $0.completed <= $1.completed })

        let now = Date.now
        let correct = ProjectRecord(
            id: "correct", name: "流放镇北", rootPath: projectFolder.path, bookmarkData: nil,
            databasePath: correctDatabaseURL.path, isLegacy: false,
            lastOpenedAt: now.addingTimeInterval(-200)
        )
        let duplicate = ProjectRecord(
            id: "duplicate", name: "流放镇北", rootPath: projectFolder.path + "/", bookmarkData: nil,
            databasePath: duplicateDatabaseURL.path, isLegacy: false,
            lastOpenedAt: now
        )
        let other = ProjectRecord(
            id: "other", name: "豌豆", rootPath: otherFolder.path, bookmarkData: nil,
            databasePath: otherDatabaseURL.path, isLegacy: false,
            lastOpenedAt: now.addingTimeInterval(-100)
        )
        let registry = ProjectRegistryData(
            projects: [duplicate, correct, other],
            currentProjectID: duplicate.id
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(registry).write(to: root.appendingPathComponent("projects.json"))

        let store = AssetStore(rootURL: root)
        await waitUntil { !store.isLoadingProject }
        precondition(store.projects.count == 2, "相同文件夹的重复项目入口必须合并")
        precondition(store.currentProject.id == correct.id, "应优先恢复原图确实属于该项目的数据库")
        precondition(store.assets.map(\.id) == ["NORTH-1"], "打开镇北项目不得显示豌豆资产")
        precondition(fileManager.fileExists(atPath: root.appendingPathComponent("projects.pre-dedup-backup.json").path))
        precondition(store.projectLoadProgress?.stage == .ready)

        store.switchProject(other.id)
        store.switchProject(correct.id)
        await waitUntil { !store.isLoadingProject }
        precondition(store.currentProject.id == correct.id, "返回当前项目必须取消尚未开始的旧切换请求")
        precondition(store.assets.map(\.id) == ["NORTH-1"], "取消旧切换后不得安装其他项目快照")
        let registryAfterCancellation = ProjectRegistry(
            rootURL: root,
            legacyAssetsURL: root.appendingPathComponent("Assets", isDirectory: true)
        )
        precondition(registryAfterCancellation.current.id == correct.id, "取消切换后注册表也必须恢复当前项目")

        let originalRootPath = store.currentProject.rootPath
        precondition(store.renameCurrentProject(to: "西方领主游戏"), "当前项目显示名称必须可以修改")
        precondition(store.currentProject.name == "西方领主游戏")
        precondition(store.currentProject.rootPath == originalRootPath, "修改显示名称不得改变项目文件夹路径")
        let renamedRegistry = ProjectRegistry(
            rootURL: root,
            legacyAssetsURL: root.appendingPathComponent("Assets", isDirectory: true)
        )
        precondition(renamedRegistry.projects.first(where: { $0.id == correct.id })?.name == "西方领主游戏", "项目显示名称必须持久化")

        store.updateAsset("NORTH-1") { $0.name = "镇北资产已修改" }
        store.switchProject(other.id)
        await waitUntil { store.currentProject.id == other.id && !store.isLoadingProject }
        precondition(store.assets.map(\.id) == ["PEA-1"], "切换后只能安装目标项目快照")

        store.switchProject(correct.id)
        await waitUntil { store.currentProject.id == correct.id && !store.isLoadingProject }
        precondition(store.assets.first?.name == "镇北资产已修改")
        let otherSnapshot = try await ProjectDatabase(url: otherDatabaseURL).load()
        precondition(otherSnapshot.library.assets.map(\.id) == ["PEA-1"], "旧项目延迟保存不得覆盖新项目数据库")

        let today = makeAsset(id: "TODAY", name: "今日新增", projectID: correct.id, imageRoot: projectFolder)
        var yesterday = makeAsset(id: "YESTERDAY", name: "昨日新增", projectID: correct.id, imageRoot: projectFolder)
        yesterday.createdAt = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .distantPast
        precondition(SavedView.today.includes(today))
        precondition(!SavedView.today.includes(yesterday))

        store.pendingImports = [PendingImportItem(
            id: "PENDING-1", stagedPath: projectFolder.appendingPathComponent("pending.png").path,
            originalSourcePath: projectFolder.appendingPathComponent("pending.png").path,
            originalFilename: "pending.png", sourceFileID: "pending", sourceFileSize: 1,
            sourceModifiedAt: .now, pixelWidth: 2048, pixelHeight: 2048,
            suggestedType: .unclassified, category: .common, createdAt: .now
        )]
        store.bulkSetPendingType(["PENDING-1"], type: .person)
        precondition(store.pendingImports.first?.category == .common, "手工归类不得被类型修改覆盖")
        store.bulkSetPendingCategory(["PENDING-1"], category: .temporary)
        precondition(store.pendingImports.first?.category == .temporary)

        store.removeProject(correct.id)
        await waitUntil {
            store.currentProject.id == other.id && !store.isLoadingProject && store.projects.count == 1
        }
        precondition(store.assets.map(\.id) == ["PEA-1"], "删除当前项目后应安全切换到剩余项目")
        precondition(fileManager.fileExists(atPath: correctDatabaseURL.path), "删除项目不得删除资产数据库")
        precondition(fileManager.fileExists(atPath: projectFolder.path), "删除项目不得删除原图文件夹")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let removedRegistry = try decoder.decode(
            ProjectRegistryData.self,
            from: Data(contentsOf: root.appendingPathComponent("projects.json"))
        )
        precondition(removedRegistry.projects.map(\.id) == [other.id])
        precondition(removedRegistry.removedProjects?.map(\.id) == [correct.id])

        let reopenedRegistry = ProjectRegistry(
            rootURL: root,
            legacyAssetsURL: root.appendingPathComponent("Assets", isDirectory: true)
        )
        let restored = reopenedRegistry.addProject(folderURL: projectFolder)
        precondition(restored.id == correct.id, "重新打开文件夹应恢复原项目 ID 与数据库")
        precondition(reopenedRegistry.projects.count == 2)
        precondition(reopenedRegistry.data.removedProjects?.isEmpty ?? true)

        print("ProjectIsolationSelfTest passed")
    }

    private static func snapshot(asset: AssetItem) -> ProjectSnapshot {
        ProjectSnapshot(library: LibraryData(assets: [asset], groups: [], relations: []), exportNames: [:])
    }

    private static func makeAsset(
        id: String,
        name: String,
        projectID: String,
        imageRoot: URL
    ) -> AssetItem {
        var asset = PendingImportItem(
            id: id,
            stagedPath: imageRoot.appendingPathComponent("\(id).png").path,
            originalSourcePath: imageRoot.appendingPathComponent("\(id).png").path,
            originalFilename: "\(id).png",
            sourceFileID: id,
            sourceFileSize: 1,
            sourceModifiedAt: .now,
            pixelWidth: 2048,
            pixelHeight: 2048,
            suggestedType: .person,
            category: .project,
            createdAt: .now
        ).previewAsset
        asset.id = id
        asset.name = name
        asset.projectID = projectID
        return asset
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out")
    }
}

private final class DatabaseProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProjectDatabaseLoadProgress] = []

    func append(_ progress: ProjectDatabaseLoadProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }

    func values() -> [ProjectDatabaseLoadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
