import Foundation

/// 受控分类：词表完整性、单选/多选行为、旧数据兼容、筛选/搜索、撤销、持久化编码。
@main struct MaterialClassificationSelfTest {
    static func main() async throws {
        vocabularyIntegrity()
        singleAndMultipleSelection()
        normalizationAndUnknownValues()
        filterAndSearch()
        persistenceAndLegacyData()
        undoPatch()
        try await databaseRoundTrip()
        print("MaterialClassificationSelfTest passed: vocabulary, single/multi, filter, search, legacy decoding, undo and database round trip")
    }

    private static func vocabularyIntegrity() {
        let dimensions = ClassificationVocabulary.dimensions
        let terms = ClassificationVocabulary.terms
        precondition(!dimensions.isEmpty && terms.count >= 100, "词表为空或生成不完整")
        precondition(Set(dimensions.map(\.id)).count == dimensions.count, "维度 id 必须唯一")
        precondition(Set(terms.map(\.id)).count == terms.count, "维度内标准词必须唯一")
        precondition(dimensions.contains { $0.id == "asset_type" && !$0.allowsMultiple }, "资产类型必须是单选")
        precondition(ClassificationVocabulary.term("人物角色", in: "asset_type") != nil, "缺少核心词")
        precondition(ClassificationVocabulary.allowsMultiple("shot"), "镜头维度应为多选")
        for dimension in dimensions {
            let scoped = ClassificationVocabulary.terms(in: dimension.id)
            precondition(!scoped.isEmpty, "维度没有词条：\(dimension.id)")
            precondition(scoped.allSatisfy { $0.dimension == dimension.id }, "词条维度错位：\(dimension.id)")
            precondition(scoped.allSatisfy { !$0.canonical.isEmpty && !$0.aliases.isEmpty }, "词条缺少标准词或别名：\(dimension.id)")
        }
        precondition(ClassificationVocabulary.recommendedCount > 0)
    }

    private static func singleAndMultipleSelection() {
        var value = MaterialClassification()
        precondition(value.isEmpty && value.termCount == 0 && value.displayText.isEmpty)

        value.toggle("人物角色", in: "asset_type")
        precondition(value.terms(for: "asset_type") == ["人物角色"])
        value.toggle("场景", in: "asset_type")
        precondition(value.terms(for: "asset_type") == ["场景"], "单选维度必须替换而不是累加")
        value.toggle("场景", in: "asset_type")
        precondition(value.isEmpty, "再次点击已选项应清除")

        value.add("正面", in: "shot")
        value.add("近景", in: "shot")
        value.add("正面", in: "shot")
        precondition(Set(value.terms(for: "shot")) == ["正面", "近景"], "多选维度去重累加")
        value.toggle("背面", in: "shot")
        value.toggle("正面", in: "shot")
        precondition(Set(value.terms(for: "shot")) == ["近景", "背面"], "多选维度逐项切换")
        value.remove("背面", in: "shot")
        value.clear("shot")
        precondition(value.terms(for: "shot").isEmpty)

        let grouped = MaterialClassification(values: ["asset_type": ["人物角色"], "shot": ["近景", "正面"]])
        precondition(grouped.groups.count == 2)
        precondition(grouped.displayText.contains("资产类型:人物角色"), "展示需带维度名")
        precondition(Array(grouped.groups[1].terms.prefix(1)) == ["正面"], "展示按词表顺序，而不是输入顺序")
    }

    private static func normalizationAndUnknownValues() {
        let raw = MaterialClassification(values: ["shot": [" 近景 ", "近景", "", "  "], "asset_type": ["人物角色"]])
        precondition(raw.terms(for: "shot") == ["近景"], "去空白与去重")
        precondition(raw.termCount == 2)
        let unknown = MaterialClassification(values: ["future_dimension": ["新词"], "shot": ["未知自定义词"]])
        precondition(unknown.terms(for: "future_dimension") == ["新词"], "未知维度保留，用于兼容未来词表")
        precondition(unknown.terms(for: "shot") == ["未知自定义词"], "未知词保留，可展示并手动移除")
        precondition(unknown.displayText.contains("future_dimension"), "未知维度用 id 展示")
        var mutable = unknown
        mutable.remove("未知自定义词", in: "shot")
        precondition(mutable.terms(for: "shot").isEmpty)
    }

    private static func filterAndSearch() {
        let person = record(id: "person", classification: MaterialClassification(values: ["asset_type": ["人物角色"], "shot": ["正面", "近景"]]))
        let scene = record(id: "scene", classification: MaterialClassification(values: ["asset_type": ["场景"], "light": ["柔光"]]))
        let unclassified = record(id: "none", classification: nil)
        let records = [person, scene, unclassified]

        func ids(_ filter: MaterialSearchFilter) -> Set<String> {
            Set(GlobalMaterialStore.query(records, links: [], filter: filter, projectID: "").map(\.id))
        }

        var filter = MaterialSearchFilter()
        filter.classificationFilters = ["asset_type": ["人物角色"]]
        precondition(ids(filter) == ["person"], "按维度命中")
        filter.classificationFilters = ["shot": ["近景"]]
        precondition(ids(filter) == ["person"])
        filter.classificationFilters = ["shot": ["正面", "近景"]]
        precondition(ids(filter) == ["person"], "同维度多选是「或」")
        filter.classificationFilters = ["asset_type": ["人物角色"], "light": ["柔光"]]
        precondition(ids(filter).isEmpty, "维度之间是「且」")
        filter.classificationFilters = ["asset_type": ["场景"]]
        precondition(ids(filter) == ["scene"])
        filter.classificationFilters = ["unknown_dimension": ["任意"]]
        precondition(ids(filter).isEmpty, "未知维度筛选不应命中")
        filter.classificationFilters = nil
        precondition(ids(filter) == ["person", "scene", "none"], "空筛选不限制")
        precondition(filter.activeFacetCount == 0)
        filter.classificationFilters = ["asset_type": ["人物角色"], "shot": []]
        precondition(filter.activeFacetCount == 1, "空集合不算筛选维度")

        var search = MaterialSearchFilter()
        search.search = "近景"
        search.searchFields = [.classification]
        precondition(ids(search) == ["person"], "分类应参与搜索")
        search.search = "人物角色 正面"
        precondition(ids(search) == ["person"], "分类内多词需同时命中")
        search.searchFields = [.name]
        precondition(ids(search).isEmpty, "关闭分类搜索范围后不能命中")
        precondition(MaterialSearchField.classification.title == "分类")
        precondition(MaterialSearchField.allCases.contains(.classification))
    }

    private static func persistenceAndLegacyData() {
        let value = MaterialClassification(values: ["asset_type": ["人物角色"], "shot": ["近景"]])
        let encoded = try! JSONEncoder().encode(value)
        let decoded = try! JSONDecoder().decode(MaterialClassification.self, from: encoded)
        precondition(decoded == value, "分类编码往返")

        let original = record(id: "round-trip", classification: value)
        let data = try! JSONEncoder().encode(original)
        let restored = try! JSONDecoder().decode(MaterialRecord.self, from: data)
        precondition(restored == original, "素材编码往返保留分类")

        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "classification")
        let legacy = try! JSONDecoder().decode(MaterialRecord.self, from: JSONSerialization.data(withJSONObject: object))
        precondition(legacy.classification == nil, "旧记录没有分类字段应解码为未分类")
        precondition(legacy.note == original.note, "旧记录备注不受影响")

        var filter = MaterialSearchFilter()
        filter.classificationFilters = ["asset_type": ["人物角色"]]
        precondition(filter.activeFacetCount == 1)
        let filterData = try! JSONEncoder().encode(filter)
        precondition((try! JSONDecoder().decode(MaterialSearchFilter.self, from: filterData)) == filter, "筛选组合编码往返")
        var filterObject = try! JSONSerialization.jsonObject(with: filterData) as! [String: Any]
        filterObject.removeValue(forKey: "classificationFilters")
        let legacyFilter = try! JSONDecoder().decode(MaterialSearchFilter.self, from: JSONSerialization.data(withJSONObject: filterObject))
        precondition(legacyFilter.classificationFilters == nil, "旧保存筛选没有分类条件")
        filter.resetFacets()
        precondition(filter.classificationFilters == nil && filter.activeFacetCount == 0)
    }

    private static func undoPatch() {
        let before = record(id: "undo", classification: nil)
        let after = record(id: "undo", classification: MaterialClassification(values: ["asset_type": ["人物角色"]]))
        let patch = try! MaterialUndoPatch(before: [before], after: [after])
        precondition(patch.changes.contains { $0.field == .categories }, "分类变更必须进入撤销记录")
        let restored = try! patch.restore(in: [after])
        precondition(restored == [before], "撤销应恢复分类为空")

        var legacyBefore = before
        legacyBefore.assetType = .person
        var legacyAfter = before
        legacyAfter.assetType = .venue
        let legacyPatch = try! MaterialUndoPatch(before: [legacyBefore], after: [legacyAfter])
        precondition(legacyPatch.changes.contains { $0.field == .classification }, "旧 assetType 撤销仍用原字段")
        let legacyRestored = try! legacyPatch.restore(in: [legacyAfter])
        precondition(legacyRestored.first?.assetType == .person)
    }

    /// 真实 SQLite 载荷往返：分类随素材提交、重开库后仍存在，备注不受影响。
    private static func databaseRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("assetframe-classification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = MaterialDatabase(root: root)
        let empty = try await database.load()
        precondition(empty.materials.isEmpty)
        let value = MaterialClassification(values: ["asset_type": ["场景"], "light": ["柔光"], "shot": ["正面"]])
        let material = record(id: "db-round-trip", classification: value)
        var snapshot = empty
        snapshot.materials = [material]
        try await database.commit(snapshot, previous: empty)
        let reopened = try await database.load()
        guard let stored = reopened.materials.first else { preconditionFailure("数据库未返回素材") }
        precondition(stored.id == material.id)
        precondition(stored.classification == value, "SQLite 载荷必须保留分类")
        precondition(stored.note == material.note, "分类写入不得影响备注")
        let legacyLike = try JSONDecoder().decode(MaterialRecord.self, from: JSONEncoder().encode(material))
        precondition(legacyLike.classification == value)
    }

    private static func record(id: String, classification: MaterialClassification?) -> MaterialRecord {
        var value = MaterialRecord(id: id, kind: .image, name: "素材 \(id)", sourcePath: "/库/\(id).png",
            originalFilename: "\(id).png", fingerprint: id, sourceLocations: [], fileSize: 100,
            createdAt: Date(timeIntervalSince1970: 1), tags: ["参考"], rating: 0, note: "备注 \(id)")
        value.classification = classification
        return value
    }
}
