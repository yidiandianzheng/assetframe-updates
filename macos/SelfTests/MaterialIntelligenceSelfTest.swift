import Foundation
import AppKit

private final class ComparisonProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
            }
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let parts = messages[1]["content"] as! [[String: Any]]
            precondition(parts.filter { $0["type"] as? String == "image_url" }.count == 2, "Comparison must transmit both images")
            let text = parts.first?["text"] as! String
            precondition(!text.contains("/tmp/") && !text.contains("private"), "Comparison may not send filesystem paths")
            let content = "{\"differences\":[\"测试响应：背景不同\"],\"uncertainties\":[\"小字待核对\"]}"
            let output = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: output); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@main struct MaterialIntelligenceSelfTest {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ASSETFRAME_QA_DATA_ROOT"]!)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("tea.png")
        let canvas = NSImage(size: NSSize(width: 1000, height: 500))
        canvas.lockFocus()
        NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1000, height: 500)).fill()
        ("TEA ASSET TEST" as NSString).draw(at: NSPoint(x: 100, y: 220), withAttributes: [.font: NSFont.systemFont(ofSize: 72), .foregroundColor: NSColor.black])
        canvas.unlockFocus()
        try NSBitmapImageRep(data: canvas.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: image)
        let hash = GlobalMaterialStore.streamFingerprint(image)!
        let originalData = try Data(contentsOf: image)
        let a = MaterialRecord(id: "a", kind: .image, name: "院子", sourcePath: image.path,
            originalFilename: "tea.png", fingerprint: hash, contentFingerprint: hash, sourceLocations: [image.path],
            fileSize: Int64(originalData.count), mediaMetadata: .init(pixelWidth: 1000, pixelHeight: 500), createdAt: .now,
            tags: ["院子", "人物", "保留标签"], rating: 4, note: "")
        var b = a; b.id = "b"; b.tags = ["院子", "无人"]; b.name = "院子空景"
        var deleted = a; deleted.id = "deleted"; deleted.deletedAt = .now
        let intent = try MaterialIntent.decode("{\"concepts\":[[\"庭院\",\"院子\"]],\"excluding\":[\"人物\"],\"kind\":\"图片\",\"orientation\":\"横屏\",\"minimumRating\":3}")
        precondition(intent.search([a,b,deleted]).map(\.id) == ["b"])
        precondition(MaterialIntent.local("找横屏的院子图片").search([a,b,deleted]).count == 2)
        let compound = MaterialIntent.local("找横屏的茶叶包装图片")
        precondition(compound.concepts.flatMap { $0 }.joined().contains("包装"), "Trailing Chinese keyword lost")
        for invalid in ["{}", "{\"concepts\":[[]],\"excluding\":[]}", "{\"concepts\":[],\"excluding\":[],\"kind\":\"BAD\"}", "{\"concepts\":[],\"excluding\":[],\"minimumRating\":6}"] {
            do { _ = try MaterialIntent.decode(invalid); preconditionFailure("Invalid query accepted") } catch { }
        }
        fflush(nil); print("PASS: query synonyms, negation, rating, orientation, deleted exclusion, local Chinese tokenization and malformed response rejection")
        let groups = MaterialVersionDifference.grouped([
            .init(id: "1", materialIDs: ["a","b"], reason: ""), .init(id: "2", materialIDs: ["c","d"], reason: ""),
            .init(id: "3", materialIDs: ["b","c"], reason: ""), .init(id: "4", materialIDs: ["x","y"], reason: "")])
        precondition(groups.count == 2 && groups[0].materialIDs == ["a","b","c","d"])
        precondition(MaterialVersionDifference.describe(a,b).contains { $0.contains("标签") })
        precondition(MaterialSimilarityScan.scan([a,b,deleted], includeVisual: true).groups.contains { $0.materialIDs == ["a", "b"] })
        let visual = MaterialVisualSimilarity.scan([a,b,deleted])
        precondition(visual.featureImages == 2 && visual.groups.count == 1)
        fflush(nil); print("PASS: real Vision image features, similarity scan, connected candidate grouping, deterministic field differences")
        let source = try MaterialAnalysisSource.capture(a)
        let local = try await Task.detached { try MaterialLocalTags.analyze(a) }.value
        precondition(local.tags.contains { $0.contains("TEA") }, "Actual OCR failed on synthetic fixture")
        let afterSource = try MaterialAnalysisSource.capture(a); precondition(afterSource == source)
        fflush(nil); print("PASS: real Apple Vision/OCR on synthetic image; tags=\(local.tags)")
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ComparisonProtocol.self]
        let response = try await OpenAICompatibleVisionClient(session: URLSession(configuration: configuration)).compare(paths: [image.path,image.path], configuration: .init(baseURL: "https://example.invalid/v1", model: "test-only", apiKey: "test-only", timeoutSeconds: 20, batchSize: 1))
        precondition(response.differences.count == 1 && response.uncertainties.count == 1)
        do { _ = try OpenAICompatibleVisionClient.decodeComparison("{\"differences\":[\"\"],\"uncertainties\":[]}"); preconditionFailure() } catch { }
        fflush(nil); print("PASS: two-image HTTP contract with URLProtocol stub; no external API request")
        let db = MaterialDatabase(root: root.appendingPathComponent("library"))
        let empty = try await db.load()
        let link = ProjectMaterialLink(id: "fixed", projectID: "project", materialID: "a", use: .candidate, selection: "选用", createdAt: .now, boundFingerprint: hash)
        try await db.commit(.init(materials: [a,b], links: [link]), previous: empty)
        let store = GlobalMaterialStore(rootURL: db.root, managedRoot: root.appendingPathComponent("managed"))
        await store.waitUntilReady()
        store.batchUpdate(["a"]) { $0.tags = Array(Set($0.tags + local.tags)).sorted() }
        try await store.saveNow().get()
        precondition(store.materials.first { $0.id == "a" }!.tags.contains("保留标签"))
        let undo = await store.undoEdit(); precondition(undo); precondition(store.materials.first { $0.id == "a" }!.tags == a.tags)
        store.setVersion("b", relativeTo: "a"); try await store.saveNow().get()
        precondition(store.links == [link] && store.materials.allSatisfy { ($0.production?.versionGroupID ?? $0.id) == "a" })
        let backup = root.appendingPathComponent("backup.sqlite")
        try await db.backup(to: backup)
        store.update("a") { $0.name = "changed" }; try await store.saveNow().get()
        _ = await store.pauseSession()
        try await db.restore(from: backup)
        let restored = try await db.load()
        precondition(restored.materials.first { $0.id == "a" }?.name == a.name && restored.links == [link])
        let out = try MaterialDelivery.export(materials: restored.materials, links: restored.links, projectID: "project", destination: root)
        precondition(fm.fileExists(atPath: out.appendingPathComponent("生产素材清单.csv").path))
        let unchanged = try Data(contentsOf: image); precondition(unchanged == originalData)
        let moved = root.appendingPathComponent("moved.png"); try fm.moveItem(at: image, to: moved)
        precondition((try? MaterialAnalysisSource.capture(a)) == nil)
        let reopened = GlobalMaterialStore(rootURL: db.root, managedRoot: root.appendingPathComponent("managed"))
        await reopened.waitUntilReady()
        try await reopened.relocate("a", to: moved); try await reopened.saveNow().get()
        precondition(reopened.materials.first { $0.id == "a" }?.sourcePath == moved.path && reopened.links == [link])
        let movedData = try Data(contentsOf: moved); precondition(movedData == originalData)
        fflush(nil); print("PASS: additive tags, undo, version grouping preserves fixed links, SQLite backup/restore, original-file delivery, relocated source and stale proposal rejection")
        _ = await reopened.pauseSession()
    }
}
