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
        let encoded = try JSONEncoder().encode(f)
        let roundTrip = try JSONDecoder().decode(MaterialSearchFilter.self, from: encoded)
        precondition(roundTrip == f)
        var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for key in ["searchFields", "requiredTags", "folderPaths", "colorLabels", "exactRating"] { old.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(MaterialSearchFilter.self, from: JSONSerialization.data(withJSONObject: old))
        precondition(restored.searchFields == nil && restored.folderPaths == nil && restored.colorLabels == nil)
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
        print("MaterialFilterSelfTest passed: combined criteria, scoped multi-field search, tags, color labels, folder boundaries, shape, rating, format, old presets, natural sorting, unknown-last, stable ties and sort persistence")
    }
}
