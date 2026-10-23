import AppKit
import Foundation

private final class TaggingHTTPStub: URLProtocol, @unchecked Sendable {
    final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var requests: [URLRequest] = []
        var bodies: [Data] = []
        var status = 200
        func record(_ request: URLRequest) -> Int {
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
                }
            }
            lock.lock(); defer { lock.unlock() }; requests.append(request); bodies.append(bytes); return status
        }
        func reset(status: Int) { lock.lock(); defer { lock.unlock() }; requests = []; bodies = []; self.status = status }
        var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
        var body: Data? { lock.lock(); defer { lock.unlock() }; return bodies.last }
    }
    static let storage = Storage()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.storage.record(request)
        let content = "{\"materialID\":\"sample\",\"addTags\":[\"正面\"],\"removeTags\":[],\"categories\":{},\"uncertainties\":[]}"
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main struct MaterialTaggingSelfTest {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ASSETFRAME_QA_DATA_ROOT"]!)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("sample.png")
        let canvas = NSImage(size: NSSize(width: 800, height: 400))
        canvas.lockFocus(); NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 800, height: 400)).fill()
        ("TEA TEST" as NSString).draw(at: NSPoint(x: 100, y: 170), withAttributes: [.font: NSFont.systemFont(ofSize: 60), .foregroundColor: NSColor.black])
        canvas.unlockFocus()
        let bytes = NSBitmapImageRep(data: canvas.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try bytes.write(to: image)
        let digest = try MaterialTaggingState.fileDigest(image.path)
        let record = MaterialRecord(id: "sample", kind: .image, name: "样本", sourcePath: image.path,
            originalFilename: image.lastPathComponent, fingerprint: digest, sourceLocations: [image.path], fileSize: Int64(bytes.count),
            createdAt: .now, tags: ["保留"], rating: 3, note: "备注保持")
        let database = MaterialDatabase(root: root)
        let empty = try await database.load()
        try await database.commit(.init(materials: [record], links: []), previous: empty)
        let store = GlobalMaterialStore(rootURL: root)
        await store.waitUntilReady()
        precondition(store.materials.count == 1)

        let stable = store.tagging.catalogKey
        precondition((0..<20).allSatisfy { _ in store.tagging.catalogKey == stable }, "词表摘要必须稳定")
        var proposal = candidate(record, state: store.tagging)
        proposal.tags = ["新增标签"]; proposal.categories.set(["正面"], for: "shot")
        let initialProposal = proposal
        try await store.changeTagging { state, _ in state.proposals.append(initialProposal) }
        let reload = try await database.load()
        precondition(reload.tagging?.proposals.first?.tags == ["新增标签"], "只改候选也必须保存")
        try await store.acceptTagging(ids: [proposal.id])
        precondition(Set(store.materials[0].tags) == ["保留", "新增标签"])
        precondition(store.materials[0].note == "备注保持" && store.materials[0].rating == 3)
        precondition(store.tagging.proposals[0].status == "已确认")
        check(await store.undoEdit(), "采用可撤销")
        precondition(store.materials[0].tags == ["保留"] && store.tagging.proposals[0].status == "待确认", "字段与候选决定共同撤回")
        check(await store.undoEdit(redo: true), "redo failed: \(store.toast ?? "")")
        precondition(store.tagging.proposals[0].status == "已确认")
        log("PASS candidate-only persistence, atomic acceptance, undo/redo and preserved fields")

        let old = store.tagging
        do {
            try await store.changeTagging { state, records in
                state.sources.append(.init(name: "不应保存", path: "/invalid")); records[0].tags = ["不应保存"]
                throw MaterialDatabase.error("injected failure")
            }
            preconditionFailure("throw must rollback")
        } catch { }
        precondition(store.tagging == old && store.materials[0].tags.contains("保留"))

        var stale = candidate(record, state: store.tagging); stale.tags = ["不得采用"]
        let staleCandidate = stale
        try await store.changeTagging { state, _ in state.proposals.append(staleCandidate) }
        try Data("changed".utf8).write(to: image)
        try await store.acceptTagging(ids: [stale.id])
        precondition(store.tagging.proposals.first { $0.id == stale.id }?.status == "已过期")
        precondition(!store.materials[0].tags.contains("不得采用"))
        try bytes.write(to: image)
        log("PASS transaction failure rollback and stale image blocking")

        var custom = MaterialTaggingState.Term(name: "自定义茶罐", dimension: "entity", aliases: ["老陶罐"], scope: "茶商业")
        try await store.saveTaggingTerm(custom)
        let customName = custom.name
        try await store.changeTagging { _, records in records[0].mutateClassification { $0.add(customName, in: "entity") } }
        var filter = MaterialSearchFilter(); filter.search = "老陶罐"; filter.searchFields = [.classification]
        precondition(GlobalMaterialStore.query(store.materials, links: [], filter: filter, projectID: "", tagging: store.tagging).count == 1)
        let cache = MaterialTextSearchCache()
        let prepared = await cache.prepare(key: .init(libraryGeneration: "test", queryRevision: store.queryRevision, fields: [.classification], catalogKey: store.tagging.catalogKey),
            enabled: true, materials: store.materials, links: [], folders: [], tagging: store.tagging)
        precondition(prepared.index?.matches(record.id, words: ["老陶罐"]) == true)
        custom.name = "陈香茶罐"; try await store.saveTaggingTerm(custom)
        precondition(store.materials[0].classification?.contains("陈香茶罐", in: "entity") == true)
        check(await store.undoEdit(), "undo failed: \(store.toast ?? "")")
        precondition(store.materials[0].classification?.contains("自定义茶罐", in: "entity") == true)
        do {
            try await store.saveTaggingTerm(.init(name: "自定义茶罐", dimension: "entity", scope: "其他项目"))
            preconditionFailure("cannot ambiguously rename shared strings across scopes")
        } catch { }
        let target = MaterialTaggingState.Term(name: "合并目标", dimension: "entity", scope: "茶商业")
        try await store.saveTaggingTerm(target)
        custom.name = "自定义茶罐"
        try await store.saveTaggingTerm(custom, mergeInto: target.id)
        precondition(store.materials[0].classification?.contains("合并目标", in: "entity") == true)
        check(await store.undoEdit(), "undo failed: \(store.toast ?? "")")
        precondition(store.materials[0].classification?.contains("自定义茶罐", in: "entity") == true)
        log("PASS custom vocabulary aliases, cached search, rename/merge, undo and scope collision protection")
        // Legacy histories may have another JSON object key order. Their values still match.
        var categorized = record
        categorized.classification = .init(values: ["shot": ["正面"], "entity": ["自定义茶罐"]])
        let oldHistoryData = try JSONSerialization.data(withJSONObject: ["changes": [["id": record.id, "field": "categories",
            "before": Data("null".utf8).base64EncodedString(),
            "after": Data("{\"entity\":[\"自定义茶罐\"],\"shot\":[\"正面\"]}".utf8).base64EncodedString()]]])
        let oldPatch = try JSONDecoder().decode(MaterialUndoPatch.self, from: oldHistoryData)
        let restoredOld = try oldPatch.restore(in: [categorized])
        precondition(restoredOld[0].classification == nil)
        for _ in 0..<20 {
            let patch = try MaterialUndoPatch(before: [record], after: [categorized])
            let restored = try patch.restore(in: [categorized])
            precondition(restored[0].classification == nil)
            let repeated = try patch.inverse.restore(in: restored)
            precondition(repeated[0].classification == categorized.classification)
        }
        log("PASS canonical multi-dimension history and old unordered JSON undo compatibility")

        var removal = candidate(store.materials[0], state: store.tagging)
        removal.removeCategories = .init(values: ["entity": ["自定义茶罐"]])
        let removalProposal = removal
        try await store.changeTagging { state, _ in state.proposals.append(removalProposal) }
        do { try await store.acceptTagging(ids: [removal.id]); preconditionFailure("category deletion needs explicit confirmation") } catch { }
        try await store.acceptTagging(ids: [removal.id], allowConflicts: true)
        precondition(store.materials[0].classification?.contains("自定义茶罐", in: "entity") != true)
        check(await store.undoEdit(), "category removal undo")
        precondition(store.materials[0].classification?.contains("自定义茶罐", in: "entity") == true)
        let beforeFavorite = store.tagging.catalogKey
        var favorite = store.tagging.effectiveTerms[0]; favorite.favorite.toggle()
        try await store.saveTaggingTerm(favorite)
        precondition(store.tagging.catalogKey == beforeFavorite, "收藏只改变显示，不应使所有候选过期")
        log("PASS explicit multi-value category removal and undo; favorite-only edits preserve source validity")

        let docs = root.appendingPathComponent("资料", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let md = docs.appendingPathComponent("提示词.md")
        try "# 原始提示词\n正面半身，室内，柔光。\n禁止水印、现代物品。\n![样本](\(image.path))\n".write(to: md, atomically: true, encoding: .utf8)
        try await store.changeTagging { state, _ in state.sources.append(.init(name: "测试项目", path: docs.path, scope: "古装短剧")) }
        let state = store.tagging
        let analysis = try await Task.detached { try MaterialTaggingAnalyzer.analyze(record: record, state: state, links: []) }.value
        precondition(analysis.categories.contains("正面", in: "shot"))
        precondition(!analysis.tags.contains("水印") && !analysis.categories.contains("现代", in: "theme"))
        var negated = analysis; negated.categories = .init(); negated.tags = []
        MaterialTaggingAnalyzer.extract(text: "静态核对：构图与无人物等硬项通过。", terms: state.effectiveTerms, scopes: ["古装短剧"], into: &negated)
        precondition(!negated.categories.contains("人物角色", in: "asset_type"), "无人物不能成为人物标签")
        precondition(analysis.evidence.contains { $0.path == md.path })
        precondition(state.isCurrent(analysis, material: record, links: []))
        try "新增资料".write(to: docs.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        precondition(!state.isCurrent(analysis, material: record, links: []), "目录变化必须使候选过期")
        try fm.removeItem(at: docs.appendingPathComponent("new.md"))
        var changedRecord = record; changedRecord.production = MaterialProductionMetadata(); changedRecord.production?.prompt = "新提示词"
        precondition(!state.isCurrent(analysis, material: changedRecord, links: []), "从空提示词变为非空必须使候选过期")
        let two = "# 两张图\n正面室内\n![A](\(image.path))\n![B](/elsewhere/other.png)"
        precondition(MaterialTaggingAnalyzer.relevantExcerpt(two, imagePath: image.path, documentPath: md.path, imageCount: 2, explicitlyBound: false) == nil)
        let response = "{\"materialID\":\"sample\",\"addTags\":[],\"removeTags\":[\"错误建议\"],\"categories\":{},\"uncertainties\":[]}"
        _ = try MaterialTaggingAIClient.decode(response, record: record, state: state, proposalTags: ["错误建议"])
        do {
            _ = try MaterialTaggingAIClient.decode("{\"materialID\":\"foreign\",\"addTags\":[],\"removeTags\":[],\"categories\":{},\"uncertainties\":[]}", record: record, state: state)
            preconditionFailure("foreign ID must fail")
        } catch { }
        log("PASS real local Vision/OCR, explicit document linking, negative/multi-image guards, document and link invalidation, AI decoding")

        let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [TaggingHTTPStub.self]
        let testSession = URLSession(configuration: sessionConfig)
        let config = MaterialTaggingAIClient.Configuration(baseURL: "https://example.invalid/v1", model: "qa-only", apiKey: "qa-only", timeout: 10)
        TaggingHTTPStub.storage.reset(status: 200)
        let corrected = try await MaterialTaggingAIClient.correct(record: record, proposal: analysis, state: state, mode: "文本", links: [], configuration: config, session: testSession)
        precondition(corrected.status == "待确认" && corrected.id != analysis.id && corrected.baseInputKey == analysis.inputKey)
        precondition(TaggingHTTPStub.storage.count == 1)
        let textBody = String(decoding: TaggingHTTPStub.storage.body!, as: UTF8.self)
        precondition(!textBody.contains("image_url") && !textBody.contains("data:image"))
        var priorDeletion = analysis
        priorDeletion.removeTags = ["保留"]
        priorDeletion.removeCategories = .init(values: ["shot": ["背面"]])
        var deletionRecord = record; deletionRecord.classification = .init(values: ["shot": ["背面"]])
        let correctedAgain = try await MaterialTaggingAIClient.correct(record: deletionRecord, proposal: priorDeletion, state: state,
            mode: "文本", links: [], configuration: config, session: testSession)
        precondition(correctedAgain.removeTags == ["保留"] && correctedAgain.removeCategories?.contains("背面", in: "shot") == true,
                     "再次AI校正不能静默丢掉此前删除建议")
        TaggingHTTPStub.storage.reset(status: 200)
        _ = try await MaterialTaggingAIClient.correct(record: record, proposal: analysis, state: state, mode: "看图", links: [], configuration: config, session: testSession)
        precondition(TaggingHTTPStub.storage.count == 1 && String(decoding: TaggingHTTPStub.storage.body!, as: UTF8.self).contains("image_url"))
        TaggingHTTPStub.storage.reset(status: 500)
        do {
            _ = try await MaterialTaggingAIClient.correct(record: record, proposal: analysis, state: state, mode: "文本", links: [], configuration: config, session: testSession)
            preconditionFailure("server failure must surface")
        } catch { }
        precondition(TaggingHTTPStub.storage.count == 1, "失败不得自动重试")
        log("PASS stubbed text/vision payloads, pending-only AI result and exactly one request on HTTP failure; no external API used")

        var confirmedPartial = analysis; confirmedPartial.status = "已确认"; confirmedPartial.error = "模拟部分识别失败"
        let oldPartial = confirmedPartial
        try await store.changeTagging { state, _ in
            state.proposals.append(oldPartial)
            state.jobs.append(.init(materialIDs: [record.id], failed: [record.id], status: "已完成"))
        }
        let controller = MaterialTaggingController(store: store)
        controller.start(ids: [record.id], retryFailed: true)
        let deadline = Date().addingTimeInterval(60)
        while controller.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        precondition(!controller.busy && controller.issue == nil)
        precondition(store.tagging.proposals.contains { $0.id == oldPartial.id && $0.status == "已确认" })
        precondition(store.tagging.proposals.contains { $0.materialID == record.id && $0.id != oldPartial.id && $0.status == "待确认" },
                     "显式重试应真正识别并生成新候选，保留旧人工决定")
        log("PASS explicit retry of confirmed partial result creates fresh candidate and preserves prior decision")

        let backup = root.appendingPathComponent("tagging-backup.sqlite")
        try await database.backup(to: backup)
        let saved = try await database.load()
        let restoreRoot = root.appendingPathComponent("restore", isDirectory: true)
        let restoreDB = MaterialDatabase(root: restoreRoot)
        try await restoreDB.restore(from: backup)
        let restored = try await restoreDB.load()
        precondition(restored.tagging == saved.tagging && restored.materials == saved.materials)
        let reopened = GlobalMaterialStore(rootURL: root); await reopened.waitUntilReady()
        // SQLite preserves row identity/content, not array insertion order after undo/merge.
        func ordered(_ value: MaterialTaggingState) -> MaterialTaggingState {
            var result = value
            result.terms.sort { $0.id < $1.id }; result.sources.sort { $0.id < $1.id }
            result.bindings.sort { $0.id < $1.id }; result.proposals.sort { $0.id < $1.id }; result.jobs.sort { $0.id < $1.id }
            return result
        }
        precondition(ordered(reopened.tagging) == ordered(store.tagging), "all persisted rows must match after reopen")
        log("PASS restart and SQLite backup/restore including candidates, vocabulary and history")
        log("MaterialTaggingSelfTest passed")
    }

    static func check(_ condition: Bool, _ message: String = "check failed", line: Int = #line) { precondition(condition, "line \(line): " + message) }
    static func log(_ message: String) { FileHandle.standardOutput.write(Data((message + "\n").utf8)) }

    static func candidate(_ record: MaterialRecord, state: MaterialTaggingState) -> MaterialTaggingState.Proposal {
        var value = MaterialTaggingState.Proposal(materialID: record.id, inputKey: UUID().uuidString, imagePath: record.sourcePath!,
            imageDigest: try! MaterialTaggingState.fileDigest(record.sourcePath!), catalogKey: state.catalogKey, relationKey: state.relationKey)
        value.evidence = [.init(kind: "素材生成提示词", digest: MaterialTaggingState.digest(Data((record.production?.prompt ?? "").utf8))),
                          .init(kind: "素材关联快照", digest: MaterialTaggingState.linkDigest([]))]
        return value
    }
}
