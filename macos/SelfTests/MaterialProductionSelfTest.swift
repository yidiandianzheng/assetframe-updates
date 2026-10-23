import Foundation
import AVFoundation
import AppKit

@main
struct MaterialProductionSelfTest {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("assetframe-production-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixtures")
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        let supplied = ProcessInfo.processInfo.environment["ASSETFRAME_MEDIA_FIXTURES"].map { URL(fileURLWithPath: $0) }
        if let supplied {
            for name in ["image.png", "video.mp4", "audio.wav", "large.wav"] { try fm.copyItem(at: supplied.appendingPathComponent(name), to: fixture.appendingPathComponent(name)) }
        } else { try await makeFixtures(fixture) }
        // Finder folder drops must expand nested mixed media while leaving originals intact.
        let droppedFolder = root.appendingPathComponent("拖入目录")
        let nested = droppedFolder.appendingPathComponent("子目录/音视频")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in ["image.png", "video.mp4", "audio.wav"] {
            try fm.copyItem(at: fixture.appendingPathComponent(name), to: nested.appendingPathComponent(name))
        }
        try Data().write(to: droppedFolder.appendingPathComponent(".hidden"))
        let expanded = GlobalMaterialStore.expand([droppedFolder])
        precondition(Set(expanded.map(\.lastPathComponent)) == Set(["image.png", "video.mp4", "audio.wav"]))
        precondition(expanded.allSatisfy { fm.fileExists(atPath: $0.path) })
        let scanResult = await GlobalMaterialStore.scanImportURLs([droppedFolder]) { _, _ in }
        check(scanResult.files.count == 3 && scanResult.errors.isEmpty)
        let missingScan = await GlobalMaterialStore.scanImportURLs([root.appendingPathComponent("不存在")]) { _, _ in }
        check(missingScan.files.isEmpty && missingScan.errors.count == 1)
        var urls: [URL] = []
        for index in 0..<100 {
            let file = ["image.png", "video.mp4", "audio.wav", "large.wav"][index % 4]
            let url = fixture.appendingPathComponent("\(index)-\(file)")
            try fm.copyItem(at: fixture.appendingPathComponent(file), to: url)
            urls.append(url)
        }
        let broken = fixture.appendingPathComponent("broken.mp4")
        try Data("damaged media".utf8).write(to: broken); urls.append(broken)
        urls.append(fixture.appendingPathComponent("missing.mp4"))
        let store = GlobalMaterialStore(rootURL: root.appendingPathComponent("store"))
        await store.waitUntilReady()
        store.importFiles(urls)
        check(store.importProgressVisible && store.isImporting && store.importPhase == "正在发现素材")
        // Editing while a batch is reading must survive subsequent batch commits.
        store.addLink("https://example.com/during-import")
        await wait { !store.isImporting }
        await store.waitForBackgroundMetadata()
        check(store.importPhase == "导入完成" && store.importProgressVisible)
        check(store.importProcessed == store.importTotal)
        check(store.importResults.count == urls.count)
        check(store.importResults.contains { $0.message.contains("missing.mp4") })
        check(store.materials.contains { $0.mediaMetadata?.issue?.contains("损坏") == true })
        check(store.materials.contains { $0.sourceURL == "https://example.com/during-import" })
        check(store.materials.count == 102, "后台查重不删除不同路径的素材记录")
        check(store.materials.filter { $0.duplicateContentOf != nil }.count == 96)
        let video = store.materials.first { $0.originalFilename.hasSuffix("video.mp4") }!
        let audio = store.materials.first { $0.originalFilename.hasSuffix("audio.wav") }!
        check(video.mediaMetadata?.isPlayable == true && video.mediaMetadata?.pixelWidth == 160 || video.mediaMetadata?.pixelWidth == 320)
        check(audio.mediaMetadata?.isPlayable == true && (audio.mediaMetadata?.sampleRate ?? 0) > 0)
        let analysis = await Task.detached { await MaterialMediaAnalysis.load(audio, cacheRoot: root.appendingPathComponent("cache")) }.value
        check(analysis.waveform.count == 256 && analysis.issue == nil, "Valid audio must generate a bounded waveform")
        let frames = await Task.detached { await MaterialMediaAnalysis.load(video, cacheRoot: root.appendingPathComponent("cache")) }.value
        check(frames.frames.count == 8 && frames.issue == nil, "Video must yield eight frames")

        let playback = MaterialPlaybackController.shared
        playback.player.isMuted = true
        playback.open(audio)
        await wait { playback.player.currentItem?.status == .readyToPlay }
        playback.loops = true; playback.toggle()
        try await Task.sleep(for: .milliseconds(1500))
        var resumed = false
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(50))
            resumed = resumed || (playback.player.rate > 0 && playback.player.currentTime().seconds > 0)
        }
        check(resumed, "Whole-file looping must resume after the end; seek completion cannot leave playback paused")
        playback.start = 0.1; playback.end = 0.3; playback.seek(0.1)
        try await Task.sleep(for: .milliseconds(650))
        check(playback.player.currentTime().seconds < 0.45, "Region loop must remain near the chosen out point")
        playback.open(video)
        check(playback.player.rate == 0 && !playback.playing, "Changing selection stops the preceding media")
        playback.stop()
        check(playback.player.currentItem == nil)

        store.update(audio.id) { m in m.name = "木门音效"; m.tags = ["木门", "开门"]; var p = MaterialProductionMetadata(); p.purpose = "音效"; m.production = p }
        _ = await store.saveNow()
        var filter = MaterialSearchFilter(); filter.search = "木门 开门"; filter.kinds = [.audio]; filter.maximumDuration = 3
        check(GlobalMaterialStore.query(store.materials, links: store.links, filter: filter, projectID: "p1").map(\.id) == [audio.id])
        store.savePreset(name: "开门音效", filter: filter)
        _ = await store.saveNow()
        var usage1 = ProjectMaterialLink(id: "use1", projectID: "p1", materialID: audio.id, use: .working, episode: "1", scene: "2", shot: "S001", selection: "选用", inPoint: 0, outPoint: 0.05, createdAt: .now)
        let usage2 = ProjectMaterialLink(id: "use2", projectID: "p2", materialID: audio.id, use: .working, shot: "S002", selection: "选用", createdAt: .now)
        store.saveUsage(usage1); store.saveUsage(usage2)
        _ = await store.saveNow()
        let newer = store.materials.first { $0.originalFilename.hasSuffix("large.wav") }!
        store.setVersion(newer.id, relativeTo: audio.id)
        _ = await store.saveNow()
        check(store.links.first { $0.id == "use2" }?.materialID == audio.id)
        usage1.materialID = newer.id
        store.saveUsage(usage1)
        _ = await store.saveNow()
        check(store.links.first { $0.id == "use1" }?.materialID == newer.id)
        check(store.links.first { $0.id == "use2" }?.materialID == audio.id)
        var badRange = usage1; badRange.outPoint = 100000
        store.saveUsage(badRange); _ = await store.saveNow()
        check(store.links.first { $0.id == "use1" }?.outPoint == 0.05)
        let output = try await Task.detached { try MaterialDelivery.export(materials: await store.materials, links: await store.links, projectID: "p1", destination: root) }.value
        let manifest = try String(contentsOf: output.appendingPathComponent("生产素材清单.csv"), encoding: .utf8)
        check(manifest.contains("S001") && manifest.contains(newer.id) && manifest.contains("0.05"))
        let exported = (fm.enumerator(at: output, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []).first { $0.pathExtension == "wav" }!
        check(GlobalMaterialStore.streamFingerprint(exported) == (newer.contentFingerprint ?? newer.fingerprint))
        store.removeUsage("use1"); _ = await store.saveNow()
        check(store.links.contains { $0.id == "use2" })
        check(fm.fileExists(atPath: newer.sourcePath!))

        let ssd = root.appendingPathComponent("test-ssd")
        let project = ProjectRecord(id: "p1", name: "测试项目", rootPath: fixture.path, bookmarkData: nil, databasePath: "", isLegacy: false, lastOpenedAt: .now)
        do { _ = try MaterialManagedCopy.copy(audio, common: false, project: project, ssdRoot: ssd); preconditionFailure("Offline SSD cannot create a fallback") } catch { }
        try fm.createDirectory(at: ssd, withIntermediateDirectories: true)
        let copy = try MaterialManagedCopy.copy(audio, common: false, project: project, ssdRoot: ssd)
        check(try MaterialManagedCopy.copy(audio, common: false, project: project, ssdRoot: ssd) == copy)
        let common = try MaterialManagedCopy.copy(audio, common: true, project: project, ssdRoot: ssd)
        check(copy != common && fm.fileExists(atPath: audio.sourcePath!))

        // New workspace actions must persist exact references and reject invalid ranges.
        let fixed = ProjectMaterialLink(id: "fixed-version", projectID: "p1", materialID: audio.id,
            use: .working, shot: "S003", selection: "选用", inPoint: 0, outPoint: 0.05, createdAt: .now)
        try await store.commitUsage(fixed)
        try await store.confirmMaterial(audio.id)
        check(store.materials.first { $0.id == audio.id }?.production?.review == "保留")
        check(store.links.first { $0.id == fixed.id }?.materialID == audio.id)
        var invalid = fixed; invalid.outPoint = 100000
        do { try await store.commitUsage(invalid); preconditionFailure("Invalid range accepted") } catch { }
        check(store.links.first { $0.id == fixed.id }?.outPoint == 0.05)
        let relocated = fixture.appendingPathComponent("relocated-audio.wav")
        try fm.copyItem(atPath: audio.sourcePath!, toPath: relocated.path)
        try await store.relocate(audio.id, to: relocated)
        check(store.materials.first { $0.id == audio.id }?.sourcePath == relocated.path)
        check(store.materials.first { $0.id == audio.id }?.tags == ["木门", "开门"])
        check(store.links.first { $0.id == fixed.id }?.materialID == audio.id)
        do { try await store.relocate(audio.id, to: fixture.appendingPathComponent("large.wav")); preconditionFailure("Different content accepted") } catch { }
        check(store.materials.first { $0.id == audio.id }?.sourcePath == relocated.path)

        let retrySSD = root.appendingPathComponent("offline-retry-ssd")
        let retryStore = GlobalMaterialStore(rootURL: root.appendingPathComponent("retry-store"), managedRoot: retrySSD)
        await retryStore.waitUntilReady()
        try await retryStore.replaceLibrary(MaterialSnapshot(materials: [audio], links: []))
        retryStore.makeCommon([audio.id], project: project)
        await retryStore.managedCopyTask?.value
        check(retryStore.materials[0].production?.isCommon == true)
        check(retryStore.materials[0].production?.managedCopies.isEmpty == true)
        try fm.createDirectory(at: retrySSD, withIntermediateDirectories: true)
        retryStore.makeCommon([audio.id], project: project)
        _ = await retryStore.pauseSession()
        check(retryStore.managedCopyJobs == 0 && retryStore.materials[0].production?.managedCopies.count == 1)
        let retryReopened = GlobalMaterialStore(rootURL: root.appendingPathComponent("retry-store"), managedRoot: retrySSD)
        await retryReopened.waitUntilReady()
        check(retryReopened.materials[0].production?.managedCopies.count == 1)
        await store.changeOrganization { $0.exportNames[video.id] = "历史导出视频" }
        let deliverySnapshot = try await store.libraryDeliverySnapshot(projectID: "library-test")
        check(deliverySnapshot.links.contains { $0.materialID == video.id && $0.projectID == "library-test" })
        check(deliverySnapshot.links.contains { $0.id == "use2" && $0.projectID == "library-test" })
        check(store.links.first { $0.id == "use2" }?.projectID == "p2", "Export must not rewrite stored project references")
        check(deliverySnapshot.materials.first { $0.id == video.id }?.name == "历史导出视频")
        print("Production workflow regression passed: fixed reference, invalid range, confirmation, verified relocation, offline copy retry and flush")

        let reopened = GlobalMaterialStore(rootURL: root.appendingPathComponent("store"))
        await reopened.waitUntilReady()
        check(reopened.materials == store.materials && reopened.links == store.links && reopened.presets == store.presets)
        let legacyRoot = root.appendingPathComponent("legacy")
        try fm.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let original = try JSONEncoder().encode(MaterialSnapshot(materials: store.materials, links: store.links))
        let json = legacyRoot.appendingPathComponent("global-material-library.json")
        try original.write(to: json)
        let migrated = GlobalMaterialStore(rootURL: legacyRoot); await migrated.waitUntilReady()
        check(migrated.materials == store.materials && migrated.links == store.links)
        check(try Data(contentsOf: json) == original)
        check(try Data(contentsOf: legacyRoot.appendingPathComponent("global-material-library.pre-sqlite-backup.json")) == original)

        let corruptRoot = root.appendingPathComponent("corrupt")
        try fm.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let corruptJSON = corruptRoot.appendingPathComponent("global-material-library.json")
        let corruptBytes = Data("{broken but precious".utf8); try corruptBytes.write(to: corruptJSON)
        let corrupt = GlobalMaterialStore(rootURL: corruptRoot); await corrupt.waitUntilReady()
        corrupt.addLink("https://example.com/must-not-overwrite")
        _ = await corrupt.saveNow()
        check(!corrupt.canWrite && corrupt.materials.isEmpty && (try? Data(contentsOf: corruptJSON)) == corruptBytes)
        check(!fm.fileExists(atPath: corruptRoot.appendingPathComponent("global-material-library.sqlite").path))
        let restoredDB = MaterialDatabase(root: corruptRoot)
        try await restoredDB.restore(from: json)
        let restored = try await restoredDB.load()
        check(restored.materials == store.materials)
        check(try Data(contentsOf: corruptJSON) == corruptBytes)
        let backup = root.appendingPathComponent("backup.sqlite")
        try await restoredDB.backup(to: backup)
        try await restoredDB.restore(from: backup)
        check(try await restoredDB.load().links == store.links)

        store.importFiles(urls); store.cancelImport()
        await wait { !store.isImporting }
        await store.waitForBackgroundMetadata()
        check(store.importResults.contains { $0.message == "已取消" })
        check(store.materials.count == 102)
        // A failed save must leave earlier committed edits intact and never publish later queued edits.
        let failingRoot = root.appendingPathComponent("fail-write")
        let failing = GlobalMaterialStore(rootURL: failingRoot); await failing.waitUntilReady()
        failing.addLink("https://example.com/committed"); _ = await failing.saveNow()
        let saved = failing.materials
        let dbPath = failingRoot.appendingPathComponent("global-material-library.sqlite")
        try fm.moveItem(at: dbPath, to: root.appendingPathComponent("preserved.sqlite"))
        try fm.createDirectory(at: dbPath, withIntermediateDirectories: false)
        failing.addLink("https://example.com/fail"); failing.addLink("https://example.com/later")
        _ = await failing.saveNow()
        check(failing.materials == saved && !failing.canWrite)

        var tenK = (0..<10000).map { i -> MaterialRecord in
            var m = i % 2 == 0 ? audio : video; m.id = "bench-\(i)"; m.fingerprint = "bench-hash-\(i)"; m.name = "素材 \(i)"; return m
        }
        tenK[9999].name = "精确目标"
        let benchDB = MaterialDatabase(root: root.appendingPathComponent("benchmark"))
        let blank = try await benchDB.load()
        let before = Date()
        try await benchDB.commit(MaterialSnapshot(materials: tenK, links: []), previous: blank)
        let writeMS = Date().timeIntervalSince(before) * 1000
        let reopenStart = Date(); let loaded = try await benchDB.load(); let reopenMS = Date().timeIntervalSince(reopenStart) * 1000
        var searchFilter = MaterialSearchFilter(); searchFilter.search = "精确目标"
        let searchStart = Date()
        for _ in 0..<20 { check(GlobalMaterialStore.query(loaded.materials, links: [], filter: searchFilter, projectID: "p1").count == 1) }
        let queryMS = Date().timeIntervalSince(searchStart) * 1000 / 20
        print("10K mixed index: write_ms=\(writeMS), reopen_ms=\(reopenMS), search_mean_ms=\(queryMS)")
        print("MaterialProductionSelfTest passed: 100 valid generated media imports + corrupt/missing, playback analysis, migration/recovery, cancellation, failure isolation, versions, delivery SHA256, SSD safety")
    }

    static func check(_ value: Bool, _ message: String = "Assertion failed", line: UInt = #line) { if !value { FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8)) }; precondition(value, message) }
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<6000 { if condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        preconditionFailure("Timed out")
    }
    static func makeFixtures(_ root: URL) async throws {
        let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try representation.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("image.png"))
        try wave(root.appendingPathComponent("audio.wav"), frames: 8000)
        try wave(root.appendingPathComponent("large.wav"), frames: 8_000_000)
        let writer = try AVAssetWriter(outputURL: root.appendingPathComponent("video.mp4"), fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for frame in 0..<12 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 15), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)) else { throw writer.error! }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
    }
    static func wave(_ url: URL, frames: Int) throws {
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        append(UInt32(36 + frames * 2)); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(8000)); append(UInt32(16000)); append(UInt16(2)); append(UInt16(16)); data.append(Data("data".utf8)); append(UInt32(frames * 2))
        data.append(Data(repeating: 20, count: frames * 2)); try data.write(to: url)
    }
}
