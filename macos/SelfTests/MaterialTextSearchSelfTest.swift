import Foundation

@main struct MaterialTextSearchSelfTest {
    @MainActor static func main() async throws {
        let seed = MaterialRecord(id: "hero", kind: .image, name: "山河 CAFÉ", sourcePath: "/库/人物/分镜/a.PNG",
            sourceURL: "https://example.com/reference", originalFilename: "landscape.PNG", fingerprint: "a",
            sourceLocations: [], fileSize: 100, mediaMetadata: MaterialMediaMetadata(pixelWidth: 800, pixelHeight: 1200),
            production: MaterialProductionMetadata(purpose: "人物", versionName: "v02", prompt: "暖色灯光", platform: "模型平台", model: "model", batch: "batch"),
            createdAt: Date(timeIntervalSince1970: 10), tags: ["古风", "参考"], rating: 4, note: "夜景")
        var sibling = seed; sibling.id = "sibling"; sibling.name = "别处"; sibling.sourcePath = "/库/人物2/other.png"; sibling.tags = []; sibling.note = ""; sibling.production = nil; sibling.sourceURL = nil
        var deleted = seed; deleted.id = "deleted"; deleted.deletedAt = .now
        let items = [seed, sibling, deleted]
        let link = ProjectMaterialLink(id: "link", projectID: "p", materialID: seed.id, use: .working, episode: "第2集", scene: "场景3", shot: "镜头18", selection: "选用", createdAt: .now, note: "使用备注")
        let folder = LocalFolderSource(id: "f", name: "角色素材", rootPath: "/库/人物", bookmarkData: nil, directoryPaths: [], createdAt: .now)
        let cache = MaterialTextSearchCache()
        let all = Set(MaterialSearchField.allCases)
        let base = MaterialTextSearchCache.Key(libraryGeneration: "A", queryRevision: 1, fields: all)
        let initial = await cache.prepare(key: base, enabled: false, materials: items, links: [link], folders: [folder])
        precondition(initial.index == nil && initial.diagnostics.buildCount == 0, "Empty search must not build")
        let first = await cache.prepare(key: base, enabled: true, materials: items, links: [link], folders: [folder])
        precondition(first.index != nil && !first.diagnostics.cacheHit && first.diagnostics.buildCount == 1)
        for query in ["山河 古风 镜头18", "CAFÉ", "café", "暖色", "第2集", "角色素材", "example.com", "夜景", "PNG", "不存在", "  "] {
            var filter = MaterialSearchFilter(); filter.search = query
            let expected = GlobalMaterialStore.query(items, links: [link], filter: filter, projectID: "p", folders: [folder]).map(\.id)
            let actual = GlobalMaterialStore.query(items, links: [link], filter: filter, projectID: "p", folders: [folder], searchIndex: first.index).map(\.id)
            precondition(actual == expected, "Indexed text must preserve membership and sort: \(query)")
        }
        var positive = MaterialSearchFilter(); positive.search = "山河 古风 镜头18"
        precondition(GlobalMaterialStore.query(items, links: [link], filter: positive, projectID: "p", searchIndex: first.index).map(\.id) == [seed.id])
        positive.search = "角色素材"; positive.searchFields = [.folder]
        precondition(GlobalMaterialStore.query(items, links: [], filter: positive, projectID: "", folders: [folder]).map(\.id) == [seed.id], "Folder prefix boundary")
        for mask in 0..<(1 << MaterialSearchField.allCases.count) {
            let fields = Set(MaterialSearchField.allCases.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil })
            var key = base; key.fields = fields
            let prepared = await cache.prepare(key: key, enabled: true, materials: items, links: [link], folders: [folder])
            for term in ["山河 古风", "模型平台", "夜景", "参考", "镜头18", "角色素材", "PNG"] {
                var filter = MaterialSearchFilter(); filter.searchFields = fields; filter.search = term
                let raw = GlobalMaterialStore.query(items, links: [link], filter: filter, projectID: "p", folders: [folder]).map(\.id)
                let indexed = GlobalMaterialStore.query(items, links: [link], filter: filter, projectID: "p", folders: [folder], searchIndex: prepared.index).map(\.id)
                precondition(raw == indexed, "Field scope leakage: \(mask) \(term)")
            }
        }
        let scopeCache = MaterialTextSearchCache()
        let cached = await scopeCache.prepare(key: base, enabled: true, materials: items, links: [link], folders: [folder])
        let reuse = await scopeCache.prepare(key: base, enabled: true, materials: items, links: [link], folders: [folder])
        precondition(reuse.diagnostics.cacheHit && reuse.diagnostics.buildCount == cached.diagnostics.buildCount)
        var changed = seed; changed.name = "新名字"; changed.tags = ["新标签"]
        var nextKey = base; nextKey.queryRevision += 1
        let updated = await scopeCache.prepare(key: nextKey, enabled: true, materials: [changed, sibling], links: [], folders: [])
        precondition(updated.index?.matches(seed.id, words: ["新名字", "新标签"]) == true)
        precondition(updated.index?.matches(seed.id, words: ["山河"]) == false)
        precondition(updated.diagnostics.incremental && updated.diagnostics.normalizedRecordCount == 1 && updated.diagnostics.reusedRecordCount == 1)
        precondition(updated.index?.texts[deleted.id] == nil, "Removed items must leave the incremental index")
        precondition(cached.index?.matches(seed.id, words: ["山河"]) == true, "Previously published snapshot remains immutable")
        var reorderedKey = nextKey; reorderedKey.queryRevision += 1
        let reordered = await scopeCache.prepare(key: reorderedKey, enabled: true, materials: [sibling, changed], links: [], folders: [])
        precondition(reordered.diagnostics.normalizedRecordCount == 0 && reordered.diagnostics.reusedRecordCount == 2)
        let dependentCache = MaterialTextSearchCache()
        _ = await dependentCache.prepare(key: base, enabled: true, materials: items, links: [link], folders: [folder])
        var renamedFolder = folder; renamedFolder.name = "新文件夹"
        var changedLink = link; changedLink.note = "新引用备注"
        var dependencyKey = base; dependencyKey.queryRevision += 1
        let dependent = await dependentCache.prepare(key: dependencyKey, enabled: true, materials: items, links: [changedLink], folders: [renamedFolder])
        precondition(dependent.index?.matches(seed.id, words: ["新文件夹", "新引用备注"]) == true)
        precondition(dependent.index?.matches(seed.id, words: ["角色素材"]) == false)
        precondition(dependent.diagnostics.normalizedRecordCount == 2 && dependent.diagnostics.reusedRecordCount == 1, "Linked fields and folder names invalidate only affected raw components")
        nextKey.libraryGeneration = "B"
        var otherLibrary = changed; otherLibrary.name = "另一个库"
        let switched = await scopeCache.prepare(key: nextKey, enabled: true, materials: [otherLibrary], links: [], folders: [])
        precondition(switched.index?.matches(seed.id, words: ["另一个库"]) == true, "Same ID across libraries must not reuse stale text")
        nextKey.localeIdentifier = "new-locale"
        let relocalized = await scopeCache.prepare(key: nextKey, enabled: true, materials: [otherLibrary], links: [], folders: [])
        precondition(relocalized.diagnostics.buildCount == switched.diagnostics.buildCount + 1)
        let bounded = MaterialTextSearchCache(byteBudget: 1)
        let refused = await bounded.prepare(key: base, enabled: true, materials: items, links: [], folders: [])
        let repeated = await bounded.prepare(key: base, enabled: true, materials: items, links: [], folders: [])
        precondition(refused.index == nil && repeated.diagnostics.fallbackReason == "byte_budget" && repeated.diagnostics.buildCount == 1, "Do not retry refused budget on every query")
        let limited = await MaterialTextSearchCache(recordLimit: 1).prepare(key: base, enabled: true, materials: items, links: [], folders: [])
        precondition(limited.index == nil && limited.diagnostics.fallbackReason == "record_limit")
        let duplicate = await MaterialTextSearchCache().prepare(key: base, enabled: true, materials: [seed, seed], links: [], folders: [])
        precondition(duplicate.index == nil && duplicate.diagnostics.fallbackReason == "duplicate_id")
        let cancelCache = MaterialTextSearchCache()
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            return await cancelCache.prepare(key: base, enabled: true, materials: items, links: [], folders: [])
        }
        cancelled.cancel()
        let cancelledValue = await cancelled.value
        precondition(cancelledValue.index == nil && cancelledValue.diagnostics.buildCount == 0)
        let recovered = await cancelCache.prepare(key: base, enabled: true, materials: items, links: [], folders: [])
        precondition(recovered.index != nil && recovered.diagnostics.buildCount == 1)
        var checks = 0
        var filter = MaterialSearchFilter(); filter.search = "山河"
        let aborted = GlobalMaterialStore.query(Array(repeating: seed, count: 5000), links: [], filter: filter, projectID: "", searchIndex: first.index, isCancelled: { checks += 1; return checks >= 3 })
        precondition(aborted.isEmpty, "Cancelled query must not return partial hits")
        let bulk = (0..<5000).map { i -> MaterialRecord in var m = seed; m.id = "item-\(i)"; m.name = "素材 \(i)"; return m }
        try await benchmark(label: "synthetic5000", materials: bulk, links: [link], folders: [folder])
        for count in [10_000, 100_000] {
            let large = (0..<count).map { i in MaterialRecord(id: "large-\(i)", kind: .image, name: "素材 \(i)", originalFilename: "photo.png", fingerprint: "\(i)", sourceLocations: [], createdAt: seed.createdAt, tags: ["组\(i % 100)"], rating: i % 6, note: "说明") }
            let largeCache = MaterialTextSearchCache()
            let key = MaterialTextSearchCache.Key(libraryGeneration: "large", queryRevision: 1, fields: all)
            let t = Date.now
            let prepared = await largeCache.prepare(key: key, enabled: true, materials: large, links: [], folders: [])
            precondition(prepared.index != nil && prepared.diagnostics.cachedRecordCount == count)
            let build = Date.now.timeIntervalSince(t)*1000
            var changedLarge = large; changedLarge[count/2].note = "新增备注"
            var revisionKey = key; revisionKey.queryRevision += 1
            let deltaStart = Date.now
            let delta = await largeCache.prepare(key: revisionKey, enabled: true, materials: changedLarge, links: [], folders: [])
            let deltaMS = Date.now.timeIntervalSince(deltaStart)*1000
            precondition(delta.diagnostics.normalizedRecordCount == 1 && delta.diagnostics.reusedRecordCount == count-1)
            var filter = MaterialSearchFilter(); filter.search = "新增备注"; filter.minimumRating = 1
            let rawStart = Date.now
            let expected = GlobalMaterialStore.query(changedLarge, links: [], filter: filter, projectID: "", sorted: false)
            let rawMS = Date.now.timeIntervalSince(rawStart)*1000
            let indexedStart = Date.now
            let actual = GlobalMaterialStore.query(changedLarge, links: [], filter: filter, projectID: "", sorted: false, searchIndex: delta.index)
            let indexedMS = Date.now.timeIntervalSince(indexedStart)*1000
            precondition(expected.map(\.id) == actual.map(\.id))
            print("LARGE_SEARCH records=\(count) build_ms=\(build) incremental_ms=\(deltaMS) normalized=1 reused=\(count-1) estimated_bytes=\(delta.diagnostics.estimatedBytes) raw_ms=\(rawMS) indexed_ms=\(indexedMS) excludes_frames=true")
        }
        if let raw = ProcessInfo.processInfo.environment["ASSETFRAME_SEARCH_BENCHMARK_ROOT"] {
            let snapshot = try await MaterialDatabase(root: URL(fileURLWithPath: raw)).load()
            try await benchmark(label: "real-library-snapshot", materials: snapshot.materials, links: snapshot.links, folders: snapshot.organization?.folders ?? [])
        }
        print("MaterialTextSearchSelfTest passed: 128 field combinations, multi-word/Unicode search, folder boundaries, deletion, revision/library/locale isolation, reuse, bounded fallback, duplicate IDs and cancellation")
    }
    static func benchmark(label: String, materials: [MaterialRecord], links: [ProjectMaterialLink], folders: [LocalFolderSource]) async throws {
        let cache = MaterialTextSearchCache()
        let started = Date.now
        let prepared = await cache.prepare(key: .init(libraryGeneration: label, queryRevision: 1, fields: Set(MaterialSearchField.allCases)), enabled: true, materials: materials, links: links, folders: folders)
        let buildMS = Date.now.timeIntervalSince(started)*1000
        var rawTimes: [Double] = [], indexedTimes: [Double] = []
        let terms = ["素材 1", "木兰", "视频", "人物", "暖色", "参考", "山河", "镜头", "png", "v02"]
        for i in 0..<40 {
            var filter = MaterialSearchFilter(); filter.search = terms[i % terms.count]
            let a = Date.now
            let raw = GlobalMaterialStore.query(materials, links: links, filter: filter, projectID: "", folders: folders, sorted: false)
            rawTimes.append(Date.now.timeIntervalSince(a)*1000)
            let b = Date.now
            let indexed = GlobalMaterialStore.query(materials, links: links, filter: filter, projectID: "", folders: folders, sorted: false, searchIndex: prepared.index)
            indexedTimes.append(Date.now.timeIntervalSince(b)*1000)
            precondition(raw.map(\.id) == indexed.map(\.id), "Benchmark membership mismatch")
        }
        let result: [String: Any] = ["label":label,"records":materials.count,"build_ms":buildMS,"raw_p95_ms":rawTimes.sorted()[37],"warm_index_p95_ms":indexedTimes.sorted()[37],"estimated_bytes":prepared.diagnostics.estimatedBytes,"index_active":prepared.diagnostics.active,"includes_debounce_or_frames":false]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]); print(String(decoding: data, as: UTF8.self))
    }
}
