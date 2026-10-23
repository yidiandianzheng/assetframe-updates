import AVFoundation
import Combine
import Foundation

@MainActor
final class MaterialPlaybackController: ObservableObject {
    static let shared = MaterialPlaybackController()
    let player = AVPlayer()
    @Published var time: Double = 0
    @Published var playing = false
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var loops = false
    @Published var error: String?
    private var endObserver: NSObjectProtocol?
    private var seekRequest = UUID()
    private var isSeeking = false
    private var scrubActive = false
    private var scrubResume = false
    private var pendingScrub: Double?
    private var scrubTask: Task<Void, Never>?
    private(set) var seekIssuedCount = 0
    private(set) var scrubCoalescedCount = 0
    var seeking: Bool { isSeeking || pendingScrub != nil }
    var scrubbing: Bool { scrubActive }
    private var observer: Any?
    private var statusObserver: NSKeyValueObservation?
    private var ownerID: String?
    var currentMaterialID: String? { ownerID }
    private var playbackSession = UUID()
    private var attachedHosts: [UUID: String] = [:]

    func open(_ material: MaterialRecord) {
        attachedHosts.removeAll()
        replacePlayback(material)
    }

    func attach(_ material: MaterialRecord, hostID: UUID) {
        attachedHosts[hostID] = material.id
        // The gallery detail and expanded preview share one player. Mounting
        // the second presentation must not reopen or reset the same item.
        if ownerID == material.id, player.currentItem != nil || error != nil { return }
        replacePlayback(material)
    }

    func detach(hostID: UUID) {
        guard let materialID = attachedHosts.removeValue(forKey: hostID),
              ownerID == materialID,
              !attachedHosts.values.contains(materialID) else { return }
        stopCurrentPlayback()
    }

    private func replacePlayback(_ material: MaterialRecord) {
        stopCurrentPlayback()
        let session = playbackSession
        ownerID = material.id
        time = 0; start = 0; end = material.mediaMetadata?.durationSeconds ?? 0; loops = false; error = nil
        guard let path = material.sourcePath, FileManager.default.isReadableFile(atPath: path) else { error = "源文件不可用"; return }
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            let completedID = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in
                guard let self, self.playbackSession == session,
                      let current = self.player.currentItem, ObjectIdentifier(current) == completedID else { return }
                if self.loops && self.end > self.start {
                    self.playing = true
                    self.seek(self.start)
                } else { self.playing = false }
            }
        }
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let message = item.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.playbackSession == session, failed else { return }
                self.error = message ?? "播放失败"; self.playing = false
            }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] stamp in
            let seconds = stamp.seconds
            Task { @MainActor [weak self] in
                guard let self, self.playbackSession == session, seconds.isFinite else { return }
                if !self.isSeeking && !self.scrubActive { self.time = seconds }
                if !self.isSeeking && !self.scrubActive { self.playing = self.player.rate > 0 }
                if self.playing && !self.isSeeking && self.end > self.start && seconds >= self.end - 0.02 {
                    if self.loops { self.seek(self.start) }
                    else { self.player.pause(); self.playing = false }
                }
            }
        }
    }
    func beginScrubbing() {
        guard player.currentItem != nil, !scrubActive else { return }
        scrubResume = playing; scrubActive = true
        player.pause(); playing = false
    }
    func scrub(to seconds: Double) {
        guard seconds.isFinite, player.currentItem != nil else { return }
        guard scrubActive else { seek(seconds); return }
        let value = boundedTime(seconds); time = value
        if pendingScrub != nil { scrubCoalescedCount += 1 }
        pendingScrub = value
        guard scrubTask == nil else { return }
        let session = playbackSession
        scrubTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            guard let self, self.playbackSession == session, self.scrubActive else { return }
            self.scrubTask = nil
            guard let target = self.pendingScrub else { return }
            self.pendingScrub = nil
            self.performSeek(target, precise: false, resume: false)
        }
    }
    func endScrubbing() {
        guard scrubActive else { return }
        let value = pendingScrub ?? time, resume = scrubResume
        cancelScrub(); performSeek(value, precise: true, resume: resume)
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, player.currentItem != nil else { return }
        let resume = scrubActive ? scrubResume : playing
        cancelScrub(); performSeek(boundedTime(seconds), precise: true, resume: resume)
    }
    private func boundedTime(_ seconds: Double) -> Double {
        let duration = player.currentItem?.duration.seconds ?? 0
        let upper = duration.isFinite && duration > 0 ? duration : end
        return upper > 0 ? min(max(0, seconds), upper) : max(0, seconds)
    }
    private func cancelScrub() {
        scrubTask?.cancel(); scrubTask = nil; pendingScrub = nil
        scrubActive = false; scrubResume = false
    }
    private func performSeek(_ seconds: Double, precise: Bool, resume: Bool) {
        guard let item = player.currentItem else { return }
        let value = boundedTime(seconds)
        time = value; seekRequest = UUID()
        let request = seekRequest, session = playbackSession
        isSeeking = true; seekIssuedCount += 1
        item.cancelPendingSeeks()
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.12, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.seekRequest == request, self.playbackSession == session else { return }
                self.isSeeking = false
                if finished && resume && !self.scrubActive && self.player.currentItem != nil {
                    self.player.play(); self.playing = true
                }
            }
        }
    }
    func toggle() {
        guard player.currentItem != nil, error == nil else { return }
        if playing {
            pause()
        } else {
            playing = true
            if time >= end || time < start { seek(start) } else { player.play() }
        }
    }
    func pause() {
        cancelScrub(); player.currentItem?.cancelPendingSeeks()
        seekRequest = UUID(); isSeeking = false
        player.pause(); playing = false
    }
    func stop(owner: String? = nil) {
        if let owner, ownerID != owner { return }
        attachedHosts.removeAll()
        stopCurrentPlayback()
    }

    private func stopCurrentPlayback() {
        playbackSession = UUID()
        cancelScrub(); player.currentItem?.cancelPendingSeeks()
        seekRequest = UUID(); isSeeking = false
        player.pause(); playing = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        if let observer { player.removeTimeObserver(observer) }; observer = nil
        statusObserver = nil
        player.replaceCurrentItem(with: nil)
        ownerID = nil
    }
}
