import Foundation

@main
struct AssetOrganizationSelfTest {
    static func main() async throws {
        precondition(UserDecision.confirmed.displayName == "使用")
        precondition(UserDecision.pending.displayName == "备用")
        precondition(UserDecision.rejected.displayName == "废片")
        precondition(UserDecision.confirmed.rawValue == "✅确定使用")
        precondition(UserDecision.pending.rawValue == "待确认")
        precondition(UserDecision.rejected.rawValue == "❌不用")

        var use = makeAsset(id: "USE", createdAt: .now)
        use.decision = .confirmed
        var backup = makeAsset(id: "BACKUP", createdAt: .now)
        backup.decision = .pending
        var waste = makeAsset(id: "WASTE", createdAt: .now)
        waste.decision = .rejected
        waste.originalFilename = "waste.gif"
        var onlyWasteFilter = AssetFilter()
        onlyWasteFilter.decision = .only(.rejected)
        precondition(AssetQuery.apply(to: [use, backup, waste], search: "", filter: onlyWasteFilter, sort: .name).map(\.id) == ["WASTE"])
        var hideWasteFilter = AssetFilter()
        hideWasteFilter.decision = .excluding(.rejected)
        precondition(Set(AssetQuery.apply(to: [use, backup, waste], search: "", filter: hideWasteFilter, sort: .name).map(\.id)) == ["USE", "BACKUP"])

        var jpg = makeAsset(id: "JPG", createdAt: .now)
        jpg.originalFilename = "portrait.JPG"
        var png = makeAsset(id: "PNG", createdAt: .now)
        png.originalFilename = "poster.png"
        var formatFilter = AssetFilter()
        formatFilter.fileExtensions = ["jpg", "png"]
        precondition(Set(AssetQuery.apply(to: [jpg, png, waste], search: "", filter: formatFilter, sort: .name).map(\.id)) == ["JPG", "PNG"])
        formatFilter.fileExtensions = ["png"]
        precondition(AssetQuery.apply(to: [jpg, png], search: "", filter: formatFilter, sort: .name).map(\.id) == ["PNG"])

        var landscape = makeAsset(id: "LANDSCAPE", createdAt: .now)
        landscape.pixelWidth = 1920; landscape.pixelHeight = 1080
        var portrait = makeAsset(id: "PORTRAIT", createdAt: .now)
        portrait.pixelWidth = 1080; portrait.pixelHeight = 1920
        var square = makeAsset(id: "SQUARE", createdAt: .now)
        square.pixelWidth = 1024; square.pixelHeight = 1024
        var shapeFilter = AssetFilter()
        shapeFilter.aspectRatios = [.landscape, .square]
        precondition(Set(AssetQuery.apply(to: [landscape, portrait, square], search: "", filter: shapeFilter, sort: .name).map(\.id)) == ["LANDSCAPE", "SQUARE"])
        shapeFilter.aspectRatios = [.custom]
        shapeFilter.customAspectRatio = 16.0 / 9.0
        precondition(AssetQuery.apply(to: [landscape, portrait, square], search: "", filter: shapeFilter, sort: .name).map(\.id) == ["LANDSCAPE"])

        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 300)
        var older = makeAsset(id: "OLDER", createdAt: Date(timeIntervalSince1970: 20))
        var newer = makeAsset(id: "NEWER", createdAt: Date(timeIntervalSince1970: 10))
        older.sourceModifiedAt = oldDate
        newer.sourceModifiedAt = newDate
        older.sourceCreatedAt = newDate
        newer.sourceCreatedAt = oldDate

        let newestFirst = AssetQuery.apply(
            to: [older, newer], search: "", filter: AssetFilter(), sort: .modifiedNewest
        )
        precondition(newestFirst.map(\.id) == ["NEWER", "OLDER"])
        let oldestFirst = AssetQuery.apply(
            to: [older, newer], search: "", filter: AssetFilter(), sort: .modifiedOldest
        )
        precondition(oldestFirst.map(\.id) == ["OLDER", "NEWER"])

        let sourceCreatedNewest = AssetSortConfiguration(criteria: [
            .init(field: .sourceCreatedAt, direction: .descending)
        ])
        precondition(AssetQuery.apply(
            to: [older, newer], search: "", filter: AssetFilter(), sort: sourceCreatedNewest
        ).map(\.id) == ["OLDER", "NEWER"])
        let sourceCreatedOldest = AssetSortConfiguration(criteria: [
            .init(field: .sourceCreatedAt, direction: .ascending)
        ])
        precondition(AssetQuery.apply(
            to: [older, newer], search: "", filter: AssetFilter(), sort: sourceCreatedOldest
        ).map(\.id) == ["NEWER", "OLDER"])
        precondition(AssetSortField.createdAt.rawValue == "添加日期")
        precondition(AssetSortField.sourceCreatedAt.rawValue == "创建日期")
        precondition(AssetSortField.sourceModifiedAt.rawValue == "修改日期")

        older.lastUsedAt = Date(timeIntervalSince1970: 200)
        newer.lastUsedAt = Date(timeIntervalSince1970: 400)
        precondition(SavedView.recentlyUsed.includes(older))
        precondition(!SavedView.recentlyUsed.includes(makeAsset(id: "NEVER-USED", createdAt: .now)))
        precondition(AssetQuery.apply(to: [older, newer], search: "", filter: AssetFilter(), sort: .usedNewest).map(\.id) == ["NEWER", "OLDER"])
        precondition(AssetQuery.apply(to: [older, newer], search: "", filter: AssetFilter(), sort: .usedOldest).map(\.id) == ["OLDER", "NEWER"])

        let shuffleInput = (0..<8).map { makeAsset(id: "SHUFFLE-\($0)", createdAt: .now) }
        let shuffled = SeededAssetShuffle.ordered(shuffleInput, seed: 100)
        precondition(shuffled.map(\.id) == SeededAssetShuffle.ordered(Array(shuffleInput.reversed()), seed: 100).map(\.id))
        precondition(Set(shuffled.map(\.id)) == Set(shuffleInput.map(\.id)))
        precondition(shuffled.map(\.id) != SeededAssetShuffle.ordered(shuffleInput, seed: 200).map(\.id))

        older.pixelWidth = 4096; older.pixelHeight = 4096
        newer.pixelWidth = 1024; newer.pixelHeight = 1024
        precondition(AssetQuery.apply(to: [older, newer], search: "", filter: AssetFilter(), sort: .resolution).map(\.id) == ["OLDER", "NEWER"])
        precondition(AssetQuery.apply(to: [older, newer], search: "", filter: AssetFilter(), sort: .resolutionLowest).map(\.id) == ["NEWER", "OLDER"])

        older.sourceFileSize = 8_000_000
        newer.sourceFileSize = 2_000_000
        let fileSizeSort = AssetSortConfiguration(criteria: [.init(field: .fileSize, direction: .descending)])
        precondition(AssetQuery.apply(to: [newer, older], search: "", filter: AssetFilter(), sort: fileSizeSort).map(\.id) == ["OLDER", "NEWER"])

        older.rating = 5; newer.rating = 1
        precondition(AssetQuery.apply(to: [older, newer], search: "", filter: AssetFilter(), sort: .rating).map(\.id) == ["OLDER", "NEWER"])
        precondition(AssetQuery.apply(to: [older, newer], search: "", filter: AssetFilter(), sort: .ratingLowest).map(\.id) == ["NEWER", "OLDER"])

        older.name = "A"; newer.name = "B"
        precondition(AssetQuery.apply(to: [older, newer], search: "", filter: AssetFilter(), sort: .name).map(\.id) == ["OLDER", "NEWER"])
        precondition(AssetQuery.apply(to: [older, newer], search: "", filter: AssetFilter(), sort: .nameDescending).map(\.id) == ["NEWER", "OLDER"])

        var largeFiveOld = makeAsset(id: "LARGE-5-OLD", createdAt: Date(timeIntervalSince1970: 10))
        largeFiveOld.pixelWidth = 4000; largeFiveOld.pixelHeight = 3000; largeFiveOld.rating = 5
        var largeFiveNew = makeAsset(id: "LARGE-5-NEW", createdAt: Date(timeIntervalSince1970: 30))
        largeFiveNew.pixelWidth = 4000; largeFiveNew.pixelHeight = 3000; largeFiveNew.rating = 5
        var largeFour = makeAsset(id: "LARGE-4", createdAt: Date(timeIntervalSince1970: 40))
        largeFour.pixelWidth = 4000; largeFour.pixelHeight = 3000; largeFour.rating = 4
        var smallFive = makeAsset(id: "SMALL-5", createdAt: Date(timeIntervalSince1970: 50))
        smallFive.pixelWidth = 1000; smallFive.pixelHeight = 1000; smallFive.rating = 5
        let multiSort = AssetSortConfiguration(criteria: [
            .init(field: .resolution, direction: .descending),
            .init(field: .rating, direction: .descending),
            .init(field: .createdAt, direction: .descending)
        ])
        precondition(AssetQuery.apply(
            to: [smallFive, largeFour, largeFiveOld, largeFiveNew],
            search: "", filter: AssetFilter(), sort: multiSort
        ).map(\.id) == ["LARGE-5-NEW", "LARGE-5-OLD", "LARGE-4", "SMALL-5"])

        let ratingFirst = AssetSortConfiguration(criteria: [
            .init(field: .rating, direction: .descending),
            .init(field: .resolution, direction: .descending)
        ])
        precondition(AssetQuery.apply(
            to: [smallFive, largeFour], search: "", filter: AssetFilter(), sort: ratingFirst
        ).map(\.id) == ["SMALL-5", "LARGE-4"])

        let ascendingResolution = AssetSortConfiguration(criteria: [
            .init(field: .resolution, direction: .ascending)
        ])
        precondition(AssetQuery.apply(
            to: [largeFour, smallFive], search: "", filter: AssetFilter(), sort: ascendingResolution
        ).map(\.id) == ["SMALL-5", "LARGE-4"])

        let duplicateFields = AssetSortConfiguration(criteria: [
            .init(field: .rating, direction: .descending),
            .init(field: .rating, direction: .ascending)
        ])
        precondition(duplicateFields.criteria.count == 1)
        var cappedSort = AssetSortConfiguration(criteria: [.init(field: .resolution, direction: .descending)])
        [.rating, .createdAt, .sourceCreatedAt, .lastUsedAt, .sourceModifiedAt, .name].forEach { cappedSort.add(field: $0) }
        precondition(cappedSort.criteria.count == AssetSortConfiguration.maximumCriteria)

        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(older)) as! [String: Any]
        legacyJSON.removeValue(forKey: "sourceCreatedAt")
        let legacyDecoded = try JSONDecoder().decode(
            AssetItem.self,
            from: JSONSerialization.data(withJSONObject: legacyJSON)
        )
        precondition(legacyDecoded.sourceCreatedAt == nil)
        var sameA = makeAsset(id: "A-STABLE", createdAt: oldDate)
        var sameB = makeAsset(id: "B-STABLE", createdAt: oldDate)
        sameA.rating = 3; sameB.rating = 3
        precondition(AssetQuery.apply(
            to: [sameB, sameA], search: "", filter: AssetFilter(),
            sort: AssetSortConfiguration(criteria: [.init(field: .rating, direction: .descending)])
        ).map(\.id) == ["A-STABLE", "B-STABLE"])

        let stack = AssetStack(
            id: "STACK-1", name: "同一角色候选", coverAssetID: older.id,
            memberAssetIDs: [older.id, newer.id], createdAt: .now, updatedAt: .now
        )
        let extraction = ScriptExtractionRecord(
            id: "SCRIPT-1", sourceName: "测试剧本.md", sourcePath: "/tmp/测试剧本.md",
            createdAt: .now, textFingerprint: "fingerprint",
            candidates: [
                ScriptAssetCandidate(
                    id: "CANDIDATE-1", name: "桑枝", type: .person, reuse: .s,
                    appearances: ["第1集第1场"], evidence: "桑枝入城", note: "主角", status: .pending
                )
            ]
        )

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let indexedImage = root.appendingPathComponent("creation-date.png")
        try Data([0]).write(to: indexedImage)
        let indexedRecords = ProjectImageIndexer.scan(root: root, existing: [])
        precondition(indexedRecords.count == 1)
        precondition(indexedRecords[0].sourceCreatedAt != nil)
        precondition(indexedRecords[0].previewAsset(projectID: "PROJECT", projectName: "测试").sourceCreatedAt != nil)

        let database = ProjectDatabase(url: root.appendingPathComponent("project.sqlite"))
        try await database.replace(with: ProjectSnapshot(
            library: LibraryData(
                assets: [older, newer], groups: [], relations: [],
                assetStacks: [stack], scriptExtractions: [extraction]
            ),
            exportNames: [:]
        ))
        let loaded = try await database.load()
        precondition(loaded.library.assetStacks?.first?.id == stack.id)
        precondition(loaded.library.assetStacks?.first?.memberAssetIDs == stack.memberAssetIDs)
        precondition(loaded.library.scriptExtractions?.first?.id == extraction.id)
        precondition(loaded.library.scriptExtractions?.first?.candidates.first?.name == "桑枝")

        let scriptURL = root.appendingPathComponent("测试剧本.md")
        try "# 第1集\n\n桑枝进入镇北城，拿出吞金兽储蓄袋。".write(to: scriptURL, atomically: true, encoding: .utf8)
        let scriptText = try ScriptDocumentReader.read(url: scriptURL)
        precondition(scriptText.contains("镇北城"))
        precondition(ScriptDocumentReader.fingerprint(scriptText).count == 64)

        let decoded = try ScriptAssetExtractionClient.decode("""
        {"items":[
          {"name":"桑枝","assetType":"人物","reuseGrade":"S","appearances":["第1集第1场"],"evidence":"桑枝入城","note":"主角"},
          {"name":"镇北城","assetType":"场景","reuseGrade":"A","appearances":["第1集第1场"],"evidence":"进入镇北城","note":"主场景"},
          {"name":"紧张情绪","assetType":"情绪","reuseGrade":"B","appearances":[],"evidence":"紧张","note":"不应入库"}
        ]}
        """)
        precondition(decoded.map(\.name) == ["桑枝", "镇北城"])

        let mergedState = try ScriptAssetExtractionClient.decode("""
        {"items":[
          {"name":"顾婉宁","assetType":"人物","formName":"基础","reuseGrade":"S","appearances":["第1集"],"evidence":"穿越前后需保持外貌一致","note":"现代装扮与古代装扮差异大"}
        ]}
        """)
        do {
            try ScriptAssetExtractionClient.validateSeparatedForms(mergedState)
            preconditionFailure("多个稳定形态挤在一行时必须拒绝结果")
        } catch ScriptExtractionError.unseparatedForms(let name) {
            precondition(name == "顾婉宁")
        }

        let separatedStates = try ScriptAssetExtractionClient.decode("""
        {"items":[
          {"name":"顾婉宁","assetType":"人物","formName":"穿越前·现代装","reuseGrade":"S","appearances":["第1集场0-1"],"evidence":"穿越前穿现代睡衣","note":"粉色长袖睡衣、湿发散着"},
          {"name":"顾婉宁","assetType":"人物","formName":"穿越后·古代装","reuseGrade":"S","appearances":["第1集场1-1"],"evidence":"穿越后长期穿粗布工衣","note":"保持同一人物外貌"},
          {"name":"桑枝","assetType":"人物","formName":"流放初期·无罪籍手镯","reuseGrade":"A","appearances":["第1集场1-2"],"evidence":"流放初期","note":"基础状态无罪籍手镯"},
          {"name":"桑枝","assetType":"人物","formName":"后期·罪籍手镯","reuseGrade":"A","appearances":["后续"],"evidence":"后期右腕长期戴罪籍手镯","note":"长期佩戴标志"}
        ]}
        """)
        try ScriptAssetExtractionClient.validateSeparatedForms(separatedStates)
        precondition(separatedStates.filter { $0.name == "顾婉宁" }.count == 2)
        precondition(separatedStates.filter { $0.name == "桑枝" }.count == 2)
        precondition(separatedStates[0].formQualifiedName == "顾婉宁（穿越前·现代装）")
        precondition(separatedStates[1].formQualifiedName == "顾婉宁（穿越后·古代装）")
        precondition(separatedStates[2].formQualifiedName == "桑枝（流放初期·无罪籍手镯）")
        precondition(separatedStates[3].formQualifiedName == "桑枝（后期·罪籍手镯）")
        precondition(decoded[0].formQualifiedName == "桑枝")

        print("AssetOrganizationSelfTest passed")
    }

    private static func makeAsset(id: String, createdAt: Date) -> AssetItem {
        var asset = PendingImportItem(
            id: id,
            stagedPath: "/tmp/\(id).png",
            originalSourcePath: "/tmp/\(id).png",
            originalFilename: "\(id).png",
            sourceFileID: id,
            sourceFileSize: 1,
            sourceModifiedAt: nil,
            pixelWidth: 1024,
            pixelHeight: 1024,
            suggestedType: .person,
            category: .project,
            createdAt: createdAt
        ).previewAsset
        asset.id = id
        return asset
    }
}
