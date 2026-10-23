import Foundation

@main
struct GlobalMaterialStoreSelfTest {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("assetframe-material-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let first = root.appendingPathComponent("first.png")
        let renamed = root.appendingPathComponent("renamed-copy.dat")
        try Data("same bytes".utf8).write(to: first)
        try Data("same bytes".utf8).write(to: renamed)
        let large = root.appendingPathComponent("large.bin")
        try Data(repeating: 0x5a, count: 3_200_000).write(to: large)
        precondition(
            GlobalMaterialStore.streamFingerprint(large, chunkSize: 64 * 1024)
                == GlobalMaterialStore.streamFingerprint(large, chunkSize: 1_048_576),
            "流式哈希不得受分块大小影响"
        )
        try fm.removeItem(at: large)

        let store = GlobalMaterialStore(rootURL: root)
        store.importFiles([first])
        await waitUntil { !store.isImporting }
        await store.waitForBackgroundMetadata()
        precondition(store.materials.count == 1, "首次导入应建立一条全局素材记录")
        let materialID = try XCTLike.unwrap(store.materials.first?.id)

        store.importFiles([renamed])
        await waitUntil { !store.isImporting }
        await store.waitForBackgroundMetadata()
        precondition(store.materials.count == 2, "内容重复保留独立文件，后台标记待处理")
        precondition(store.materials[0].sourcePath == first.path, "主文件存在时重复导入不应产生第二个路径")
        precondition(store.materials[0].sourceLocations == [first.path], "兼容字段也只保留当前单一路径")

        store.setLink(materialID: materialID, projectID: "project-a", use: .candidate)
        store.setLink(materialID: materialID, projectID: "project-b", use: .reference)
        _ = await store.saveNow()
        precondition(store.materials(projectID: "project-a").map(\.id) == [materialID])
        _ = await store.saveNow()
        precondition(store.materials(projectID: "project-b").map(\.id) == [materialID])
        store.removeLink(materialID: materialID, projectID: "project-a")
        _ = await store.saveNow()
        precondition(store.materials(projectID: "project-a").isEmpty, "移除项目引用后不应继续显示在该项目")
        precondition(fm.fileExists(atPath: first.path), "移除项目引用不得删除源文件")

        precondition(store.materials.contains { $0.duplicateContentOf == materialID })
        try fm.removeItem(at: first)
        precondition(store.materials.first?.sourceMissing == true, "当前文件失联时应明确标记缺失")
        store.importFiles([renamed])
        await waitUntil { !store.isImporting }
        await store.waitForBackgroundMetadata()
        precondition(store.materials.first?.sourceMissing == true, "重新导入不能自动替换已引用版本")
        precondition(store.materials.first?.sourcePath == first.path, "原记录保留原路径")
        precondition(store.materials.first?.sourceLocations == [first.path])
        try fm.removeItem(at: renamed)
        precondition(store.materials.first?.sourceMissing == true, "当前文件离线时仍保留素材记录并明确缺失")

        let wav = root.appendingPathComponent("tone.wav")
        try makePCMWave(at: wav, sampleRate: 8_000, channels: 1, frameCount: 800)
        store.importAudioFiles([wav])
        await waitUntil { !store.isImporting }
        await store.waitForBackgroundMetadata()
        let audio = try XCTLike.unwrap(store.materials.first(where: { $0.originalFilename == "tone.wav" }))
        precondition(audio.kind == .audio)
        precondition(audio.mediaMetadata?.sampleRate == 8_000)
        precondition(audio.mediaMetadata?.channelCount == 1)
        precondition((audio.mediaMetadata?.durationSeconds ?? 0) > 0.09)

        store.addLink("https://example.com/reference")
        _ = await store.saveNow()
        precondition(store.materials().contains(where: { $0.kind == .link && $0.sourceURL == "https://example.com/reference" }))
        precondition(store.materials().first(where: { $0.kind == .link })?.sourceMissing == false)

        var presetFilter = MaterialSearchFilter(); presetFilter.kinds = [.image]
        store.savePreset(name: "Visual", filter: presetFilter)
        try await store.saveNow().get()
        let presetID = try XCTLike.unwrap(store.presets.first?.id)
        presetFilter.minimumRating = 4
        store.savePreset(name: " visual ", filter: presetFilter)
        try await store.saveNow().get()
        precondition(store.presets.count == 1 && store.presets[0].id == presetID,
                     "同名保存应更新原组合并保留 ID，不追加重复组合")
        precondition(store.presets[0].filter.minimumRating == 4 && store.presets[0].name == "visual")
        store.savePreset(name: "音频", filter: MaterialSearchFilter(kinds: [.audio]))
        store.savePreset(name: "  ", filter: presetFilter)
        try await store.saveNow().get()
        precondition(store.presets.count == 2, "不同名称可另存，空白名称不得新增")

        let reopened = GlobalMaterialStore(rootURL: root)
        await reopened.waitUntilReady()
        precondition(reopened.materials.count == 4, "重启后应恢复文件、音频与链接素材")
        precondition(reopened.materials.first(where: { $0.kind != .link })?.sourceLocations.count == 1)
        precondition(reopened.links.count == 1 && reopened.links[0].projectID == "project-b")
        precondition(reopened.presets.count == 2 && reopened.presets.first?.id == presetID
                     && reopened.presets.first?.filter.minimumRating == 4,
                     "更新后的筛选组合应可靠持久化")
        let reopenedAudio = try XCTLike.unwrap(reopened.materials.first(where: { $0.kind == .audio }))
        precondition(reopenedAudio.mediaMetadata?.sampleRate == 8_000)
        precondition(reopenedAudio.mediaMetadata?.channelCount == 1)

        let blockedRoot = root.appendingPathComponent("root-is-a-file")
        try Data("not a directory".utf8).write(to: blockedRoot)
        let failingStore = GlobalMaterialStore(rootURL: blockedRoot)
        await failingStore.waitUntilReady()
        failingStore.addLink("https://example.com/must-not-persist")
        precondition(failingStore.materials.isEmpty, "保存失败时必须回滚内存成功状态")
        precondition(failingStore.persistenceError != nil)
        if case .success = await failingStore.saveNow() {
            preconditionFailure("不可写根目录必须明确返回失败")
        }

        let corruptRoot = root.appendingPathComponent("corrupt", isDirectory: true)
        try fm.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: corruptRoot.appendingPathComponent("global-material-library.json"))
        let corruptStore = GlobalMaterialStore(rootURL: corruptRoot)
        await corruptStore.waitUntilReady()
        precondition(corruptStore.persistenceError?.contains("素材库读取失败") == true)
        try await testPreviewUsage(root: root.appendingPathComponent("preview-usage"))
        print("GlobalMaterialStoreSelfTest passed: coalesced_usage query_revision recent_order timer pause_flush failure_retry")
    }

    @MainActor
    private static func testPreviewUsage(root: URL) async throws {
        let store = GlobalMaterialStore(rootURL: root)
        await store.waitUntilReady()
        store.addLink("https://example.com/first")
        store.addLink("https://example.com/second")
        try await store.saveNow().get()
        let first = store.materials[0].id, second = store.materials[1].id
        let initialQuery = store.queryRevision, initialCommits = store.persistenceCommitCount
        let ordinary = store.browseQueryRevision(scope: "all", sortField: .name)
        let recent = store.browseQueryRevision(scope: "recent", sortField: .name)
        let recentOrder = store.browseQueryRevision(scope: "all", sortField: .recentlyUsed)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<120 {
            store.recordPreviewUsage(index.isMultiple(of: 2) ? first : second, at: start.addingTimeInterval(Double(index)))
        }
        precondition(store.materials.allSatisfy { $0.lastUsedAt == nil }, "Buffered visits must not claim a successful commit")
        try await store.saveNow().get()
        precondition(store.persistenceCommitCount == initialCommits + 1, "120 visits must coalesce into one transaction")
        precondition(store.queryRevision == initialQuery)
        precondition(store.browseQueryRevision(scope: "all", sortField: .name) == ordinary,
                     "Usage must not invalidate ordinary queries")
        precondition(store.browseQueryRevision(scope: "recent", sortField: .name) != recent)
        precondition(store.browseQueryRevision(scope: "all", sortField: .recentlyUsed) != recentOrder)
        precondition(store.materials.first { $0.id == first }?.lastUsedAt == start.addingTimeInterval(118))
        precondition(store.materials.first { $0.id == second }?.lastUsedAt == start.addingTimeInterval(119))
        precondition(GlobalMaterialStore.sortedMaterials(store.materials, order: .init(field: .recentlyUsed)).first?.id == second)

        // Older callbacks cannot move a visit time backwards.
        store.recordPreviewUsage(first, at: start)
        try await store.saveNow().get()
        precondition(store.persistenceCommitCount == initialCommits + 1)

        let timerTime = start.addingTimeInterval(200)
        store.recordPreviewUsage(first, at: timerTime)
        await waitUntil { store.materials.first { $0.id == first }?.lastUsedAt == timerTime }
        precondition(store.queryRevision == initialQuery, "Timer flush must remain usage-only")

        store.recordPreviewUsage(first, at: start.addingTimeInterval(300))
        store.update(first) { $0.name = "Edited title"; $0.rating = 4; $0.tags = ["retained"] }
        try await store.saveNow().get()
        let edited = store.materials.first { $0.id == first }!
        precondition(edited.name == "Edited title" && edited.rating == 4 && edited.tags == ["retained"])
        precondition(edited.lastUsedAt == start.addingTimeInterval(300))
        precondition(store.queryRevision == initialQuery + 1, "Ordinary edits must still invalidate query results")

        // Cut the session before the timer fires; disk state must include visits.
        store.recordPreviewUsage(second, at: start.addingTimeInterval(400))
        try await store.pauseSession().get()
        store.recordPreviewUsage(second, at: start.addingTimeInterval(500))
        try await store.saveNow().get()
        let reopened = GlobalMaterialStore(rootURL: root, paused: true)
        await reopened.waitUntilReady()
        precondition(reopened.materials.first { $0.id == second }?.lastUsedAt == start.addingTimeInterval(400))
        store.resumeSession()

        // Break only this temporary database root, then restore and retry it.
        let savedRoot = root.appendingPathExtension("saved")
        store.recordPreviewUsage(first, at: start.addingTimeInterval(600))
        try FileManager.default.moveItem(at: root, to: savedRoot)
        try Data("blocked directory".utf8).write(to: root)
        let beforeFailure = store.materials
        if case .success = await store.saveNow() { preconditionFailure("Blocked commit must fail") }
        precondition(store.materials == beforeFailure, "Failed usage write must publish nothing")
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: savedRoot, to: root)
        store.retryLoad()
        await waitUntil { store.materials.first { $0.id == first }?.lastUsedAt == start.addingTimeInterval(600) }
        precondition(store.persistenceError == nil, "Buffered visits must survive failure and reload")

        store.recordPreviewUsage(first, at: start.addingTimeInterval(700))
        store.update(first) { $0.deletedAt = start.addingTimeInterval(650) }
        try await store.saveNow().get()
        precondition(store.materials.first { $0.id == first }?.lastUsedAt == start.addingTimeInterval(600),
                     "Late visits must not update or resurrect removed materials")
        let final = GlobalMaterialStore(rootURL: root, paused: true)
        await final.waitUntilReady()
        precondition(final.materials.first { $0.id == first }?.deletedAt != nil)
        precondition(final.materials.first { $0.id == second }?.lastUsedAt == start.addingTimeInterval(400))
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out waiting for material import")
    }

    private static func makePCMWave(at url: URL, sampleRate: UInt32, channels: UInt16, frameCount: UInt32) throws {
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = frameCount * UInt32(blockAlign)
        var data = Data("RIFF".utf8)
        append(UInt32(36) + dataSize, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(channels, to: &data)
        append(sampleRate, to: &data)
        append(byteRate, to: &data)
        append(blockAlign, to: &data)
        append(bitsPerSample, to: &data)
        data.append(Data("data".utf8))
        append(dataSize, to: &data)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        try data.write(to: url)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

private enum XCTLike {
    static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "GlobalMaterialStoreSelfTest", code: 1) }
        return value
    }
}
