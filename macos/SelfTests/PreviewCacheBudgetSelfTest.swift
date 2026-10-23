import Foundation

@main struct PreviewCacheBudgetSelfTest {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("assetframe-qa.budget-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("ScreenPreviews")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        func file(_ key: String, date: TimeInterval) throws -> URL {
            let url = folder.appendingPathComponent(String(repeating: key, count: 64)+".png")
            try Data(repeating: 1, count: 100).write(to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: url.path)
            return url
        }
        let cold = try file("a", date: 1), hot = try file("b", date: 2)
        let original = folder.appendingPathComponent("user-original.png")
        try Data(repeating: 4, count: 400).write(to: original)
        let outside = root.appendingPathComponent("outside.png")
        try Data(repeating: 5, count: 500).write(to: outside)
        let link = folder.appendingPathComponent(String(repeating: "c", count: 64)+".png")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let budget = PreviewCacheBudget(byteBudget: 150, reserveBytes: 200)
        let result = budget.maintain(root: root)
        precondition(result.observedBytes == 100 && result.removedFiles == 1)
        precondition(!fm.fileExists(atPath: cold.path) && fm.fileExists(atPath: hot.path))
        let originalBytes = try Data(contentsOf: original); precondition(originalBytes.count == 400)
        let outsideBytes = try Data(contentsOf: outside); precondition(outsideBytes.count == 500)
        precondition(!budget.allowWrite(bytes: 40, file: hot, root: root, freeBytes: 220), "Reserve prevents writes before disk is full")
        precondition(budget.allowWrite(bytes: 40, file: hot, root: root, freeBytes: 1000))
        precondition(!budget.allowWrite(bytes: 151, file: hot, root: root, freeBytes: nil))
        precondition(!budget.allowWrite(bytes: 1, file: original, root: root, freeBytes: nil))
        let untouched = PreviewCacheBudget(byteBudget: 0, reserveBytes: 0)
        _ = untouched.maintain(root: root, isCurrent: { false })
        precondition(fm.fileExists(atPath: hot.path), "No removal after library generation changes")
        let linkedCategory = root.appendingPathComponent("MediaThumbnails")
        try fm.createSymbolicLink(at: linkedCategory, withDestinationURL: folder)
        let second = budget.maintain(root: root)
        precondition(second.observedBytes == 100, "Symlinked categories are not double counted or traversed")
        print("PreviewCacheBudgetSelfTest passed: budget, oldest eviction, disk reserve, source protection, symlinks, inactive generation")
    }
}
