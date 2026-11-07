import Foundation

/// 界面进度的单调状态机：每轮索引领一个 epoch，只有当前 epoch 的上报会被采纳。
/// 进度从后台 detached 任务 hop 回主线程时可能乱序或迟到，这里挡住回退与旧任务回写。
struct SuggestionProgressState: Sendable {
    private(set) var indexed = 0
    private(set) var total = 0
    private(set) var epoch = 0
    private(set) var isRunning = false

    /// 开始一轮：作废旧 epoch，返回本轮的 epoch。
    mutating func begin(total: Int) -> Int {
        epoch &+= 1
        indexed = 0
        self.total = total
        isRunning = true
        return epoch
    }

    /// 采纳一档上报；返回 false 表示属于已失效任务、造成回退或读数未变。
    mutating func apply(indexed: Int, total: Int, epoch: Int) -> Bool {
        guard isRunning, epoch == self.epoch else { return false }
        let next = Swift.max(self.indexed, indexed)
        guard next != self.indexed || total != self.total else { return false }
        self.indexed = next
        self.total = total
        return true
    }

    /// 结束本轮；返回 false 表示这轮已被新任务或取消取代。
    mutating func finish(epoch: Int) -> Bool {
        guard isRunning, epoch == self.epoch else { return false }
        isRunning = false
        self.epoch &+= 1
        return true
    }
}

/// 导入增量的取数口径：两端都取提交态快照，发布态只作兜底。
/// mutate 在导入期间按 0.5s 节流发布 materials，读发布态会把本次新增过滤成空数组。
enum SuggestionIndexScope {
    static func newlyAdded(committed: [MaterialRecord], published: [MaterialRecord], before: Set<String>) -> [MaterialRecord] {
        let added = committed.filter { !before.contains($0.id) }
        return added.isEmpty ? published.filter { !before.contains($0.id) } : added
    }
}

/// 分类建议引擎：把「命名规则」和「本机视觉/相似图」的判断结果整理成待确认建议。
///
/// 这个引擎只产出 `MaterialTaggingState.Suggestion`，本身不写 `MaterialRecord.classification`；
/// 正式分类只在用户于「待确认」箱里点采纳（或沿用其既有决定）后由 `GlobalMaterialStore` 写入。
/// 全程本地：只读文件名、目录名和 macOS 自带 Vision，不联网、不调用任何线上模型。
enum ClassificationSuggestionEngine {
    /// 相似图判定的距离上限，沿用 `ProjectImageIndexer` 既有的 0.35 口径。
    static let similarDistanceLimit: Float = 0.35
    /// 一轮相似图索引最多处理多少张未分类图，超出的留到下一轮，避免长时间独占磁盘与 CPU。
    static let maximumClusterInputs = 2000
    /// 参考图（已有资产类型的图）每种类型最多取几张，控制比对规模。
    static let referencesPerType = 12
    /// 剩余图片互相聚类的簇上限，超出后本轮不再新增相似图建议。
    static let maximumClusters = 240

    struct Progress: Sendable, Equatable { var indexed: Int; var total: Int }

    /// 分组的稳定指纹：同一维度、同一建议名、同一来源引擎即为同一组。
    /// 用户的决定按它跨重跑对齐，所以不能含会漂移的成员列表或时间戳。
    static func groupKey(dimension: String, name: String, engine: String) -> String {
        "cls:\(engine)|\(dimension)|\(name)"
    }

    /// 该维度当前值是否允许被自动结果提问。
    ///
    /// 只有三种情况不算用户的判断：空、规则当年写下的占位默认值、`correctableTerms` 登记的旧版误判。
    /// 其余非空值一律视为手工设置或已采用过，永不再提建议、永不覆盖。
    static func allowsSuggestion(existing: [String], dimension: String) -> Bool {
        if existing.isEmpty { return true }
        if existing == GalleryAutoClassifier.placeholderTerms { return true }
        let legacy = GalleryAutoClassifier.correctableTerms[dimension] ?? []
        return !legacy.isEmpty && existing == legacy
    }

    /// 引擎的公共入口：规则 + 相似图/本机视觉，按组键去重，供「待确认」箱整体刷新。
    nonisolated static func suggestions(for records: [MaterialRecord],
                                        progress: (@Sendable (Progress) -> Void)? = nil) async -> [MaterialTaggingState.Suggestion] {
        let rules = ruleSuggestions(for: records)
        let visual = await similaritySuggestions(for: records, progress: progress)
        var seen: Set<String> = []
        return (rules + visual).filter { seen.insert($0.groupKey).inserted }
    }

    // MARK: - 命名规则

    /// 按「维度 + 词」汇总规则命中，每个词一条建议。
    nonisolated static func ruleSuggestions(for records: [MaterialRecord]) -> [MaterialTaggingState.Suggestion] {
        var accumulator = RuleAccumulator()
        for record in records { accumulator.add(record) }
        return accumulator.suggestions()
    }

    /// 逐张跑命名规则并按张上报进度：导入增量走这条，才能显示「已索引 120 / 300」而不必全库重跑。
    nonisolated static func ruleSuggestions(
        for records: [MaterialRecord],
        progress: (@Sendable (Progress) -> Void)?
    ) async -> [MaterialTaggingState.Suggestion] {
        var accumulator = RuleAccumulator()
        for (offset, record) in records.enumerated() {
            if Task.isCancelled { break }
            accumulator.add(record)
            let done = offset + 1
            if done == records.count || done % 24 == 0 {
                progress?(Progress(indexed: done, total: records.count))
                await Task.yield()
            }
        }
        return accumulator.suggestions()
    }

    /// 命名规则的逐张累加器：整库扫描和导入增量共用同一套装箱口径。
    struct RuleAccumulator: Sendable {
        private struct Bucket {
            var ids: [String] = []
            var basis: Set<String> = []
            var fromFilename = 0
            var conflicts = 0
        }
        private var buckets: [String: Bucket] = [:]

        /// 单张图片的规则命中入箱；非图片、已删除、无路径或只命中占位默认值的图片不产生建议。
        mutating func add(_ record: MaterialRecord) {
            guard record.deletedAt == nil, record.kind == .image, let path = record.sourcePath else { return }
            let result = GalleryAutoClassifier.classify(
                path: path,
                filename: record.originalFilename,
                pixelWidth: record.mediaMetadata?.pixelWidth ?? 0,
                pixelHeight: record.mediaMetadata?.pixelHeight ?? 0
            )
            let current = record.classification ?? MaterialClassification()
            for (dimension, terms) in result.values {
                guard let term = terms.first, !term.isEmpty else { continue }
                // 规则没命中时写下的占位值不是判断结果，不进箱。
                guard result.evidence[dimension] != "默认" else { continue }
                guard allowsSuggestion(existing: current.terms(for: dimension), dimension: dimension) else { continue }
                if current.terms(for: dimension) == [term] { continue }
                var bucket = buckets[dimension + "\u{1}" + term] ?? Bucket()
                bucket.ids.append(record.id)
                bucket.basis.insert(basisLabel(result.evidence[dimension] ?? ""))
                if (result.evidence[dimension] ?? "").contains("文件名") { bucket.fromFilename += 1 }
                if !result.conflicts.isEmpty { bucket.conflicts += 1 }
                buckets[dimension + "\u{1}" + term] = bucket
            }
        }

        func suggestions() -> [MaterialTaggingState.Suggestion] {
            buckets.map { key, bucket in
                let parts = key.components(separatedBy: "\u{1}")
                let dimension = parts[0], name = parts[1]
                var suggestion = MaterialTaggingState.Suggestion(
                    groupKey: groupKey(dimension: dimension, name: name, engine: "规则"),
                    dimension: dimension, name: name,
                    materialIDs: bucket.ids.sorted(), basis: sortedBasis(bucket.basis), engine: "规则"
                )
                suggestion.confidence = ruleConfidence(total: bucket.ids.count, fromFilename: bucket.fromFilename, conflicts: bucket.conflicts)
                suggestion.detail = "命名规则命中 \(bucket.ids.count) 张" +
                    (bucket.conflicts > 0 ? "；其中 \(bucket.conflicts) 张同时命中冲突结论" : "")
                return suggestion
            }.sorted { ($0.dimension, -$0.materialIDs.count, $0.name) < ($1.dimension, -$1.materialIDs.count, $1.name) }
        }
    }

    private static func ruleConfidence(total: Int, fromFilename: Int, conflicts: Int) -> String {
        if conflicts > 0 { return "低" }
        if fromFilename == total { return "高" }
        return fromFilename > 0 || total >= 3 ? "中" : "低"
    }

    /// 规则给出的依据原文转成界面可读的来源名。
    private static func basisLabel(_ evidence: String) -> String {
        switch evidence {
        case "文件名": return "文件名"
        case "目录名", "路径": return "目录名"
        case "文件名/目录": return "文件名/目录名"
        case "产品线": return "产品线推断"
        case "像素尺寸": return "像素尺寸"
        case "默认": return "默认值"
        default: return evidence.isEmpty ? "命名规则" : evidence
        }
    }

    static func sortedBasis(_ basis: Set<String>) -> [String] {
        let preferred = ["目录名", "文件名", "识图内容", "相似图"]
        return preferred.filter { basis.contains($0) } + basis.subtracting(preferred).sorted()
    }

    // MARK: - 相似图与本机视觉

    private struct Reference: Sendable { var name: String; var path: String }
    private struct Prototype: Sendable { var name: String; var feature: Data }
    private struct Row: Sendable { var id: String; var feature: Data?; var labels: [String]; var folder: String }
    private struct Cluster: Sendable { var ids: [String]; var labels: [String]; var folders: [String] }

    /// 资产类型为空的照片：先与「已有资产类型」的参考图找相似；剩下的再互相聚类，按 Vision 标签或目录名命名。
    ///
    /// `progress` 提供「已索引 120 / 300」；分块之间检查取消，暂停导入或关闭窗口都会立刻停下。
    nonisolated static func similaritySuggestions(
        for records: [MaterialRecord],
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async -> [MaterialTaggingState.Suggestion] {
        let images = records.filter { $0.deletedAt == nil && $0.kind == .image && $0.sourcePath != nil }
        let targets = images
            .filter { allowsSuggestion(existing: $0.classification?.terms(for: "asset_type") ?? [], dimension: "asset_type") }
            .sorted { $0.id < $1.id }
        let references = referenceRecords(from: images)
        guard !targets.isEmpty else {
            progress?(Progress(indexed: 0, total: 0))
            return []
        }
        let batch = Array(targets.prefix(maximumClusterInputs))
        let worker = Task.detached(priority: .utility) { () -> [MaterialTaggingState.Suggestion] in
            var rows: [Row] = []
            rows.reserveCapacity(batch.count)
            for (offset, record) in batch.enumerated() {
                if offset % 16 == 0 {
                    if Task.isCancelled { break }
                    progress?(Progress(indexed: offset, total: batch.count))
                }
                guard let path = record.sourcePath else { continue }
                let classified = autoreleasepool { LocalImageClassifier.classify(atPath: path, generateFeaturePrint: true) }
                rows.append(Row(id: record.id, feature: classified.featurePrintData,
                                  labels: classified.labels, folder: folderName(path)))
            }
            progress?(Progress(indexed: batch.count, total: batch.count))
            let prototypes: [Prototype] = references.compactMap { reference in
                guard let feature = ProjectImageIndexer.featurePrintData(atPath: reference.path) else { return nil }
                return Prototype(name: reference.name, feature: feature)
            }

            var matched: [String: [String]] = [:]
            var leftovers: [Row] = []
            for (offset, row) in rows.enumerated() {
                if offset % 64 == 0, Task.isCancelled { break }
                guard let feature = row.feature else { leftovers.append(row); continue }
                var votes: [String: Double] = [:]
                for prototype in prototypes {
                    guard let distance = ProjectImageIndexer.featurePrintDistance(feature, prototype.feature),
                          distance <= similarDistanceLimit else { continue }
                    votes[prototype.name, default: 0] += Double(1 - distance / similarDistanceLimit)
                }
                if let winner = votes.max(by: { $0.value < $1.value })?.key { matched[winner, default: []].append(row.id) }
                else { leftovers.append(row) }
            }

            var suggestions: [MaterialTaggingState.Suggestion] = matched
                .filter { !$0.value.isEmpty }
                .map { name, ids in
                    var suggestion = similarityGroup(dimension: "asset_type", name: name, ids: ids, engine: "相似图", basis: ["相似图"],
                                                     detail: "与已有「\(name)」资产类型的参考图相似（距离 ≤ \(similarDistanceLimit)）")
                    suggestion.isNewTerm = ClassificationVocabulary.term(name, in: "asset_type") == nil
                    return suggestion
                }
            for cluster in leaderClusters(leftovers) {
                if let visionName = mappedAssetTypeNames(cluster.labels).first {
                    suggestions.append(similarityGroup(dimension: "asset_type", name: visionName, ids: cluster.ids, engine: "本机视觉",
                                                       basis: ["识图内容"],
                                                       detail: "本机 Vision 识别到「\(Array(Set(cluster.labels).prefix(3)).joined(separator: "、"))」"))
                } else {
                    let folder = cluster.folders.mostCommon() ?? "未分组图片"
                    let known = ClassificationVocabulary.term(folder, in: "asset_type")
                    var suggestion = similarityGroup(dimension: "asset_type", name: known?.canonical ?? folder, ids: cluster.ids,
                                                     engine: "相似图", basis: ["相似图", "目录名"],
                                                     detail: known == nil
                                                         ? "\(cluster.ids.count) 张图互相相似且集中在「\(folder)」目录；词表里没有这个词，需确认是否新增"
                                                         : "\(cluster.ids.count) 张图互相相似，目录「\(folder)」已在词表中")
                    suggestion.isNewTerm = known == nil
                    suggestions.append(suggestion)
                }
            }
            if targets.count > batch.count {
                for index in suggestions.indices {
                    suggestions[index].detail += "；本轮只索引前 \(batch.count) 张，剩余 \(targets.count - batch.count) 张待下轮"
                }
            }
            return suggestions.sorted { ($0.engine, -$0.materialIDs.count, $0.name) < ($1.engine, -$1.materialIDs.count, $1.name) }
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }

    /// 参考图 = 已经有资产类型、且该值不是占位/旧版误判的图片。
    private static func referenceRecords(from images: [MaterialRecord]) -> [Reference] {
        var grouped: [String: [Reference]] = [:]
        for record in images {
            guard let path = record.sourcePath else { continue }
            let current = record.classification?.terms(for: "asset_type") ?? []
            guard current.count == 1, !allowsSuggestion(existing: current, dimension: "asset_type") else { continue }
            grouped[current[0], default: []].append(Reference(name: current[0], path: path))
        }
        return grouped.values.flatMap { Array($0.sorted { $0.path < $1.path }.prefix(referencesPerType)) }
    }

    /// leader 聚类：每张图只与已有簇的代表比较，代价是 图数 × 簇数，簇数封顶 `maximumClusters`。
    private static func leaderClusters(_ rows: [Row]) -> [Cluster] {
        var clusters: [Cluster] = []
        var representatives: [Data] = []
        for row in rows {
            guard let feature = row.feature else { continue }
            if let index = representatives.firstIndex(where: {
                guard let distance = ProjectImageIndexer.featurePrintDistance($0, feature) else { return false }
                return distance <= similarDistanceLimit
            }) {
                clusters[index].ids.append(row.id)
                clusters[index].labels.append(contentsOf: row.labels)
                clusters[index].folders.append(row.folder)
            } else {
                guard clusters.count < maximumClusters else { continue }
                representatives.append(feature)
                clusters.append(Cluster(ids: [row.id], labels: row.labels, folders: [row.folder]))
            }
        }
        return clusters.filter { $0.ids.count >= 2 }
    }

    private static func similarityGroup(dimension: String, name: String, ids: [String], engine: String,
                                        basis: [String], detail: String) -> MaterialTaggingState.Suggestion {
        var suggestion = MaterialTaggingState.Suggestion(
            groupKey: groupKey(dimension: dimension, name: name, engine: engine),
            dimension: dimension, name: name, materialIDs: ids.sorted(), basis: basis, engine: engine
        )
        suggestion.confidence = ids.count >= 8 ? "中" : "低"
        suggestion.detail = detail
        return suggestion
    }

    /// 本机 Vision 的英文标签映射到词表里的资产类型标准词；映射不到返回空，交给目录名兜底。
    static func mappedAssetTypeNames(_ labels: [String]) -> [String] {
        let lowered = labels.map { $0.lowercased() }
        let groups: [(String, [String])] = [
            ("人物角色", ["person", "people", "portrait", "face", "man", "woman", "child"]),
            ("场景", ["building", "architecture", "room", "landscape", "street", "city", "indoor", "outdoor"]),
            ("道具", ["cup", "mug", "bottle", "container", "box", "package", "tool", "furniture"]),
            ("品牌标识", ["logo", "letter", "text", "word", "sign", "symbol"]),
            ("色卡", ["palette", "gradient", "swatch"])
        ]
        return groups.compactMap { name, keywords in
            guard lowered.contains(where: { label in keywords.contains(where: label.contains) }),
                  ClassificationVocabulary.term(name, in: "asset_type") != nil else { return nil }
            return name
        }
    }

    static func folderName(_ path: String) -> String {
        let segments = path.split(separator: "/").map(String.init).filter { !GalleryAutoClassifier.projectRootNames.contains($0) }
        return segments.dropLast().last ?? "未分组图片"
    }

    // MARK: - 决定回放与入箱

    /// 一条「按用户既有决定直接写入正式分类」的回放项。
    struct StandingWrite: Equatable, Sendable {
        var groupKey: String
        var dimension: String
        var name: String
        var materialIDs: [String]
    }

    /// 把一次新扫描的结果按用户决定分成「直接写入」和「进箱待确认」。
    ///
    /// 同一组做过多次决定时以最后一次为准（先拆分、后采纳是正常路径）。
    /// - 采纳／改名后采纳／合并：沿用当时的名字直接写入，不再问第二次。
    /// - 忽略：箱里留一条「已忽略」，不写分类。
    /// - 拆分：只把用户留下的那批继续问，拆走的图片不再算回本组。
    /// - 没有决定过的组：原样进箱。
    static func replay(_ fresh: [MaterialTaggingState.Suggestion], decisions: [MaterialTaggingState.Decision])
        -> (autoApply: [StandingWrite], ask: [MaterialTaggingState.Suggestion]) {
        var autoApply: [StandingWrite] = []
        var ask: [MaterialTaggingState.Suggestion] = []
        for suggestion in fresh {
            guard let decision = decisions.last(where: { $0.groupKey == suggestion.groupKey }) else {
                ask.append(suggestion)
                continue
            }
            switch decision.action {
            case "忽略":
                var ignored = suggestion
                ignored.status = "已忽略"
                ignored.decidedAt = decision.decidedAt
                ask.append(ignored)
            case "拆分":
                let kept = Set(decision.materialIDs)
                var reduced = suggestion
                reduced.materialIDs.removeAll { !kept.contains($0) }
                guard !reduced.materialIDs.isEmpty else { continue }
                reduced.detail += "；已按你的拆分去掉 \(suggestion.itemCount - reduced.itemCount) 张"
                ask.append(reduced)
            default:
                autoApply.append(StandingWrite(groupKey: suggestion.groupKey, dimension: suggestion.dimension,
                                               name: decision.name, materialIDs: suggestion.materialIDs))
            }
        }
        return (autoApply, ask)
    }

    /// 建议落进箱：新组追加，旧组更新统计字段但保留 id 与创建时间（界面选中不丢），处理过的组不回退成待确认。
    ///
    /// - Parameter unionWithExisting: 增量扫描（只喂本次新增图片）时传真，把箱里同组已有的图片并回来，
    ///   否则一次增量入箱会顶掉整库扫描攒下的待确认张数；全库扫描的结果本身就是完整集合，传假。
    static func mergedBox(_ existing: [MaterialTaggingState.Suggestion], _ fresh: [MaterialTaggingState.Suggestion],
                          unionWithExisting: Bool) -> [MaterialTaggingState.Suggestion] {
        var box = existing
        for suggestion in fresh {
            guard let position = box.firstIndex(where: { $0.groupKey == suggestion.groupKey }) else {
                box.append(suggestion)
                continue
            }
            guard box[position].status == "待确认" else { continue }
            var updated = suggestion
            if unionWithExisting {
                updated.materialIDs = Array(Set(box[position].materialIDs).union(suggestion.materialIDs)).sorted()
            }
            updated.id = box[position].id
            updated.createdAt = box[position].createdAt
            box[position] = updated
        }
        return box
    }
}

private extension Array where Element == String {
    func mostCommon() -> String? {
        Dictionary(grouping: self, by: { $0 }).map { ($0.key, $0.value.count) }.max { $0.1 < $1.1 }?.0
    }
}
