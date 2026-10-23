import Foundation

@main
struct FiveStarManagedCopySelfTest {
    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default
        let supportRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fakeSSD = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fakeSSD, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: supportRoot)
            try? fileManager.removeItem(at: sourceRoot)
            try? fileManager.removeItem(at: fakeSSD)
        }

        let source = sourceRoot.appendingPathComponent("五星人物.png")
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x05, 0x05, 0x05, 0x05])
        try bytes.write(to: source)

        let store = AssetStore(rootURL: supportRoot, managedLibrarySSDURL: fakeSSD)
        await waitUntil { !store.isLoadingProject }
        store.importImages([source])
        await waitUntil { !store.isImporting && store.assets.contains(where: { $0.originalFilename == source.lastPathComponent }) }

        let id = store.assets.first(where: { $0.originalFilename == source.lastPathComponent })!.id
        precondition(store.asset(withID: id)?.imagePath == source.path, "未满 5 星必须原位管理")
        store.updateAsset(id) {
            $0.type = .person
            $0.rating = 4
        }
        precondition(store.asset(withID: id)?.imagePath == source.path, "4 星必须继续原位管理")
        precondition(fileManager.fileExists(atPath: source.path), "4 星评分不得移动或删除原图")

        store.updateAsset(id) { $0.rating = 5 }
        await waitUntil {
            guard let path = store.asset(withID: id)?.imagePath else { return false }
            return path.hasPrefix(fakeSSD.path + "/") && path.contains("/01_向量时刻资产库/05_五星精选/人物资产/")
        }
        let managed = store.asset(withID: id)!
        precondition(fileManager.fileExists(atPath: source.path), "复制管理不得移动或删除原文件")
        precondition(fileManager.fileExists(atPath: managed.imagePath), "5 星受管副本必须存在")
        let managedBytes = try Data(contentsOf: URL(fileURLWithPath: managed.imagePath))
        precondition(managedBytes == bytes, "受管副本必须保持原字节")
        precondition(store.originalSourcePath(for: id) == source.path, "必须保留原文件追溯路径")

        let fiveStarPath = managed.imagePath
        store.updateAsset(id) { $0.rating = 4 }
        precondition(store.asset(withID: id)?.imagePath == fiveStarPath, "降星不得自动删除或移动既有五星副本")
        precondition(fileManager.fileExists(atPath: fiveStarPath), "降星后既有五星副本必须保留")

        store.updateAsset(id) { $0.rating = 5 }
        await waitUntil {
            store.asset(withID: id)?.imagePath.contains("/05_五星精选/人物资产/") == true
        }
        precondition(store.asset(withID: id)?.imagePath == fiveStarPath, "已受管资产再次评 5 星不得重复复制")

        let batchSource = sourceRoot.appendingPathComponent("批量五星道具.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x06]).write(to: batchSource)
        store.importImages([batchSource])
        await waitUntil { !store.isImporting && store.assets.contains(where: { $0.originalFilename == batchSource.lastPathComponent }) }
        let batchID = store.assets.first(where: { $0.originalFilename == batchSource.lastPathComponent })!.id
        store.bulkSetRating([batchID], rating: 5)
        await waitUntil {
            guard let path = store.asset(withID: batchID)?.imagePath else { return false }
            return path.hasPrefix(fakeSSD.path + "/") && path.contains("/01_向量时刻资产库/05_五星精选/")
        }

        let commonSource = sourceRoot.appendingPathComponent("跨项目通用道具.png")
        let commonBytes = Data([0x89, 0x50, 0x4e, 0x47, 0x06, 0x06])
        try commonBytes.write(to: commonSource)
        store.importImages([commonSource])
        await waitUntil { !store.isImporting && store.assets.contains(where: { $0.originalFilename == commonSource.lastPathComponent }) }
        let commonID = store.assets.first(where: { $0.originalFilename == commonSource.lastPathComponent })!.id
        store.performSetType(.prop, on: [.formal(commonID)])
        _ = store.performSetCommon(true, on: [.formal(commonID)])
        await waitUntil {
            store.asset(withID: commonID)?.imagePath.contains("/01_向量时刻资产库/06_通用资产/道具资产/") == true
        }
        let commonManagedPath = store.asset(withID: commonID)!.imagePath
        precondition(fileManager.fileExists(atPath: commonSource.path), "加入通用资产不得移动或删除原图")
        precondition(fileManager.fileExists(atPath: commonManagedPath), "通用资产 SSD 受管副本必须存在")
        let copiedCommonBytes = try Data(contentsOf: URL(fileURLWithPath: commonManagedPath))
        precondition(copiedCommonBytes == commonBytes)
        precondition(store.originalSourcePath(for: commonID) == commonSource.path, "通用资产必须保留原文件追溯路径")

        _ = store.performSetCommon(false, on: [.formal(commonID)])
        precondition(fileManager.fileExists(atPath: commonManagedPath), "移出通用资产不得删除已有 SSD 副本")
        _ = store.performSetCommon(true, on: [.formal(commonID)])
        await waitUntil { store.asset(withID: commonID)?.isMaster == true }
        let commonFolder = URL(fileURLWithPath: commonManagedPath).deletingLastPathComponent()
        let commonFiles = try fileManager.contentsOfDirectory(at: commonFolder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("跨项目通用道具") }
        precondition(commonFiles.count == 1, "再次加入通用资产必须复用已有 SSD 副本")

        _ = store.performSetRating(5, on: [.formal(commonID)])
        await waitUntil {
            guard let asset = store.asset(withID: commonID) else { return false }
            return asset.imagePath.contains("/05_五星精选/")
                && asset.allSourceVersions.contains(where: { $0.path.contains("/06_通用资产/") })
        }
        let commonAndFiveStar = store.asset(withID: commonID)!
        precondition(fileManager.fileExists(atPath: commonManagedPath), "成为五星后仍须保留通用资产副本")
        precondition(fileManager.fileExists(atPath: commonAndFiveStar.imagePath), "五星副本必须独立存在")

        let bulkCommonSource = sourceRoot.appendingPathComponent("批量通用人物.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x06, 0x66]).write(to: bulkCommonSource)
        store.importImages([bulkCommonSource])
        await waitUntil { !store.isImporting && store.assets.contains(where: { $0.originalFilename == bulkCommonSource.lastPathComponent }) }
        let bulkCommonID = store.assets.first(where: { $0.originalFilename == bulkCommonSource.lastPathComponent })!.id
        store.performSetType(.person, on: [.formal(bulkCommonID)])
        _ = store.performSetCommon(true, on: [.formal(bulkCommonID)])
        await waitUntil {
            store.asset(withID: bulkCommonID)?.imagePath.contains("/06_通用资产/人物资产/") == true
        }
        precondition(fileManager.fileExists(atPath: bulkCommonSource.path))

        let pendingFourSource = sourceRoot.appendingPathComponent("待确认四星场景.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x04, 0x04]).write(to: pendingFourSource)
        store.stageImages([pendingFourSource])
        await waitUntil { !store.isImporting && store.pendingImports.contains(where: { $0.originalFilename == pendingFourSource.lastPathComponent }) }
        let pendingFour = store.pendingImports.first(where: { $0.originalFilename == pendingFourSource.lastPathComponent })!
        let resolvedFour = store.performSetRating(4, on: [.pending(pendingFour.id)])
        precondition(resolvedFour.count == 1 && resolvedFour.first?.capabilities.ratingPromotesToFormal == false)
        guard let promotedFour = store.assets.first(where: { $0.originalFilename == pendingFourSource.lastPathComponent }) else {
            preconditionFailure("待确认四星应登记为正式资产")
        }
        precondition(promotedFour.starRating == 4)
        precondition(promotedFour.imagePath == pendingFourSource.path, "待确认项评 4 星后必须保持原位")
        precondition(fileManager.fileExists(atPath: pendingFourSource.path))

        let pendingFiveSource = sourceRoot.appendingPathComponent("待确认五星人物.png")
        let pendingFiveBytes = Data([0x89, 0x50, 0x4e, 0x47, 0x05, 0x55])
        try pendingFiveBytes.write(to: pendingFiveSource)
        store.stageImages([pendingFiveSource])
        await waitUntil { !store.isImporting && store.pendingImports.contains(where: { $0.originalFilename == pendingFiveSource.lastPathComponent }) }
        let pendingFive = store.pendingImports.first(where: { $0.originalFilename == pendingFiveSource.lastPathComponent })!
        _ = store.performSetRating(5, on: [.pending(pendingFive.id)])
        await waitUntil {
            guard let asset = store.assets.first(where: { $0.originalFilename == pendingFiveSource.lastPathComponent }) else { return false }
            return asset.starRating == 5 && asset.imagePath.hasPrefix(fakeSSD.path + "/")
        }
        let promotedFive = store.assets.first(where: { $0.originalFilename == pendingFiveSource.lastPathComponent })!
        precondition(!store.pendingImports.contains(where: { $0.id == pendingFive.id }))
        precondition(SavedView.favorites.includes(promotedFive), "原位待确认项评 5 星后必须进入五星目录")
        let promotedFiveBytes = try Data(contentsOf: URL(fileURLWithPath: promotedFive.imagePath))
        precondition(promotedFiveBytes == pendingFiveBytes)
        precondition(fileManager.fileExists(atPath: pendingFiveSource.path), "五星复制不得删除原图")

        let offlineSSD = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let offlineStore = AssetStore(rootURL: supportRoot.appendingPathComponent("offline", isDirectory: true), managedLibrarySSDURL: offlineSSD)
        await waitUntil { !offlineStore.isLoadingProject }
        let retrySource = sourceRoot.appendingPathComponent("离线重试五星道具.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x09]).write(to: retrySource)
        offlineStore.stageImages([retrySource])
        await waitUntil { !offlineStore.isImporting && offlineStore.pendingImports.count == 1 }
        let retryPending = offlineStore.pendingImports[0]
        _ = offlineStore.performSetRating(5, on: [.pending(retryPending.id)])
        guard let retryID = offlineStore.assets.first(where: { $0.originalFilename == retrySource.lastPathComponent })?.id else {
            preconditionFailure("SSD 离线时五星记录仍应原位登记")
        }
        precondition(offlineStore.asset(withID: retryID)?.starRating == 5)
        precondition(offlineStore.asset(withID: retryID)?.imagePath == retrySource.path)

        let offlineCommonSource = sourceRoot.appendingPathComponent("离线重试通用场景.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x06, 0x09]).write(to: offlineCommonSource)
        offlineStore.importImages([offlineCommonSource])
        await waitUntil {
            !offlineStore.isImporting
                && offlineStore.assets.contains(where: { $0.originalFilename == offlineCommonSource.lastPathComponent })
        }
        let offlineCommonID = offlineStore.assets.first(where: { $0.originalFilename == offlineCommonSource.lastPathComponent })!.id
        offlineStore.performSetType(.scene, on: [.formal(offlineCommonID)])
        _ = offlineStore.performSetCommon(true, on: [.formal(offlineCommonID)])
        precondition(offlineStore.asset(withID: offlineCommonID)?.imagePath == offlineCommonSource.path)
        await offlineStore.flushCurrentProject()
        try fileManager.createDirectory(at: offlineSSD, withIntermediateDirectories: true)
        let reloadedOfflineStore = AssetStore(
            rootURL: supportRoot.appendingPathComponent("offline", isDirectory: true),
            managedLibrarySSDURL: offlineSSD
        )
        await waitUntil {
            !reloadedOfflineStore.isLoadingProject &&
            reloadedOfflineStore.asset(withID: retryID)?.imagePath.contains("/05_五星精选/") == true
        }
        await waitUntil {
            reloadedOfflineStore.asset(withID: offlineCommonID)?.imagePath.contains("/06_通用资产/场景资产/") == true
        }
        precondition(fileManager.fileExists(atPath: retrySource.path), "SSD 重试复制不得改动原图")
        precondition(fileManager.fileExists(atPath: offlineCommonSource.path), "通用资产 SSD 重试不得改动原图")
        try? fileManager.removeItem(at: offlineSSD)

        print("FiveStarManagedCopySelfTest passed")
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out waiting for five-star managed copy")
    }
}
