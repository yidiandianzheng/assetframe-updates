import Foundation

/// 「待确认」分类箱：不覆盖手工分类的门、规则分组与稳定组键、依据与把握的文字口径、
/// 本机视觉命名映射、撤销补丁与 SQLite 落盘往返。全程不读真实图片、不联网。
@main struct ClassificationSuggestionSelfTest {
    static func main() async throws {
        gateOnlyAsksAboutNonUserValues()
        progressStateRejectsStaleAndOutOfOrder()
        indexScopeUsesCommittedSnapshot()
        ruleBucketsAndStableKeys()
        basisAndConfidenceWording()
        await ruleProgressCoversEveryImage()
        visualNamingHelpers()
        decisionReplayAndBoxMerge()
        await similarityAsksNothingWithoutTargets()
        undoCoversSuggestionsAndDecisions()
        try await taggingStateDecodesWithoutNewKeys()
        try await databaseRoundTrip()
        print("ClassificationSuggestionSelfTest passed: never-overwrite gate, progress state, incremental import scope, rule buckets, stable group keys, rule per-image progress, basis/confidence wording, vision naming, decision replay, box merge, undo, database round trip")
    }

    // MARK: - 永不覆盖

    private static func gateOnlyAsksAboutNonUserValues() {
        precondition(ClassificationSuggestionEngine.allowsSuggestion(existing: [], dimension: "asset_type"), "空分类应可以提问")
        precondition(ClassificationSuggestionEngine.allowsSuggestion(existing: GalleryAutoClassifier.placeholderTerms, dimension: "usage"),
                     "规则当年写下的占位值应允许再次提问")
        precondition(ClassificationSuggestionEngine.allowsSuggestion(existing: ["实拍照片"], dimension: "asset_kind"),
                     "旧版误判值应允许纠正")
        precondition(!ClassificationSuggestionEngine.allowsSuggestion(existing: ["实拍照片"], dimension: "asset_type"),
                     "可纠正值按维度登记，不能跨维度生效")
        // 用户手工设置或采纳过的值：任何形式的非空结论都不再提问。
        for existing in [["人物角色"], ["场景", "道具"], ["设计素材", "其他"], ["未知自定义词"]] {
            precondition(!ClassificationSuggestionEngine.allowsSuggestion(existing: existing, dimension: "asset_type"),
                         "已有分类 \(existing) 不得被自动结果覆盖")
        }
    }

    // MARK: - 规则分组

    private static func ruleBucketsAndStableKeys() {
        let records = [
            image(id: "p1", path: "/Volumes/库/01_公共资产库/01_人物/人物01.png"),
            image(id: "p2", path: "/Volumes/库/01_公共资产库/01_人物/人物02.png"),
            // 手工分类过的图不再出现在同一组里。
            manual(image(id: "p3", path: "/Volumes/库/01_公共资产库/01_人物/人物03.png"), "asset_type", ["场景"]),
            // 只写进占位用途值的产品图：「默认」结论不进箱。
            image(id: "prod", path: "/Volumes/库/04_产品/茶盈航罐子01.png"),
            image(id: "brand", path: "/Volumes/库/杂项/茶盈航礼盒.png"),
            // 非图片与被删除的素材不参与。
            image(id: "movie", path: "/Volumes/库/杂项/片段.mov", kind: .video),
            deleted(image(id: "gone", path: "/Volumes/库/01_公共资产库/01_人物/人物99.png"))
        ]
        let first = ClassificationSuggestionEngine.ruleSuggestions(for: records)
        let second = ClassificationSuggestionEngine.ruleSuggestions(for: records)

        precondition(!first.isEmpty, "规则命中应产生建议")
        precondition(Set(first.map(\.groupKey)).count == first.count, "组键必须唯一")
        precondition(first.map(\.groupKey).sorted() == second.map(\.groupKey).sorted(), "同一批数据重跑组键必须一致")
        precondition(first.allSatisfy { $0.engine == "规则" && $0.status == "待确认" }, "规则建议来源固定为规则、状态固定为待确认")
        precondition(first.allSatisfy { $0.sampleIDs.count <= 4 }, "样图最多 4 张")

        let personType = first.first { $0.dimension == "asset_type" && $0.name == "人物角色" }
        precondition(personType?.materialIDs == ["p1", "p2"], "已有手工分类的图与被删除的素材不得进组，成员需排序")
        precondition(personType?.itemCount == 2 && personType?.sampleIDs.count == 2)
        precondition(!(first.contains { $0.dimension == "asset_type" && $0.name == "场景" }), "规则没给出的名字不应凭空出现")

        // 「默认」占位值不进箱，但同一张图的真实命中照常进箱。
        precondition(!first.contains { $0.dimension == "usage" }, "占位用途值不是判断结果，不得进箱")
        precondition(first.contains { $0.dimension == "organize_status" && $0.materialIDs == ["prod"] },
                     "同一张图的真实命中不应被占位值连带挡掉")
        precondition(!first.contains { $0.materialIDs.contains("movie") }, "视频不参与图库命名规则")

        let grouped = ClassificationSuggestionEngine.groupKey(dimension: "asset_type", name: "人物角色", engine: "规则")
        precondition(grouped == "cls:规则|asset_type|人物角色", "组键口径：\(grouped)")
        precondition(grouped != ClassificationSuggestionEngine.groupKey(dimension: "asset_type", name: "人物角色", engine: "相似图"),
                     "不同来源引擎不能共用一个组键")
    }

    // MARK: - 依据与把握

    private static func basisAndConfidenceWording() {
        precondition(ClassificationSuggestionEngine.sortedBasis(Set(["相似图", "文件名", "目录名", "像素尺寸"])) == ["目录名", "文件名", "相似图", "像素尺寸"],
                     "依据按固定口径排序，未知来源排在后面")
        precondition(ClassificationSuggestionEngine.sortedBasis(Set(["识图内容"])) == ["识图内容"])
        precondition(ClassificationSuggestionEngine.sortedBasis(Set()).isEmpty)

        let records = [
            image(id: "b1", path: "/Volumes/库/杂项/茶盈航礼盒01.png"),
            image(id: "b2", path: "/Volumes/库/杂项/茶盈航礼盒02.png"),
            image(id: "s1", path: "/Volumes/库/01_公共资产库/01_人物/人物01.png"),
            image(id: "s2", path: "/Volumes/库/01_公共资产库/01_人物/人物02.png")
        ]
        let suggestions = ClassificationSuggestionEngine.ruleSuggestions(for: records)
        let allowed = ["高", "中", "低"]
        precondition(suggestions.allSatisfy { allowed.contains($0.confidence) }, "把握程度必须是文字档位")
        precondition(suggestions.allSatisfy { !$0.basis.isEmpty && $0.basis.allSatisfy { !$0.isEmpty } }, "每条建议都要给出依据")
        precondition(suggestions.allSatisfy { !$0.detail.isEmpty }, "每条建议都要给出可解释的说明")

        let brand = suggestions.first { $0.dimension == "brand" && $0.name == "茶盈航" }
        precondition(brand?.basis == ["文件名"], "文件名命中应写明依据是文件名")
        precondition(brand?.confidence == "高", "全部来自文件名的命中把握为高")
        let directory = suggestions.first { $0.dimension == "asset_type" && $0.name == "人物角色" }
        precondition(directory?.basis == ["目录名"], "目录命中应写明依据是目录名")
        precondition(directory?.confidence == "低", "只有两张且仅靠目录推断时不给高档位")
    }

    // MARK: - 视觉命名

    /// 导入增量靠这条逐张上报进度：档数足够、进度不回退、总数固定为本次图片数，
    /// 且装箱结果与整库扫描的同步路径一致（两条路径共用同一个累加器）。
    private static func ruleProgressCoversEveryImage() async {
        let records = (1...60).map { index in
            image(id: "img\(index)", path: "/Volumes/库/01_公共资产库/01_人物/人物\(String(format: "%02", index)).png")
        }
        let log = ProgressLog()
        let stepped = await ClassificationSuggestionEngine.ruleSuggestions(for: records) { log.append($0) }
        let readings = log.all

        precondition(readings.last == ClassificationSuggestionEngine.Progress(indexed: 60, total: 60),
                     "进度必须报到最后一张，收尾一档不能漏")
        precondition(readings.allSatisfy { $0.total == 60 }, "总数应为本次图片数，否则界面显示的就是全库重跑")
        precondition(readings.count >= 3, "60 张要分多档上报，界面才看得到「已索引 x / y」在动")
        precondition(readings.map(\.indexed) == readings.map(\.indexed).sorted(), "逐张进度不得回退")
        precondition(stepped.first { $0.dimension == "asset_type" && $0.name == "人物角色" }?.materialIDs.count == 60,
                     "逐张路径应把本次全部命中都装进同一组")
        precondition(stepped.map(\.groupKey).sorted() == ClassificationSuggestionEngine.ruleSuggestions(for: records).map(\.groupKey).sorted(),
                     "带进度的逐张路径与整库路径必须同口径")
    }

    private static func visualNamingHelpers() {
        precondition(ClassificationSuggestionEngine.mappedAssetTypeNames(["person", "building", "cup"]) == ["人物角色", "场景", "道具"])
        precondition(ClassificationSuggestionEngine.mappedAssetTypeNames(["Portrait"]) == ["人物角色"], "标签大小写不影响映射")
        precondition(ClassificationSuggestionEngine.mappedAssetTypeNames(["snowfield"]).isEmpty, "映射不到时不得编造名字")
        precondition(ClassificationSuggestionEngine.mappedAssetTypeNames(["person", "logo", "palette"]).allSatisfy {
            ClassificationVocabulary.term($0, in: "asset_type") != nil
        }, "视觉映射只能给出词表里已有的词")
        precondition(ClassificationSuggestionEngine.folderName("/Volumes/库/04_产品/a.png") == "04_产品")
        precondition(ClassificationSuggestionEngine.folderName("/中茶木兰姐/人物资产/a.png") == "人物资产", "项目容器名不作为分组名")
        precondition(ClassificationSuggestionEngine.folderName("a.png") == "未分组图片")
    }

    /// 已有资产类型的库不该触发相似图索引；这条路径必须在不读画面的情况下直接返回。
    private static func similarityAsksNothingWithoutTargets() async {
        let records = [
            manual(image(id: "r1", path: "/Volumes/库/01_公共资产库/01_人物/人物01.png"), "asset_type", ["人物角色"]),
            manual(image(id: "r2", path: "/Volumes/库/01_公共资产库/01_人物/人物02.png"), "asset_type", ["场景"])
        ]
        let log = ProgressLog()
        let visual = await ClassificationSuggestionEngine.similaritySuggestions(for: records) { log.append($0) }
        precondition(visual.isEmpty, "资产类型都已填写时不应生成相似图建议")
        precondition(log.all == [ClassificationSuggestionEngine.Progress(indexed: 0, total: 0)], "无目标也要回报 0 / 0 进度")

        let all = await ClassificationSuggestionEngine.suggestions(for: [])
        precondition(all.isEmpty, "空库不应有任何建议")
    }

    private static func undoCoversSuggestionsAndDecisions() {
        var before = MaterialTaggingState()
        before.suggestions = [suggestion(id: "s-1", group: "cls:规则|asset_type|人物角色", name: "人物角色", ids: ["p1", "p2"])]
        var after = before
        after.suggestions?[0].status = "已采纳"
        after.suggestions?.append(suggestion(id: "s-2", group: "cls:相似图|asset_type|茶罐", name: "茶罐", ids: ["p9"], isNewTerm: true))
        after.decisions = [decision(id: "d-1", group: "cls:规则|asset_type|人物角色", action: "采纳", name: "人物角色", ids: ["p1", "p2"])]

        let changes = try! MaterialTaggingUndo.changes(before: before, after: after)
        precondition(changes.contains { $0.section == .suggestions }, "建议变化必须进撤销记录")
        precondition(changes.contains { $0.section == .decisions }, "用户决定必须进撤销记录")
        let restored = try! MaterialTaggingUndo.restore(changes, in: after)
        precondition(restored == before, "撤销要同时回退建议状态与用户决定")

        // 当前值与补丁不匹配时报冲突，不能静默写坏。
        var drifted = after
        drifted.suggestions?[0].name = "被别处改掉了"
        precondition(throwsConflict { _ = try MaterialTaggingUndo.restore(changes, in: drifted) }, "撤销前的行级校验要拦住漂移")
    }

    private static func throwsConflict(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch is MaterialUndoPatch.Conflict { return true } catch { return false }
    }

    // MARK: - 旧库兼容

    private static func taggingStateDecodesWithoutNewKeys() async throws {
        var modern = MaterialTaggingState()
        modern.proposals = [MaterialTaggingState.Proposal(materialID: "m", inputKey: "i", baseInputKey: nil, imagePath: "/a.png",
                                                          imageDigest: "d", catalogKey: "c", relationKey: "r")]
        modern.suggestions = [suggestion(id: "s-1", group: "g-1", name: "人物角色", ids: ["p1", "p2", "p3", "p4", "p5"])]
        modern.decisions = [decision(id: "d-1", group: "g-1", action: "采纳", name: "人物角色", ids: ["p1", "p2"])]
        let data = try JSONEncoder().encode(modern)

        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "suggestions")
        object.removeValue(forKey: "decisions")
        let decoded = try JSONDecoder().decode(MaterialTaggingState.self, from: JSONSerialization.data(withJSONObject: object))
        precondition(decoded.suggestions == nil && decoded.decisions == nil, "旧库缺少新键应解码为 nil，不能解码失败")
        precondition(decoded.proposals.count == 1 && decoded.pendingSuggestions.isEmpty)
        precondition(decoded.decision(for: "g-1") == nil)

        let restored = try JSONDecoder().decode(MaterialTaggingState.self, from: data)
        precondition(restored.pendingSuggestions.count == 1)
        precondition(restored.decision(for: "g-1")?.action == "采纳")
        precondition(restored.suggestions?.first?.sampleIDs.count == 4, "样图最多 4 张")
        precondition(restored.suggestions?.first?.itemCount == 5, "涉及张数按整组成员计")
        precondition(MaterialTaggingState().isEmpty, "空箱不该让整份元数据被判为非空")
    }

    // MARK: - 落盘

    private static func databaseRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("assetframe-suggestion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = MaterialDatabase(root: root)
        let empty = try await database.load()
        precondition(empty.tagging == nil)

        var state = MaterialTaggingState()
        state.suggestions = [
            suggestion(id: "s-1", group: "cls:规则|asset_type|人物角色", name: "人物角色", ids: ["p1", "p2"]),
            suggestion(id: "s-2", group: "cls:相似图|asset_type|茶罐", name: "茶罐", ids: ["p9"], isNewTerm: true, confidence: "低")
        ]
        state.decisions = [decision(id: "d-1", group: "cls:规则|asset_type|人物角色", action: "忽略", name: "人物角色", ids: [])]
        var withBox = empty
        withBox.tagging = state
        try await database.commit(withBox, previous: empty)
        let reopened = try await database.load()
        precondition(reopened.tagging?.suggestions == state.suggestions, "建议必须原样落盘与回读")
        precondition(reopened.tagging?.decisions == state.decisions, "用户决定要单独持久化")
        precondition(reopened.tagging?.pendingSuggestions.count == 2)

        // 清箱后只剩决定：空数组回读为 nil，且不抹掉用户已做过的决定。
        var onlyDecisions = reopened
        onlyDecisions.tagging?.suggestions = nil
        try await database.commit(onlyDecisions, previous: reopened)
        let afterClear = try await database.load()
        precondition(afterClear.tagging?.suggestions == nil, "清空后的箱不应回读为空数组")
        precondition(afterClear.tagging?.decisions == state.decisions, "清箱不得抹掉用户已做过的决定")

        // 从未用过建议箱的库：提交一次无关改动后仍不应出现箱内容。
        let plainRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("assetframe-suggestion-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: plainRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plainRoot) }
        let plain = MaterialDatabase(root: plainRoot)
        let loadedPlain = try await plain.load()
        var withTermOnly = loadedPlain
        withTermOnly.tagging = MaterialTaggingState(terms: [MaterialTaggingState.Term(id: "t1", name: "自定义词", dimension: "brand")])
        try await plain.commit(withTermOnly, previous: loadedPlain)
        let reloadedPlain = try await plain.load()
        precondition(reloadedPlain.tagging?.suggestions == nil && reloadedPlain.tagging?.decisions == nil,
                     "未使用建议箱的库不应出现箱内容")
        precondition(reloadedPlain.tagging?.terms.count == 1)
    }

    // MARK: - 决定回放与入箱

    private static func decisionReplayAndBoxMerge() {
        let adopted = ClassificationSuggestionEngine.groupKey(dimension: "asset_type", name: "人物角色", engine: "规则")
        let ignored = ClassificationSuggestionEngine.groupKey(dimension: "asset_type", name: "场景", engine: "规则")
        let split = ClassificationSuggestionEngine.groupKey(dimension: "asset_type", name: "道具", engine: "规则")
        let merged = ClassificationSuggestionEngine.groupKey(dimension: "asset_type", name: "分镜", engine: "规则")
        let brandNew = ClassificationSuggestionEngine.groupKey(dimension: "asset_type", name: "色卡", engine: "规则")

        let fresh = [
            suggestion(id: "n1", group: adopted, name: "人物角色", ids: ["a1", "a2"]),
            suggestion(id: "n2", group: ignored, name: "场景", ids: ["b1"]),
            suggestion(id: "n3", group: split, name: "道具", ids: ["c1", "c2", "c3"]),
            suggestion(id: "n4", group: merged, name: "分镜", ids: ["d1"]),
            suggestion(id: "n5", group: brandNew, name: "色卡", ids: ["e1"])
        ]
        let decisions = [
            decision(id: "d1", group: adopted, action: "采纳", name: "人物角色", ids: ["a1", "a2"]),
            decision(id: "d2", group: ignored, action: "忽略", name: "场景", ids: []),
            // 拆分决定记的是「留下的那批」，拆走的图片不再算回本组。
            decision(id: "d3", group: split, action: "拆分", name: "道具", ids: ["c1"]),
            decision(id: "d4", group: merged, action: "合并", name: "人物角色", ids: ["d1"])
        ]

        let replay = ClassificationSuggestionEngine.replay(fresh, decisions: decisions)
        // 箱里进三条：忽略过的组（已忽略态）、拆分后还剩图片的组、没决定过的组。
        precondition(replay.ask.count == 3, "忽略组与拆分剩余组仍要在箱里可见，加上新组共三条：\(replay.ask.map(\.name))")
        precondition(replay.ask.contains { $0.groupKey == brandNew && $0.status == "待确认" }, "没决定过的组原样进箱")
        precondition(replay.ask.contains { $0.groupKey == ignored && $0.status == "已忽略" }, "忽略过的组以已忽略态留在箱里")
        precondition(replay.ask.first { $0.groupKey == split }?.materialIDs == ["c1"],
                     "拆分后重跑只问用户留下的图片")
        precondition(replay.ask.filter { $0.status == "待确认" }.map(\.groupKey) == [split, brandNew],
                     "只有没处理过的组才是待确认")

        precondition(Set(replay.autoApply.map(\.groupKey)) == [adopted, merged],
                     "采纳过与合并过的组按既有决定直接写入：\(replay.autoApply.map(\.groupKey))")
        precondition(replay.autoApply.first { $0.groupKey == merged }?.name == "人物角色",
                     "合并组的写入名取合并目标名")
        precondition(!replay.autoApply.contains { $0.groupKey == ignored }, "忽略过的组永不自动写入")

        // 忽略的组仍在箱里留一条「已忽略」，让用户看得到自己挡掉了什么。
        let ignoredReplay = ClassificationSuggestionEngine.replay(
            [suggestion(id: "n2", group: ignored, name: "场景", ids: ["b1"])],
            decisions: [decision(id: "d2", group: ignored, action: "忽略", name: "场景", ids: [])])
        precondition(ignoredReplay.autoApply.isEmpty && ignoredReplay.ask.count == 1)
        precondition(ignoredReplay.ask[0].status == "已忽略", "忽略组重跑后仍是已忽略")
        precondition(ignoredReplay.ask[0].decidedAt == fixedDate, "已忽略条目沿用用户做决定的时间")

        // 同一组先拆分、后采纳：以最后一次决定为准。
        let latestWins = ClassificationSuggestionEngine.replay(
            [suggestion(id: "n3", group: split, name: "道具", ids: ["c1", "c2"])],
            decisions: [decision(id: "d3", group: split, action: "拆分", name: "道具", ids: ["c1"]),
                        decision(id: "d5", group: split, action: "采纳", name: "道具", ids: ["c1"])])
        precondition(latestWins.autoApply.map(\.groupKey) == [split] && latestWins.ask.isEmpty,
                   "同一组的重复决定要按最后一次回放")

        // 拆分决定里留下的图片这次全没命中：本组不再提问。
        let nothingLeft = ClassificationSuggestionEngine.replay(
            [suggestion(id: "n3", group: split, name: "道具", ids: ["c9"])],
            decisions: [decision(id: "d3", group: split, action: "拆分", name: "道具", ids: ["c1"])])
        precondition(nothingLeft.ask.isEmpty && nothingLeft.autoApply.isEmpty, "留下集合为空时不该凭空造一组")

        // 入箱：全库扫描用替换，增量入箱必须并回箱里已有的待确认图片。
        let box = [suggestion(id: "old1", group: adopted, name: "人物角色", ids: ["a1", "a2"]),
                   suggestion(id: "old2", group: ignored, name: "场景", ids: ["b1", "b2"], status: "已忽略")]
        var incoming = suggestion(id: "new1", group: adopted, name: "人物角色", ids: ["a3", "a4"])
        incoming.createdAt = fixedDate.addingTimeInterval(60)

        let replaced = ClassificationSuggestionEngine.mergedBox(box, [incoming], unionWithExisting: false)
        precondition(replaced.count == 2, "同组重跑不新增条目，箱里条目数应保持不变")
        precondition(replaced[0].id == "old1", "复用原 id，界面选中不丢")
        precondition(replaced[0].createdAt == fixedDate, "复用原创建时间")
        precondition(replaced[0].materialIDs == ["a3", "a4"], "全库扫描的结果就是完整集合，直接替换")

        let unioned = ClassificationSuggestionEngine.mergedBox(box, [incoming], unionWithExisting: true)
        precondition(unioned[0].materialIDs == ["a1", "a2", "a3", "a4"],
                    "增量入箱必须并回已有待确认图片：\(unioned[0].materialIDs)")
        precondition(unioned[0].itemCount == 4 && unioned[0].sampleIDs.count == 4, "并集后样图仍最多 4 张")

        let ignoredKept = ClassificationSuggestionEngine.mergedBox(box, [
            suggestion(id: "new2", group: ignored, name: "场景", ids: ["b3"])
        ], unionWithExisting: true)
        precondition(ignoredKept[1].status == "已忽略" && ignoredKept[1].materialIDs == ["b1", "b2"],
                     "用户忽略过的组不回退成待确认，也不追加成员")

        let appended = ClassificationSuggestionEngine.mergedBox(box, [
            suggestion(id: "new3", group: brandNew, name: "色卡", ids: ["e1"])
        ], unionWithExisting: false)
        precondition(appended.count == 3 && appended.last?.groupKey == brandNew, "新组追加到箱尾")
    }

    // MARK: - 构造

    /// 固定到整秒：SQLite 载荷用秒级 ISO8601 编码日期，带小数秒的时间戳无法原样往返。
    private static let fixedDate = Date(timeIntervalSince1970: 1_735_689_600)

    private static func suggestion(id: String, group: String, name: String, ids: [String],
                                   isNewTerm: Bool = false, status: String = "待确认",
                                   confidence: String = "中") -> MaterialTaggingState.Suggestion {
        var value = MaterialTaggingState.Suggestion(id: id, groupKey: group, dimension: "asset_type", name: name,
                                                    isNewTerm: isNewTerm, materialIDs: ids, basis: ["目录名"], engine: "规则")
        value.status = status
        value.confidence = confidence
        value.detail = "自测用说明"
        value.createdAt = fixedDate
        return value
    }

    private static func decision(id: String, group: String, action: String, name: String,
                                 ids: [String]) -> MaterialTaggingState.Decision {
        MaterialTaggingState.Decision(id: id, groupKey: group, dimension: "asset_type", action: action,
                                      name: name, materialIDs: ids, decidedAt: fixedDate)
    }

    private static func image(id: String, path: String, kind: MaterialKind = .image) -> MaterialRecord {
        let filename = (path as NSString).lastPathComponent
        return MaterialRecord(id: id, kind: kind, name: filename, sourcePath: path, originalFilename: filename,
            fingerprint: "source:\(id)", sourceLocations: [], fileSize: 100, createdAt: fixedDate, tags: [], rating: 0, note: "")
    }

    private static func deleted(_ record: MaterialRecord) -> MaterialRecord {
        var value = record
        value.deletedAt = fixedDate
        return value
    }

    private static func manual(_ record: MaterialRecord, _ dimension: String, _ terms: [String]) -> MaterialRecord {
        var value = record
        value.mutateClassification { $0.set(terms, for: dimension) }
        return value
    }

    // MARK: - 进度状态机

    /// 乱序 hop 不回退、旧 epoch 不污染新任务、结束后迟到回写被丢弃。
    private static func progressStateRejectsStaleAndOutOfOrder() {
        var state = SuggestionProgressState()
        let first = state.begin(total: 60)
        precondition(state.isRunning && state.total == 60 && state.indexed == 0,
                     "开始一轮应把读数置为可观测状态")
        precondition(state.apply(indexed: 24, total: 60, epoch: first), "首档上报应被采纳")
        precondition(!state.apply(indexed: 12, total: 60, epoch: first), "乱序回写不能让进度回退")
        precondition(state.indexed == 24, "进度只增不减")

        let second = state.begin(total: 30)
        precondition(second != first, "新一轮必须换 epoch")
        precondition(!state.apply(indexed: 48, total: 60, epoch: first), "旧任务的在途回写必须丢弃")
        precondition(state.indexed == 0 && state.total == 30, "新任务不应继承旧读数")
        precondition(state.apply(indexed: 30, total: 30, epoch: second), "当前任务的上报应被采纳")
        precondition(state.finish(epoch: second), "当前任务可以结束")
        precondition(!state.finish(epoch: second), "同一任务不能结束两次")
        precondition(!state.apply(indexed: 30, total: 30, epoch: second), "结束后的迟到回写必须丢弃")
    }

    // MARK: - 导入增量取数

    /// 复现 V261023.11：提交态已有新增、发布态还停在导入前，不能把本次新增过滤成空数组。
    private static func indexScopeUsesCommittedSnapshot() {
        let old = image(id: "old", path: "/Volumes/库/杂项/旧图.png")
        let fresh = (1...3).map { image(id: "new\($0)", path: "/Volumes/库/01_公共资产库/01_人物/人物0\($0).png") }
        let before = Set([old.id])
        let committed = [old] + fresh
        let added = SuggestionIndexScope.newlyAdded(committed: committed, published: [old], before: before)
        precondition(added.map(\.id) == fresh.map(\.id), "发布态滞后时仍应取到本次新增的全部记录")
        precondition(SuggestionIndexScope.newlyAdded(committed: [old], published: [old], before: before).isEmpty,
                     "没有新增时不应把旧记录当成增量")
        let fallback = SuggestionIndexScope.newlyAdded(committed: [old], published: committed, before: before)
        precondition(fallback.map(\.id) == fresh.map(\.id), "提交态取不到时发布态兜底应生效")
    }

    private final class ProgressLog: @unchecked Sendable {
        private var values: [ClassificationSuggestionEngine.Progress] = []
        func append(_ value: ClassificationSuggestionEngine.Progress) { values.append(value) }
        var all: [ClassificationSuggestionEngine.Progress] { values }
    }
}
