import Foundation

@main
struct MaterialImportPerformanceSelfTest {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assetframe-import-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var urls: [URL] = []
        for i in 0..<130 {
            let url = root.appendingPathComponent("\(i).txt")
            try Data((String(repeating: "asset", count: 200) + "\(i)").utf8).write(to: url)
            urls.append(url)
        }
        let store = GlobalMaterialStore(rootURL: root.appendingPathComponent("index"))
        await store.waitUntilReady()
        let start = Date()
        store.importFiles(urls)
        while store.isImporting { try await Task.sleep(for: .milliseconds(5)) }
        let elapsed = Date().timeIntervalSince(start)
        precondition(store.materials.count == 130)
        precondition(store.importResults.count == 130)
        let beforeRevision = store.revision
        let repeated = Date()
        store.importFiles(urls)
        while store.isImporting { try await Task.sleep(for: .milliseconds(5)) }
        precondition(store.materials.count == 130)
        precondition(store.importRead == 0, "来源路径、大小和修改时间未变化时不应再次读取并哈希文件")
        precondition(store.importDuplicate == 130)
        precondition(store.importAdded == 0)
        print("Import benchmark: new_130_ms=\(elapsed * 1000), repeat_130_ms=\(Date().timeIntervalSince(repeated) * 1000), new_revisions=\(beforeRevision), repeat_revisions=\(store.revision - beforeRevision)")
        #if OPTIMIZED_IMPORT
        precondition(store.revision == beforeRevision, "重复导入不得无变化保存并触发全库刷新")
        precondition(beforeRevision <= 7, "130 个文件至多分六批提交，加一次初始加载")
        #endif
    }
}
