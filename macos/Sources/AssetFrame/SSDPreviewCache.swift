import Foundation
import CryptoKit
import AppKit
import ImageIO

/// Rebuildable cache only. Never create a missing mount point or fall back to a source folder.
enum SSDPreviewCache {
    static let volume = URL(fileURLWithPath: "/Volumes/SSD-1TB", isDirectory: true)
    private static let scopeLock = NSLock()
    nonisolated(unsafe) private static var libraryScope = ""
    static func selectLibrary(_ id: String) {
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else { return }
        scopeLock.lock(); defer { scopeLock.unlock() }
        libraryScope = id + "/" + (UserDefaults.standard.string(forKey: "preview-generation-" + id) ?? "v1")
        let selectedRoot = baseRoot.appendingPathComponent(libraryScope)
        PreviewCacheBudget.shared.schedule(root: selectedRoot) { Self.root.path == selectedRoot.path }
    }
    static func clearLibrary(_ id: String) throws {
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else { throw CocoaError(.fileWriteInvalidFileName) }
        let generation = UUID().uuidString
        // Old generation remains recoverable; old writers cannot populate the new one.
        UserDefaults.standard.set(generation, forKey: "preview-generation-" + id)
        selectLibrary(id)
    }
    static func libraryRoot(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw CocoaError(.fileReadInvalidFileName) }
        let folder = baseRoot.appendingPathComponent(id)
        guard folder.resolvingSymlinksInPath().path == baseRoot.resolvingSymlinksInPath().appendingPathComponent(id).path else { throw CocoaError(.fileReadNoPermission) }
        return folder
    }
    /// Only obsolete app-generated cache generations, retaining the most recent previous one.
    static func pruneObsolete(_ id: String) throws -> Int {
        let folder = try libraryRoot(id)
        let current = UserDefaults.standard.string(forKey: "preview-generation-" + id) ?? "v1"
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return 0 }
        let candidates = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]).filter {
            let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return v?.isDirectory == true && v?.isSymbolicLink == false && $0.lastPathComponent != current && ($0.lastPathComponent == "v1" || UUID(uuidString: $0.lastPathComponent) != nil)
        }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for old in candidates.dropFirst() { try fm.removeItem(at: old) }
        return max(0, candidates.count - 1)
    }
    static var root: URL {
        scopeLock.lock(); let scope = libraryScope; scopeLock.unlock()
        return scope.isEmpty ? baseRoot : baseRoot.appendingPathComponent(scope)
    }
    private static var baseRoot: URL {
        if let raw = ProcessInfo.processInfo.environment["ASSETFRAME_QA_DATA_ROOT"],
           URL(fileURLWithPath: raw).lastPathComponent.hasPrefix("assetframe-qa."),
           ["/tmp", "/private/tmp", FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path].contains(URL(fileURLWithPath: raw).deletingLastPathComponent().resolvingSymlinksInPath().path) {
            return URL(fileURLWithPath: raw).appendingPathComponent("PreviewCache")
        }
        return volume.appendingPathComponent("Codex创作媒体库/99_可重建缓存/AssetFrame")
    }
    static func directory(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
    static func thumbnailKey(path: String, size: Int64, modified: Date?, pixels: Int) -> String {
        let raw = "\(path)|\(size)|\(modified?.timeIntervalSince1970 ?? 0)|\(pixels)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static let warmGate = DispatchSemaphore(value: 2)
    static func warmThumbnail(path: String, size: Int64, modified: Date?) {
        let folder = directory("Thumbnails")
        guard prepare(folder), !Task.isCancelled else { return }
        let file = folder.appendingPathComponent(thumbnailKey(path: path, size: size, modified: modified, pixels: 512) + ".png")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        warmGate.wait(); defer { warmGate.signal() }
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), prepare(folder) else { return }
        _ = write(data, to: file)
    }
    static func recordAccess(_ file: URL) {
        let selectedRoot = root
        PreviewCacheBudget.shared.touch(file, root: selectedRoot)
        PreviewCacheBudget.shared.schedule(root: selectedRoot) { Self.root.path == selectedRoot.path }
    }
    @discardableResult static func write(_ data: Data, to file: URL) -> Bool {
        let selectedRoot = root
        guard PreviewCacheBudget.recognized(file, root: selectedRoot), prepare(file.deletingLastPathComponent()) else { return false }
        let free = (try? selectedRoot.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
        let oldSize = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let budget = PreviewCacheBudget.shared
        budget.schedule(root: selectedRoot) { Self.root.path == selectedRoot.path }
        guard budget.allowWrite(bytes: data.count, file: file, root: selectedRoot, freeBytes: free, replacingBytes: oldSize) else { return false }
        guard root.path == selectedRoot.path, !Task.isCancelled,
              file.resolvingSymlinksInPath().path == selectedRoot.resolvingSymlinksInPath().appendingPathComponent(file.deletingLastPathComponent().lastPathComponent).appendingPathComponent(file.lastPathComponent).path else { return false }
        do { try data.write(to: file, options: .atomic); budget.didWrite(bytes: max(0, data.count - oldSize), root: selectedRoot); return true }
        catch { return false }
    }
    static func prepare(_ directory: URL) -> Bool {
        let fm = FileManager.default
        let resolvedRoot = root.resolvingSymlinksInPath().path
        guard directory.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot + "/") else { return false }
        if root.path.hasPrefix(volume.path + "/") {
            guard fm.mountedVolumeURLs(includingResourceValuesForKeys: nil)?.contains(where: {
                $0.standardizedFileURL.path == volume.path
            }) == true, resolvedRoot.hasPrefix(volume.path + "/") else { return false }
        }
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: true); return true }
        catch { return false }
    }
}
