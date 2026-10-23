import AppKit
import CoreServices
import Foundation

@MainActor
final class LinkedFolderEventMonitor {
    enum Cause: String, Sendable { case initial, filesystem, volume, periodic }
    let events: AsyncStream<Cause>
    private let continuation: AsyncStream<Cause>.Continuation
    private var stream: FSEventStreamRef?
    private var volumeObservers: [NSObjectProtocol] = []
    private var timer: Task<Void, Never>?
    private let sink: FolderEventSink
    private(set) var watching = false
    init(roots: [URL]) {
        let pair = AsyncStream<Cause>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream; continuation = pair.continuation
        sink = FolderEventSink(continuation: pair.continuation)
        let paths = roots.map { $0.standardizedFileURL.path }
        if !paths.isEmpty {
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(sink).toOpaque(),
                retain: { p in guard let p else { return nil }; _ = Unmanaged<FolderEventSink>.fromOpaque(p).retain(); return p },
                release: { p in if let p { Unmanaged<FolderEventSink>.fromOpaque(p).release() } }, copyDescription: nil)
            stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<FolderEventSink>.fromOpaque(info).takeUnretainedValue().continuation.yield(.filesystem)
            }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents))
            if let stream {
                FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "assetframe.folder-events", qos: .utility))
                watching = FSEventStreamStart(stream)
            }
        }
        let continuation = pair.continuation
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in continuation.yield(.volume) })
        }
        timer = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                continuation.yield(.periodic)
            }
        }
        continuation.yield(.initial)
    }
    func stop() {
        timer?.cancel(); timer = nil
        for observer in volumeObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        volumeObservers.removeAll()
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil; watching = false; continuation.finish()
    }
}

private final class FolderEventSink {
    let continuation: AsyncStream<LinkedFolderEventMonitor.Cause>.Continuation
    init(continuation: AsyncStream<LinkedFolderEventMonitor.Cause>.Continuation) { self.continuation = continuation }
}
