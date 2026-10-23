import AppKit
import Foundation

private struct StubVisionModelClient: VisionModelClient {
    func analyze(
        input: VisionAnalysisInput,
        configuration: VisionAPIConfiguration
    ) async throws -> PendingAIAnalysisSuggestion {
        if input.itemID == "FAIL" { throw VisionAPIClientError.httpStatus(429, "rate limited") }
        return PendingAIAnalysisSuggestion(
            itemID: input.itemID,
            proposedName: "古代红衣女性",
            assetType: .person,
            styleTags: ["红衣", "古装", "人物"],
            summary: "画面主体为红衣女性",
            confidence: 0.91,
            analyzedAt: .now,
            modelName: configuration.model,
            decision: .pending
        )
    }

    func testConnection(configuration: VisionAPIConfiguration) async throws {}
}

@main
struct VisionAPIClassificationSelfTest {
    @MainActor
    static func main() async throws {
        try testImagePreprocessing()
        try testResponseDecoding()
        try await testStoreClassificationAndPersistence()
        print("VisionAPIClassificationSelfTest passed")
    }

    private static func testImagePreprocessing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vision-preprocess-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePNG(to: url, width: 3_000, height: 1_000)
        let prepared = try VisionImagePreprocessor.prepare(atPath: url.path)
        precondition(max(prepared.pixelWidth, prepared.pixelHeight) == 1_280)
        precondition(prepared.mimeType == "image/jpeg")
        precondition(prepared.data.starts(with: [0xFF, 0xD8]))
        precondition(prepared.dataURL.hasPrefix("data:image/jpeg;base64,"))
    }

    private static func testResponseDecoding() throws {
        let content = """
        ```json
        {"itemID":"A","proposedName":" 红衣人物 ","assetType":"不存在类型","tags":["红衣","红衣","古装","人物","正面","室内","暖光","中景","多余"],"summary":"可见红衣人物","confidence":1.4}
        ```
        """
        let suggestion = try OpenAICompatibleVisionClient.decodeSuggestion(
            content,
            expectedItemID: "A",
            model: "deepseek-vision-test"
        )
        precondition(suggestion.assetType == .unclassified, "非法类型必须降级为待分类")
        precondition(suggestion.normalizedConfidence == 1)
        precondition(suggestion.normalizedTags.count == 8)
        precondition(suggestion.modelName == "deepseek-vision-test")
    }

    @MainActor
    private static func testStoreClassificationAndPersistence() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = fileManager.temporaryDirectory.appendingPathComponent("vision-source-\(UUID().uuidString).png")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writePNG(to: source, width: 400, height: 600)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: source)
        }

        let store = AssetStore(rootURL: root)
        await waitUntil { !store.isLoadingProject }
        store.pendingImports = [
            makeItem(id: "OK", path: source.path),
            makeItem(id: "FAIL", path: source.path),
            makeItem(id: "MANUAL", path: source.path, type: .scene)
        ]
        let configuration = VisionAPIConfiguration(
            baseURL: "https://example.com/v1",
            model: "deepseek-vision-test",
            apiKey: "not-a-real-key",
            timeoutSeconds: 30,
            batchSize: 2
        )
        store.startPendingAIClassification(
            ids: ["OK", "FAIL", "MANUAL"],
            configuration: configuration,
            client: StubVisionModelClient()
        )
        await waitUntil {
            guard let progress = store.pendingAIClassificationProgress else { return false }
            return progress.phase != .analyzing
        }
        precondition(store.pendingAIClassificationProgress?.succeeded == 1)
        precondition(store.pendingAIClassificationProgress?.failed == 1)
        precondition(store.pendingImport(withID: "MANUAL")?.aiVisionSuggestion == nil, "人工类型不得发送给 AI")
        precondition(store.pendingImport(withID: "OK")?.suggestedType == .unclassified, "AI 建议不得自动写入分类")

        precondition(store.applyPendingAISuggestions(["OK"]) == 1)
        let applied = store.pendingImport(withID: "OK")
        precondition(applied?.suggestedType == .person)
        precondition(applied?.name == "古代红衣女性")
        precondition(applied?.normalizedManualTags == ["人物", "古装", "红衣"])
        precondition(fileManager.fileExists(atPath: source.path), "采纳 AI 建议不得移动或删除原文件")

        await store.flushPendingImportManifest()
        let reopened = AssetStore(rootURL: root)
        await waitUntil { !reopened.isLoadingProject && reopened.pendingImports.count == 3 }
        precondition(reopened.pendingImport(withID: "OK")?.aiVisionSuggestion?.effectiveDecision == .applied)
    }

    private static func makeItem(id: String, path: String, type: AssetType = .unclassified) -> PendingImportItem {
        PendingImportItem(
            id: id,
            stagedPath: path,
            originalSourcePath: path,
            originalFilename: "\(id).png",
            sourceFileID: id,
            sourceFileSize: 8,
            sourceModifiedAt: nil,
            pixelWidth: 400,
            pixelHeight: 600,
            suggestedType: type,
            category: type == .unclassified ? .pending : .project,
            createdAt: .now
        )
    }

    private static func writePNG(to url: URL, width: Int, height: Int) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { fatalError("Unable to create test bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Unable to encode test PNG")
        }
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out waiting for vision API classification state")
    }
}
