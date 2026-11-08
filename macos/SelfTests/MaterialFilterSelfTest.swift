import Foundation

@main struct MaterialFilterSelfTest {
    static func main() throws {
        var reset = MaterialSearchFilter()
        reset.search = "人物"; reset.searchFields = [.name]
        precondition(reset.activeFacetCount == 0, "Search configuration is not a facet")
        reset.kinds = [.image, .video]; reset.minimumDuration = 1; reset.maximumDuration = 10
        reset.exactRating = 0; reset.requiredTags = []
        precondition(reset.activeFacetCount == 3, "Count dimensions; exact zero rating is active, empty sets are not")
        reset.resetFacets()
        precondition(reset.activeFacetCount == 0 && reset.search == "人物" && reset.searchFields == [.name],
                     "Clearing facets must preserve search text and its selected fields")
        let image = MaterialRecord(id: "image", kind: .image, name: "参考", sourcePath: "/库/人物/子目录/a.png",
            originalFilename: "a.PNG", fingerprint: "a", sourceLocations: [], fileSize: nil,
            mediaMetadata: MaterialMediaMetadata(pixelWidth: 800, pixelHeight: 1200),
            createdAt: .now, tags: ["人物", "参考"], rating: 4, note: "", colorLabel: "红色")
        var other = image; other.id = "other"; other.sourcePath = "/库/人物2/b.png"; other.colorLabel = nil; other.tags = ["人物"]
        var audio = image; audio.id = "audio"; audio.kind = .audio; audio.originalFilename = "a.wav"; audio.rating = 0
        audio.mediaMetadata = nil
        var video = image; video.id = "video"; video.kind = .video; video.originalFilename = "a.mp4"
        var searchableImage = image
        searchableImage.id = "searchable"
        searchableImage.name = "山河画卷"
        searchableImage.originalFilename = "landscape.PNG"
        searchableImage.sourceURL = "https://example.com/reference"
        searchableImage.sourcePath = "/库/人物/分镜/landscape.PNG"
        searchableImage.tags = ["古风"]
        searchableImage.note = "暖色调整"
        searchableImage.production = MaterialProductionMetadata(purpose: "生成镜头", versionName: "v03", prompt: "远景", platform: "即梦", model: "4.0", batch: "B12")
        let searchLink = ProjectMaterialLink(id: "search-link", projectID: "project", materialID: searchableImage.id, use: .candidate, episode: "第2集", scene: "客栈", shot: "镜头18", selection: "备用", createdAt: .now, note: "补人物动作")
        let searchFolder = LocalFolderSource(
            id: "search-folder", name: "人物参考库", rootPath: "/库/人物",
            bookmarkData: nil, directoryPaths: [], createdAt: .now, lastScannedAt: nil
        )
        let records = [image, other, audio, video, searchableImage]
        var cancellationChecks = 0
        let cancelled = GlobalMaterialStore.query(Array(repeating: image, count: 5_000), links: [],
            filter: MaterialSearchFilter(), projectID: "", isCancelled: {
                cancellationChecks += 1
                return cancellationChecks >= 3
            })
        precondition(cancelled.isEmpty && cancellationChecks == 3,
                     "Cancelled queries must stop early and never return partial results")
        func ids(_ filter: MaterialSearchFilter) -> Set<String> {
            Set(GlobalMaterialStore.query(records, links: [searchLink], filter: filter, projectID: "", folders: [searchFolder]).map(\.id))
        }
        var f = MaterialSearchFilter(); f.kinds = [.image]; f.formats = ["png"]; f.requiredTags = ["人物", "参考"]
        f.folderPaths = ["/库/人物"]; f.colorLabels = ["红色"]; f.minimumRating = 4; f.orientation = "竖屏"
        precondition(ids(f) == ["image"], "Combined filters must intersect, match descendants and exclude sibling prefix")
        f.requiredTags = ["不存在"]; precondition(ids(f).isEmpty)
        f = MaterialSearchFilter(); f.colorLabels = ["未标记"]; precondition(ids(f) == ["other"])
        f = MaterialSearchFilter(); f.exactRating = 0; precondition(ids(f) == ["audio"])
        f = MaterialSearchFilter(); f.orientation = "横屏"; precondition(ids(f).isEmpty, "Unknown dimensions do not match a shape")
        f = MaterialSearchFilter(); precondition(ids(f).count == 5)
        f.folderPaths = ["/库/人物", "/库/人物2"]; precondition(ids(f).count == 5)
        f = MaterialSearchFilter(); f.kinds = [.image]; precondition(ids(f) == ["image", "other", "searchable"])
        f.kinds = [.video]; precondition(ids(f) == ["video"])
        f.kinds = [.audio]; precondition(ids(f) == ["audio"])
        f.formats = ["mp3"]
        f.selectOnly(kind: .video)
        precondition(f.kinds == [.video] && f.formats.isEmpty, "Quick media scope must clear an incompatible format")
        f.selectOnly(kind: nil)
        precondition(f.kinds.isEmpty && f.formats.isEmpty)
        let searchCases: [(MaterialSearchField, String, Set<String>)] = [
            (.name, "山河", ["searchable"]), (.folder, "分镜", ["searchable"]),
            (.fileExtension, "png", ["image", "other", "searchable"]),
            (.tags, "古风", ["searchable"]), (.sourceLink, "example.com", ["searchable"]),
            (.productionMark, "第2集 镜头18", ["searchable"]), (.note, "暖色", ["searchable"])
        ]
        for (field, term, expected) in searchCases {
            var scoped = MaterialSearchFilter(); scoped.search = term; scoped.searchFields = [field]
            precondition(ids(scoped) == expected, "Search field failed: \(field)")
        }
        var splitAcrossFields = MaterialSearchFilter()
        splitAcrossFields.search = "山河 古风 镜头18"
        precondition(ids(splitAcrossFields) == ["searchable"], "Words should match across enabled fields")
        var excludedField = MaterialSearchFilter(); excludedField.search = "古风"; excludedField.searchFields = [.name]
        precondition(ids(excludedField).isEmpty, "Disabled fields must not leak into search")
        var facet = MaterialSearchFilter(); facet.folderPaths = ["/库/人物"]; facet.requiredTags = ["参考"]
        let scopeRecords = GlobalMaterialStore.query(records, links: [], filter: facet, projectID: "")
        let counts = GlobalMaterialStore.formatCounts(in: scopeRecords)
        precondition(counts == ["png": 1, "wav": 1, "mp4": 1], "Counts must reflect other filters and normalize extensions")
        facet.formats = ["png"]
        let selected = GlobalMaterialStore.query(records, links: [], filter: facet, projectID: "")
        precondition(selected.count == 1 && counts["wav"] == 1, "Selecting PNG must not remove the WAV alternative count")
        var two = image; two.id = "two"; two.name = "素材2"; two.fileSize = 20
        var ten = image; ten.id = "ten"; ten.name = "素材10"; ten.fileSize = 100
        var unknown = image; unknown.id = "unknown"; unknown.fileSize = nil
        precondition(GlobalMaterialStore.sortedMaterials([ten, two], order: MaterialSortOrder(field: .name, ascending: true)).map(\.id) == ["two", "ten"])
        precondition(GlobalMaterialStore.sortedMaterials([unknown, ten, two], order: MaterialSortOrder(field: .size, ascending: false)).map(\.id) == ["ten", "two", "unknown"])
        precondition(GlobalMaterialStore.sortedMaterials([unknown, ten, two], order: MaterialSortOrder(field: .size, ascending: true)).map(\.id) == ["two", "ten", "unknown"])
        two.rating = 3; ten.rating = 3
        let stable = GlobalMaterialStore.sortedMaterials([two, ten], order: MaterialSortOrder(field: .rating, ascending: false))
        precondition(stable.map(\.id) == ["ten", "two"], "Ties require stable IDs")
        let sort = MaterialSortOrder(field: .duration, ascending: true)
        let decodedSort = try JSONDecoder().decode(MaterialSortOrder.self, from: JSONEncoder().encode(sort))
        precondition(sort == decodedSort)
        var createdOld = two; createdOld.sourceCreatedAt = Date(timeIntervalSince1970: 10)
        var createdNew = ten; createdNew.sourceCreatedAt = Date(timeIntervalSince1970: 20)
        precondition(GlobalMaterialStore.sortedMaterials([createdNew, createdOld], order: MaterialSortOrder(field: .created, ascending: true)).map(\.id) == ["two", "ten"])
        let randomOrder = MaterialSortOrder(field: .random, ascending: true, randomSeed: 42)
        let randomA = GlobalMaterialStore.sortedMaterials([two, ten, unknown], order: randomOrder).map(\.id)
        let randomB = GlobalMaterialStore.sortedMaterials([unknown, two, ten], order: randomOrder).map(\.id)
        precondition(randomA == randomB && Set(randomA) == Set(["two", "ten", "unknown"]), "Random mode must stay stable during one browse session")
        // 轻量挑图：桶边界按日历日、口径可切、未挑过滤只看颜色标签，且必须能随筛选组合持久化。
        let bucketCalendar = Calendar.current
        let startOfToday = bucketCalendar.startOfDay(for: Date.now)
        func day(_ offset: Int) -> Date {
            let midnight = bucketCalendar.date(byAdding: .day, value: -offset, to: startOfToday) ?? startOfToday
            return bucketCalendar.date(byAdding: .hour, value: 12, to: midnight) ?? midnight
        }
        func dated(_ id: String, file: Date, imported: Date? = nil) -> MaterialRecord {
            var item = image
            item.id = id; item.sourceCreatedAt = file; item.sourceModifiedAt = file
            item.createdAt = imported ?? file; item.colorLabel = nil
            return item
        }
        let todayRecord = dated("today", file: day(0))
        let yesterdayRecord = dated("yesterday", file: day(1))
        let dayBeforeRecord = dated("dayBefore", file: day(2))
        let oldRecord = dated("old", file: day(10))
        let lateImportRecord = dated("lateImport", file: day(10), imported: Date.now)
        let bucketRecords = [todayRecord, yesterdayRecord, dayBeforeRecord, oldRecord, lateImportRecord]
        func bucketIDs(_ scope: QuickPickScope) -> Set<String> {
            var scoped = MaterialSearchFilter(); scoped.quickPick = scope
            return Set(GlobalMaterialStore.query(bucketRecords, links: [], filter: scoped, projectID: "").map(\.id))
        }
        precondition(bucketIDs(QuickPickScope(bucket: .today)) == ["today"], "今天桶只含当天日历日")
        precondition(bucketIDs(QuickPickScope(bucket: .yesterday)) == ["yesterday"])
        precondition(bucketIDs(QuickPickScope(bucket: .dayBefore)) == ["dayBefore"])
        precondition(bucketIDs(QuickPickScope(bucket: .last7)) == ["today", "yesterday", "dayBefore"], "近7天含今天，往前六个日历日")
        precondition(bucketIDs(QuickPickScope(bucket: .today, basis: .imported)) == ["today", "lateImport"],
                     "补导入的历史图按入库时间落进今天，这是两个口径必须分开的理由")
        var midnightRecord = todayRecord; midnightRecord.sourceCreatedAt = startOfToday; midnightRecord.sourceModifiedAt = startOfToday; midnightRecord.createdAt = startOfToday
        var lastSecondRecord = todayRecord; lastSecondRecord.sourceCreatedAt = startOfToday.addingTimeInterval(-1)
        lastSecondRecord.sourceModifiedAt = startOfToday.addingTimeInterval(-1); lastSecondRecord.createdAt = startOfToday.addingTimeInterval(-1)
        let boundaryRecords = [midnightRecord, lastSecondRecord]
        var boundaryFilter = MaterialSearchFilter(); boundaryFilter.quickPick = QuickPickScope(bucket: .today)
        let boundaryHits = Set(GlobalMaterialStore.query(boundaryRecords, links: [], filter: boundaryFilter, projectID: "").map(\.id))
        precondition(boundaryHits == ["today"], "零点整属于今天，前一天最后一秒不属于今天")
        // 指定日期：只看选中的那一天，边界同样按本地零点。
        let customRecord = dated("custom", file: day(3))
        let customNeighbor = dated("customNeighbor", file: day(4))
        var customFilter = MaterialSearchFilter(); customFilter.quickPick = QuickPickScope(day: day(3))
        let customHits = GlobalMaterialStore.query([customRecord, customNeighbor, todayRecord], links: [], filter: customFilter, projectID: "").map(\.id)
        precondition(customHits == ["custom"], "指定日期只取那一天")
        let customMidnightDate = bucketCalendar.startOfDay(for: day(3))
        var customMidnight = customRecord; customMidnight.sourceCreatedAt = customMidnightDate
        customMidnight.sourceModifiedAt = customMidnightDate; customMidnight.createdAt = customMidnightDate
        let customLastDate = customMidnightDate.addingTimeInterval(-1)
        var customLastSecond = customNeighbor; customLastSecond.sourceCreatedAt = customLastDate
        customLastSecond.sourceModifiedAt = customLastDate; customLastSecond.createdAt = customLastDate
        let customBoundary = Set(GlobalMaterialStore.query([customMidnight, customLastSecond], links: [], filter: customFilter, projectID: "").map(\.id))
        precondition(customBoundary == ["custom"], "指定日期的零点整属于当天，前一天最后一秒不属于")
        let customCounts = QuickPickCounts.counting([customRecord, customNeighbor], scope: QuickPickScope(day: day(3)))
        precondition(customCounts.bucketTotal == 1 && customCounts.unpicked == 1 && customCounts.buckets[.last7] == 2,
                     "指定日期的读数只算那一天，预置桶数字照旧")
        let customTrip = try JSONDecoder().decode(QuickPickScope.self, from: JSONEncoder().encode(QuickPickScope(day: day(3))))
        precondition(customTrip.day != nil, "指定日期要能随浏览状态存回")
        var scopeObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(QuickPickScope(day: day(3)))) as! [String: Any]
        scopeObject.removeValue(forKey: "day")
        let restoredScope = try JSONDecoder().decode(QuickPickScope.self, from: JSONSerialization.data(withJSONObject: scopeObject))
        precondition(restoredScope.day == nil && restoredScope.bucket == .today, "旧筛选组合缺 day 键必须解码回预置桶")
        var markedRecord = todayRecord; markedRecord.colorLabel = "绿色"
        var unmarkedOther = yesterdayRecord; unmarkedOther.colorLabel = nil
        var pickedFilter = MaterialSearchFilter()
        pickedFilter.quickPick = QuickPickScope(bucket: .last7, unpickedOnly: true)
        let pickedHits = Set(GlobalMaterialStore.query([markedRecord, unmarkedOther], links: [], filter: pickedFilter, projectID: "").map(\.id))
        precondition(pickedHits == ["yesterday"], "只看没挑过的必须跳过已有颜色标签的记录")
        let pickCounts = QuickPickCounts.counting([todayRecord, markedRecord, yesterdayRecord, oldRecord], scope: QuickPickScope(bucket: .today))
        precondition(pickCounts.buckets[.today] == 2 && pickCounts.buckets[.last7] == 3 && pickCounts.buckets[.yesterday] == 1,
                     "桶计数按口径与日历日，近7天含今天")
        precondition(pickCounts.bucketTotal == 2 && pickCounts.picked == 1 && pickCounts.unpicked == 1, "当前桶的已挑/未挑必须相加等于总数")
        var pickFilter = MaterialSearchFilter(); pickFilter.quickPick = QuickPickScope(bucket: .last7, basis: .imported, unpickedOnly: true)
        let pickTrip = try JSONDecoder().decode(MaterialSearchFilter.self, from: JSONEncoder().encode(pickFilter))
        precondition(pickTrip == pickFilter, "轻量模式要随浏览状态与筛选组合一起存回")
        var keepMode = pickFilter; keepMode.kinds = [.image]; keepMode.resetFacets()
        precondition(keepMode.quickPick == pickFilter.quickPick && keepMode.kinds.isEmpty, "清除筛选不能退出轻量模式")
        let encoded = try JSONEncoder().encode(f)
        let roundTrip = try JSONDecoder().decode(MaterialSearchFilter.self, from: encoded)
        precondition(roundTrip == f)
        var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for key in ["searchFields", "requiredTags", "folderPaths", "colorLabels", "exactRating", "quickPick"] { old.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(MaterialSearchFilter.self, from: JSONSerialization.data(withJSONObject: old))
        precondition(restored.searchFields == nil && restored.folderPaths == nil && restored.colorLabels == nil && restored.quickPick == nil,
                     "旧库与旧筛选组合缺 quickPick 键必须解码成完整库")
        // Same fixture and process: compare the previous double sort with the new single sort.
        let bulk = (0..<5_000).map { i -> MaterialRecord in
            var item = image; item.id = "item-\(i)"; item.name = "素材 \(i)"
            item.createdAt = Date(timeIntervalSince1970: Double(i)); return item
        }
        var browseFilter = MaterialSearchFilter(); browseFilter.projectOnly = false
        let browseOrder = MaterialSortOrder(field: .imported, ascending: false)
        var oldTimes: [Double] = [], newTimes: [Double] = []
        for iteration in 0..<30 {
            browseFilter.search = iteration % 2 == 0 ? "" : "素材 1"
            let start = Date.now
            let oldResult = GlobalMaterialStore.sortedMaterials(GlobalMaterialStore.query(bulk, links: [], filter: browseFilter, projectID: ""), order: browseOrder)
            oldTimes.append(Date.now.timeIntervalSince(start) * 1000)
            let next = Date.now
            let newResult = GlobalMaterialStore.sortedMaterials(GlobalMaterialStore.query(bulk, links: [], filter: browseFilter, projectID: "", sorted: false), order: browseOrder)
            newTimes.append(Date.now.timeIntervalSince(next) * 1000)
            precondition(oldResult.map(\.id) == newResult.map(\.id), "Single sort must preserve query membership and ordering")
        }
        let oldP95 = oldTimes.sorted()[28], newP95 = newTimes.sorted()[28]
        print(String(format: "Unified 5000 query+sort P95 baseline=%.2fms optimized=%.2fms (search debounce excluded)", oldP95, newP95))
        precondition(newP95 <= 300, "5000-record local query exceeded 300ms")
        print("MaterialFilterSelfTest passed: combined criteria, scoped multi-field search, tags, color labels, folder boundaries, shape, rating, format, old presets, natural sorting, unknown-last, stable ties, sort persistence and quick-pick date buckets")
    }
}
