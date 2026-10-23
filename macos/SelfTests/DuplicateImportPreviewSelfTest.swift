import Foundation

@main
struct DuplicateImportPreviewSelfTest {
    static func main() async throws {
        let item = PendingImportItem(
            id: "incoming", stagedPath: "/nonexistent-duplicate-test/incoming.png",
            originalSourcePath: "/nonexistent-duplicate-test/incoming.png",
            originalFilename: "incoming.png", sourceFileID: "incoming-file", sourceFileSize: 10_000_000,
            sourceModifiedAt: .now, pixelWidth: 2538, pixelHeight: 4500,
            suggestedType: .person, category: .project, createdAt: .now
        )
        let candidate = DuplicateImportCandidate(existingPath: "/nonexistent-duplicate-test/existing.png", incomingItem: item)
        precondition(candidate.incomingPreviewAsset.isSourceMissing == nil, "对比预览不能同步探测磁盘")
        precondition(candidate.existingPreviewAsset.isSourceMissing == nil)
        precondition(item.previewAsset.sourceMissing, "其他调用仍保留原来的缺失检查语义")
        precondition(candidate.existingPreviewAsset.imagePath == candidate.existingPath)
        precondition(candidate.incomingPreviewAsset.imagePath == item.stagedPath)
        precondition(candidate.existingPreviewAsset.id != candidate.incomingPreviewAsset.id)
        precondition(candidate.existingPreviewAsset.pixelWidth == 2538)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("assetframe-duplicate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("duplicates.json")
        let writer = DuplicateImportQueueWriter()
        await writer.write(candidates: [candidate], to: manifest, revision: 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode([DuplicateImportCandidate].self, from: Data(contentsOf: manifest))
        precondition(restored.count == 1)
        precondition(restored[0].queueIdentity == candidate.queueIdentity)
        precondition(restored[0].incomingPath == candidate.incomingPath)
        print("DuplicateImportPreviewSelfTest passed")
    }
}
