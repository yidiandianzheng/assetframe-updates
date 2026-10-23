import Foundation
import Combine

@main
struct StreamingImportSelfTest {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("assetframe-streaming-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture")
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        for i in 0..<300 { try png.write(to: fixture.appendingPathComponent("\(i).png")) }
        let scanner = ImportDirectoryScanner(urls: [fixture])
        var total = 0
        var first = true
        while true {
            let batch = await scanner.next(first: first)
            precondition(batch.files.count <= (first ? 32 : 128))
            precondition(batch.files.count + batch.directories.count <= 256)
            total += batch.files.count
            first = false
            if batch.finished { break }
        }
        precondition(total == 300)
        let receiver = ProgressReceiver()
        let relay = ImportProgressRelay<Int> { await receiver.accept($0) }
        for i in 1...1000 { relay.submit(i) }
        try await Task.sleep(for: .milliseconds(100))
        let latest = await receiver.latest
        precondition(latest == 1000, "进度投递必须保留最新样本")
        let controller = ImportProgressController()
        let jobID = UUID()
        controller.replace(with: ImportProgressState(id: jobID, phase: .completed, total: 1, processed: 1, imported: 1, skipped: 0, currentFilename: "完成"))
        controller.replace(with: ImportProgressState(id: jobID, phase: .scanning, total: 0, processed: 0, imported: 0, skipped: 0, currentFilename: "旧进度"))
        precondition(controller.state?.phase == .completed)
        let writer = PendingImportManifestWriter()
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let saved = await writer.write(items: [], root: blocked, directoryName: "pending", manifestName: "test.json", revision: 1)
        precondition(!saved, "不可写目录不得报告保存成功")
        let materialStore = GlobalMaterialStore(rootURL: root.appendingPathComponent("material-state"))
        await materialStore.waitUntilReady()
        var changes = 0
        let subscription = materialStore.objectWillChange.sink { changes += 1 }
        for i in 0..<1000 { materialStore.importController.importProcessed = i }
        precondition(changes == 0)
        withExtendedLifetime(subscription) {}

        materialStore.importFiles([fixture])
        let firstJobID = materialStore.importController.job?.id
        let importDeadline = Date.now.addingTimeInterval(30)
        while materialStore.isImporting {
            if let resume = materialStore.resumableImport {
                precondition(resume.id == firstJobID, "Progress and recovery must identify the same import job")
            }
            precondition(Date.now < importDeadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(materialStore.materials.count == 300 && materialStore.resumableImport == nil)
        materialStore.cancelBackgroundMetadata()

        if let fileList = ProcessInfo.processInfo.environment["ASSETFRAME_REAL_FILE_LIST"] {
            let paths = try String(contentsOfFile: fileList, encoding: .utf8).split(separator: "\n").map(String.init)
            for count in [1000, 5000, 6619, 10000] where paths.count >= count {
                let urls = paths.prefix(count).map(URL.init(fileURLWithPath:))
                let store = GlobalMaterialStore(rootURL: root.appendingPathComponent("material-\(count)"))
                await store.waitUntilReady()
                let start = Date.now
                store.importFiles(urls)
                let response = Date.now.timeIntervalSince(start)
                var firstPublished: Double?
                while store.isImporting {
                    if firstPublished == nil && !store.materials.isEmpty { firstPublished = Date.now.timeIntervalSince(start) }
                    try await Task.sleep(for: .milliseconds(5))
                    precondition(Date.now.timeIntervalSince(start) < 180)
                }
                let elapsed = Date.now.timeIntervalSince(start)
                precondition(store.materials.count == count)
                let repeated = Date.now
                store.importFiles(urls)
                while store.isImporting { try await Task.sleep(for: .milliseconds(5)) }
                let repeatTime = Date.now.timeIntervalSince(repeated)
                precondition(store.importDuplicate == count)
                print("REAL material count=\(count) response_ms=\(response * 1000) first_published_s=\(firstPublished ?? elapsed) total_s=\(elapsed) repeated_s=\(repeatTime)")
                // Stop background content reads when moving to the next isolated library.
                store.cancelBackgroundMetadata()
                let projectStore = AssetStore(rootURL: root.appendingPathComponent("project-\(count)"))
                while projectStore.isLoadingProject { try await Task.sleep(for: .milliseconds(5)) }
                let projectStart = Date.now
                projectStore.stageImages(urls)
                var projectFirst: Double?
                while projectStore.isImporting {
                    if projectFirst == nil && !projectStore.pendingImports.isEmpty { projectFirst = Date.now.timeIntervalSince(projectStart) }
                    try await Task.sleep(for: .milliseconds(5))
                    precondition(Date.now.timeIntervalSince(projectStart) < 180)
                }
                let projectElapsed = Date.now.timeIntervalSince(projectStart)
                precondition(projectStore.pendingImports.count == count)
                let projectRepeat = Date.now
                projectStore.stageImages(urls)
                while projectStore.isImporting { try await Task.sleep(for: .milliseconds(5)) }
                let projectRepeatElapsed = Date.now.timeIntervalSince(projectRepeat)
                precondition(projectStore.importProgress?.skipped == count)
                projectStore.cancelBackgroundMetadata()
                print("REAL project count=\(count) first_published_s=\(projectFirst ?? projectElapsed) total_s=\(projectElapsed) repeated_s=\(projectRepeatElapsed)")
                if count == 6619 {
                    precondition(elapsed < 30 && repeatTime < 10)
                    precondition(projectElapsed < 30 && projectRepeatElapsed < 10)
                }
            }
        }
        print("StreamingImportSelfTest passed")
    }
}

private actor ProgressReceiver {
    var latest = 0
    func accept(_ value: Int) { latest = value }
}
