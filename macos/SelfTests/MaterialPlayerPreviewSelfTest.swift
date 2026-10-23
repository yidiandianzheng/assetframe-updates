import AppKit
import AVFoundation
import AVKit
import Foundation

@main
struct MaterialPlayerPreviewSelfTest {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assetframe-qa.player-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = root.appendingPathComponent("audio.wav")
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + 32_000)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(8000)); append(UInt32(16000)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(32_000)); data.append(Data(repeating: 20, count: 32_000))
        try data.write(to: wav)
        let broken = root.appendingPathComponent("broken.mp4")
        try Data("invalid media".utf8).write(to: broken)
        func record(_ id: String, _ path: URL) -> MaterialRecord {
            MaterialRecord(id: id, kind: .audio, name: id, sourcePath: path.path,
                originalFilename: path.lastPathComponent, fingerprint: id, sourceLocations: [path.path],
                mediaMetadata: MaterialMediaMetadata(durationSeconds: 2), createdAt: .now, tags: [], rating: 0, note: "")
        }
        let playable = record("new-owner", wav)
        let old = record("old-owner", broken)
        let missing = record("missing-owner", root.appendingPathComponent("missing.wav"))
        let playback = MaterialPlaybackController()
        playback.player.isMuted = true
        for _ in 0..<8 {
            playback.open(old)
            await Task.yield()
            playback.open(playable)
            playback.stop(owner: old.id)
            precondition(playback.player.currentItem != nil, "Outgoing owner's teardown must not stop the new item")
            try await ready(playback)
            precondition(playback.error == nil && !playback.playing)
            playback.seek(0.15)
            playback.stop()
            try await Task.sleep(for: .milliseconds(20))
            precondition(playback.player.currentItem == nil && !playback.playing)
        }
        playback.open(missing)
        precondition(playback.error == "源文件不可用" && playback.player.currentItem == nil)
        playback.open(playable)
        try await ready(playback)
        precondition(playback.error == nil)
        let item = playback.player.currentItem
        let view = NativeMaterialVideoPlayer.makePlayerView(player: playback.player)
        precondition(view.player === playback.player && view.controlsStyle == .inline && view.videoGravity == .resizeAspect)
        NativeMaterialVideoPlayer.dismantleNSView(view, coordinator: ())
        precondition(view.player == nil && playback.player.currentItem === item)
        playback.stop()
        let detailHost = UUID(), expandedHost = UUID()
        playback.attach(playable, hostID: detailHost)
        try await ready(playback)
        let sharedItem = playback.player.currentItem
        playback.attach(playable, hostID: expandedHost)
        precondition(playback.player.currentItem === sharedItem, "Second visible host must not reset playback")
        playback.detach(hostID: expandedHost)
        precondition(playback.player.currentItem === sharedItem, "Leaving expanded preview must retain the detail player's item")
        playback.seek(0.2)
        playback.pause()
        try await Task.sleep(for: .milliseconds(30))
        precondition(!playback.playing && playback.player.currentItem === sharedItem,
                     "Return-to-gallery pause retains the item and cancels pending seek resume")
        let issued = playback.seekIssuedCount
        playback.beginScrubbing()
        for i in 0..<200 { playback.scrub(to: Double(i) / 200) }
        precondition(playback.seekIssuedCount == issued && playback.scrubCoalescedCount >= 199)
        playback.endScrubbing()
        for _ in 0..<200 {
            if !playback.seeking { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(!playback.seeking && abs(playback.player.currentTime().seconds - 0.995) < 0.02)
        precondition(playback.seekIssuedCount == issued + 1 && !playback.playing)
        playback.beginScrubbing(); playback.scrub(to: 1.4)
        playback.open(playable)
        playback.attach(playable, hostID: detailHost)
        try await ready(playback)
        try await Task.sleep(for: .milliseconds(80))
        precondition(!playback.scrubbing && !playback.seeking && playback.time < 0.1, "Pending old scrub cannot seek the new item")
        playback.toggle()
        try await Task.sleep(for: .milliseconds(30))
        playback.beginScrubbing(); playback.scrub(to: 0.5); playback.endScrubbing(); playback.pause()
        try await Task.sleep(for: .milliseconds(80))
        precondition(!playback.playing, "Pause during scrub completion must defeat pending resume")
        playback.loops = true
        playback.start = 0.1; playback.end = 0.35
        playback.toggle()
        try await Task.sleep(for: .milliseconds(750))
        precondition(playback.error == nil && playback.playing)
        precondition(playback.player.currentTime().seconds < 0.6, "Region loop must honor the chosen out point")
        playback.detach(hostID: detailHost)
        precondition(playback.player.currentItem == nil, "Last visible host releases playback")
        playback.attach(old, hostID: detailHost)
        playback.attach(playable, hostID: expandedHost)
        playback.detach(hostID: detailHost)
        try await ready(playback)
        precondition(playback.error == nil && playback.player.currentItem != nil, "Old host must not stop or poison the new material")
        playback.stop()

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let analysis = MaterialMediaAnalysis(frames: [png, Data([0]), png, png], times: [0.5, 1, 1.5, .nan])
        let frames = CachedMaterialVideoFrame.prepare(analysis)
        precondition(frames.map(\.time) == [0.5, 1.5])
        precondition(frames.allSatisfy { $0.image.size == NSSize(width: 16, height: 8) })
        precondition(CachedMaterialVideoFrame.prepare(MaterialMediaAnalysis()).isEmpty)
        let preservedBytes = try Data(contentsOf: wav)
        precondition(preservedBytes == data, "Playback must leave original bytes untouched")
        print("MaterialPlayerPreviewSelfTest passed: native AVPlayerView, invalid-to-valid switches, owner/seek teardown, missing recovery, shared detail/expanded hosts, last-host release, region looping and cached frame/time pairing")
    }

    @MainActor static func ready(_ playback: MaterialPlaybackController) async throws {
        for _ in 0..<600 {
            if playback.player.currentItem?.status == .readyToPlay { return }
            precondition(playback.error == nil, "Old failure callback must not poison the current item")
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Player readiness timed out")
    }
}
