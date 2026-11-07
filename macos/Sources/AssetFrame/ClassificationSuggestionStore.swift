import Foundation

/// 索引入口的种类：只跑命名规则，或规则 + 本机视觉/相似图。
private enum SuggestionIndexMode {
    case rules(images: [MaterialRecord], unionWithExisting: Bool)
    case full(records: [MaterialRecord])
}

/// 「待确认」分类箱的库侧操作：刷新建议、四个动作、整批采纳与用户决定的持久化。
///
/// 所有写入都走 `changeTagging`，因此与候选标签共用同一个队列、乐观锁、备份和撤销栈。
/// 自动结果只进箱；正式分类只在用户明确采纳（或重新跑时沿用他自己已经做过的决定）时才写。
extension GlobalMaterialStore {
    /// 只跑命名规则的全库扫描：把命中结果放进「待确认」箱，不写正式分类。
    ///
    /// 导入结束、元数据补齐后自动调用；菜单「按命名生成待确认分类」和 CLI `classification.backfill` 是手工入口。
    /// 代价与图片数成正比但不读画面，所以能在导入流水结束后立即跑一次，不必手工重扫。
    @discardableResult
    func indexClassificationRules() async -> Int {
        await runRuleIndex(records: materials, unionWithExisting: false)
        return (tagging.suggestions ?? []).filter { $0.status == "待确认" }.count
    }

    /// 刷新建议：规则引擎 + 本机视觉/相似图，逐张报告「已索引 x / y」。
    ///
    /// 箱里已有的组保留原 id 与创建时间（界面选中不丢），用户决定过的组按决定处理、不再提问。
    @discardableResult
    func refreshClassificationSuggestions() async -> Int {
        await runSuggestionIndex(mode: .full(records: materials))
        return (tagging.suggestions ?? []).filter { $0.status == "待确认" }.count
    }

    /// 新导入的图片逐张增量入箱：只跑命名规则（不读画面、不调 Vision），相似图与本机视觉交给整库索引任务。
    /// 走与整库刷新同样的提交路径，因此用户已经做过的决定同样对新增图片生效。
    /// 逐张推进度，界面显示「已索引 120 / 300」；只处理本次导入的图，不全库重跑。
    func indexImportedImages(_ records: [MaterialRecord]) async {
        await runRuleIndex(records: records, unionWithExisting: true)
    }

    // MARK: - 索引任务的统一执行体

    /// 三个入口共用同一套进度状态与任务句柄：置位可观测计数、后台算规则、可取消、hop 按 epoch 有序采纳。
    @MainActor
    private func runRuleIndex(records: [MaterialRecord], unionWithExisting: Bool) async {
        let images = records.filter { $0.kind == .image && $0.deletedAt == nil && $0.sourcePath != nil }
        await runSuggestionIndex(mode: .rules(images: images, unionWithExisting: unionWithExisting))
    }

    @MainActor
    private func runSuggestionIndex(mode: SuggestionIndexMode) async {
        guard canWrite, !isSessionPaused else {
            toast = "资源库当前不可写入，未生成分类建议"
            return
        }
        let images: [MaterialRecord]
        let allRecords: [MaterialRecord]
        let unionWithExisting: Bool
        let isFull: Bool
        switch mode {
        case let .rules(value, union):
            images = value
            allRecords = value
            unionWithExisting = union
            isFull = false
        case let .full(value):
            allRecords = value
            images = value.filter { $0.kind == .image && $0.deletedAt == nil && $0.sourcePath != nil }
            unionWithExisting = false
            isFull = true
        }
        guard !images.isEmpty else { return }

        // 取消上一条任务并作废旧 epoch：面板「停止」与新任务都不会被在途的进度 hop 污染。
        suggestionIndexTask?.cancel()
        let epoch = beginSuggestionIndex(total: isFull ? 0 : images.count)
        let report: @Sendable (ClassificationSuggestionEngine.Progress) -> Void = { [weak self] value in
            Task { @MainActor in
                self?.applySuggestionProgress(indexed: value.indexed, total: value.total, epoch: epoch)
            }
        }
        let job = Task { [weak self] in
            guard let self else { return }
            let worker = Task.detached(priority: .utility) { () -> [MaterialTaggingState.Suggestion] in
                if isFull {
                    return await ClassificationSuggestionEngine.suggestions(for: allRecords, progress: report)
                }
                return await ClassificationSuggestionEngine.ruleSuggestions(for: images, progress: report)
            }
            let fresh = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, self.canWrite else {
                self.finishSuggestionIndexNow(epoch: epoch)
                return
            }
            // job 返回前把读数补到终值：最后一档的 MainActor hop 可能还排在队列里，
            // 外部验收（CLI status.store）不能依赖它是否已经落地。
            let finalTotal = self.suggestionProgress.total
            if finalTotal > 0 { self.applySuggestionProgress(indexed: finalTotal, total: finalTotal, epoch: epoch) }
            if !fresh.isEmpty || !unionWithExisting {
                await self.commitClassificationSuggestions(fresh, unionWithExisting: unionWithExisting)
            }
            self.endSuggestionIndex(epoch: epoch)
        }
        suggestionIndexTask = job
        await job.value
    }

    // MARK: - 进度状态

    /// 开一轮索引：作废旧 epoch，把三只 @Published 计数器置为可观测状态。
    @MainActor
    private func beginSuggestionIndex(total: Int) -> Int {
        let epoch = suggestionProgress.begin(total: total)
        publishSuggestionProgress()
        return epoch
    }

    /// 只采纳当前 epoch 的上报；indexed 单调不回退，0 / 0 的空目标回报不清掉分母。
    @MainActor
    private func applySuggestionProgress(indexed: Int, total: Int, epoch: Int) {
        guard total > 0, suggestionProgress.apply(indexed: indexed, total: total, epoch: epoch) else { return }
        publishSuggestionProgress()
    }

    @MainActor
    private func publishSuggestionProgress() {
        isIndexingSuggestions = suggestionProgress.isRunning
        suggestionIndexed = suggestionProgress.indexed
        suggestionIndexTotal = suggestionProgress.total
    }

    /// 取消即结束，不留延迟：面板「停止」按下后读数立刻停下。
    @MainActor
    private func finishSuggestionIndexNow(epoch: Int) {
        guard suggestionProgress.finish(epoch: epoch) else { return }
        publishSuggestionProgress()
    }

    /// 正常收尾：规则一趟常在一个采样间隔内跑完，保留最终读数约 0.7 秒，界面那行才看得见。
    @MainActor
    private func endSuggestionIndex(epoch: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self else { return }
            self.finishSuggestionIndexNow(epoch: epoch)
        }
    }

    // MARK: - 四个动作

    /// 采纳；`renamedTo` 非空即「改名后采纳」，之后重跑沿用新名字。
    @discardableResult
    func adoptClassificationSuggestion(_ id: String, renamedTo: String? = nil) async throws -> Int {
        let replacement = renamedTo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard renamedTo == nil || !replacement.isEmpty else { throw MaterialDatabase.error("改名后的分类名不能为空") }
        var written = 0
        var label = ""
        try await changeTagging(nil, undoable: true) { state, records in
            guard let index = state.suggestions?.firstIndex(where: { $0.id == id }),
                  state.suggestions?[index].status == "待确认" else {
                throw MaterialDatabase.error("这条建议已经处理过，请刷新后再确认")
            }
            var suggestion = state.suggestions![index]
            let name = renamedTo == nil ? suggestion.name : replacement
            guard name != suggestion.name || renamedTo == nil else { throw MaterialDatabase.error("新旧名称相同，直接采纳即可") }
            written = Self.writeClassification(dimension: suggestion.dimension, name: name, ids: suggestion.materialIDs, into: &records)
            suggestion.status = renamedTo == nil ? "已采纳" : "改名后采纳"
            suggestion.name = name
            suggestion.isNewTerm = ClassificationVocabulary.term(name, in: suggestion.dimension) == nil
            suggestion.decidedAt = .now
            state.suggestions![index] = suggestion
            state.decisions = (state.decisions ?? []) + [MaterialTaggingState.Decision(
                groupKey: suggestion.groupKey, dimension: suggestion.dimension,
                action: renamedTo == nil ? "采纳" : "改名后采纳", name: name, materialIDs: suggestion.materialIDs)]
            label = name
        }
        toast = written > 0 ? "「\(label)」已写入 \(written) 张图片的分类，可撤销" : "「\(label)」涉及的图片都已有手工分类，未覆盖"
        return written
    }

    /// 忽略：记下决定，重跑时这一组不再出现待确认条目。
    func ignoreClassificationSuggestion(_ id: String) async throws {
        try await changeTagging(nil, undoable: true) { state, _ in
            guard let index = state.suggestions?.firstIndex(where: { $0.id == id }),
                  state.suggestions?[index].status == "待确认" else {
                throw MaterialDatabase.error("这条建议已经处理过")
            }
            var suggestion = state.suggestions![index]
            suggestion.status = "已忽略"
            suggestion.decidedAt = .now
            state.suggestions![index] = suggestion
            state.decisions = (state.decisions ?? []) + [MaterialTaggingState.Decision(
                groupKey: suggestion.groupKey, dimension: suggestion.dimension, action: "忽略", name: suggestion.name)]
        }
        toast = "已忽略这条建议；重新跑分类时不会再问同一组"
    }

    /// 合并：把来源组的图片并进目标组，来源组记下「以后也按目标名字处理」。
    func mergeClassificationSuggestion(_ id: String, into targetID: String) async throws {
        try await changeTagging(nil, undoable: true) { state, _ in
            guard id != targetID else { throw MaterialDatabase.error("不能和自身合并") }
            guard let sourceIndex = state.suggestions?.firstIndex(where: { $0.id == id }),
                  let targetIndex = state.suggestions?.firstIndex(where: { $0.id == targetID }),
                  state.suggestions?[sourceIndex].status == "待确认", state.suggestions?[targetIndex].status == "待确认" else {
                throw MaterialDatabase.error("只能合并两条还没处理的建议")
            }
            let source = state.suggestions![sourceIndex]
            var target = state.suggestions![targetIndex]
            guard source.dimension == target.dimension else { throw MaterialDatabase.error("只能合并同一个分类维度的建议") }
            target.materialIDs = Array(Set(target.materialIDs).union(source.materialIDs)).sorted()
            target.basis = ClassificationSuggestionEngine.sortedBasis(Set(target.basis).union(source.basis))
            target.isNewTerm = target.isNewTerm || source.isNewTerm
            // 合并不改把握度：目标组自己的文件名/目录依据仍然成立，并入图片只是接受同一个名字。
            target.detail += "；并入了「\(source.name)」的 \(source.itemCount) 张"
            state.suggestions![targetIndex] = target
            var moved = source
            moved.status = "已合并"
            moved.mergedInto = target.id
            moved.decidedAt = .now
            state.suggestions![sourceIndex] = moved
            state.decisions = (state.decisions ?? []) + [MaterialTaggingState.Decision(
                groupKey: source.groupKey, dimension: source.dimension, action: "合并", name: target.name,
                materialIDs: source.materialIDs)]
        }
        toast = "已合并到目标建议，可撤销"
    }

    /// 拆分：把选中的图片另立一组待确认建议，原组留下其余图片。
    func splitClassificationSuggestion(_ id: String, name: String, materialIDs: [String]) async throws {
        let moved = Set(materialIDs)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MaterialDatabase.error("请填写拆出后的分类名") }
        try await changeTagging(nil, undoable: true) { state, _ in
            guard let index = state.suggestions?.firstIndex(where: { $0.id == id }),
                  state.suggestions?[index].status == "待确认" else {
                throw MaterialDatabase.error("这条建议已经处理过，无法拆分")
            }
            var source = state.suggestions![index]
            guard !moved.isEmpty, moved.count < source.materialIDs.count, Set(source.materialIDs).isSuperset(of: moved) else {
                throw MaterialDatabase.error("拆分要留下至少一张、移走至少一张，且只能移本组内的图片")
            }
            let childKey = ClassificationSuggestionEngine.groupKey(dimension: source.dimension, name: trimmed, engine: source.engine)
            guard childKey != source.groupKey, !(state.suggestions ?? []).contains(where: { $0.groupKey == childKey && $0.status == "待确认" }) else {
                throw MaterialDatabase.error("拆出的名称与本组或另一条待确认建议相同，请换一个名字")
            }
            source.materialIDs.removeAll { moved.contains($0) }
            source.detail += "；已拆出 \(moved.count) 张到「\(trimmed)」"
            state.suggestions![index] = source
            var child = MaterialTaggingState.Suggestion(
                groupKey: childKey, dimension: source.dimension, name: trimmed,
                isNewTerm: ClassificationVocabulary.term(trimmed, in: source.dimension) == nil,
                materialIDs: moved.sorted(), basis: source.basis, engine: source.engine,
                detail: "由「\(source.name)」拆出 \(moved.count) 张")
            child.confidence = "低"
            state.suggestions?.append(child)
            // 记下拆完剩下的那批：规则重跑会把整组图片再算进来，回放时要按这里过滤掉已拆走的。
            state.decisions = (state.decisions ?? []) + [MaterialTaggingState.Decision(
                groupKey: source.groupKey, dimension: source.dimension, action: "拆分", name: source.name,
                materialIDs: source.materialIDs)]
        }
        toast = "已拆出新建议，两组都可撤销"
    }

    /// 整批采纳：箱里所有待确认建议一次写入，只算一步撤销。
    @discardableResult
    func adoptAllClassificationSuggestions() async throws -> Int {
        let pending = tagging.pendingSuggestions
        guard !pending.isEmpty else { return 0 }
        var written = 0
        try await changeTagging(nil, undoable: true) { state, records in
            var decided: [MaterialTaggingState.Decision] = []
            guard var box = state.suggestions else { return }
            for index in box.indices {
                guard box[index].status == "待确认" else { continue }
                var suggestion = box[index]
                written += Self.writeClassification(dimension: suggestion.dimension, name: suggestion.name,
                                                    ids: suggestion.materialIDs, into: &records)
                suggestion.status = "已采纳"
                suggestion.decidedAt = .now
                box[index] = suggestion
                decided.append(MaterialTaggingState.Decision(groupKey: suggestion.groupKey, dimension: suggestion.dimension,
                                                             action: "采纳", name: suggestion.name, materialIDs: suggestion.materialIDs))
            }
            state.suggestions = box
            state.decisions = (state.decisions ?? []) + decided
        }
        toast = written > 0 ? "整批采纳：已写入 \(written) 张图片的分类，可撤销" : "整批采纳：这些图都已有手工分类，未覆盖"
        return written
    }

    // MARK: - 内部

    /// 写正式分类：只写该维度仍为空/占位/旧版误判的图片，其余一律跳过。
    @discardableResult
    private static func writeClassification(dimension: String, name: String, ids: [String], into records: inout [MaterialRecord]) -> Int {
        let positions = Dictionary(records.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var written = 0
        for id in ids {
            guard let index = positions[id], records[index].deletedAt == nil else { continue }
            guard ClassificationSuggestionEngine.allowsSuggestion(
                existing: records[index].classification?.terms(for: dimension) ?? [], dimension: dimension) else { continue }
            records[index].mutateClassification { value in
                if ClassificationVocabulary.allowsMultiple(dimension) { value.add(name, in: dimension) } else { value.set([name], for: dimension) }
            }
            written += 1
        }
        return written
    }

    /// 同一组的「按既有决定写入」说明只保留一条：重跑会反复命中同一条决定，不能每次都往末尾追加。
    private static func replacingNote(in detail: String, count: Int) -> String {
        let marker = "；按你之前的决定写入"
        let base = detail.range(of: marker).map { String(detail[..<$0.lowerBound]) } ?? detail
        return "\(base)\(marker) \(count) 张"
    }

    /// 提交一次刷新结果：先按用户既有决定直接写入，再把剩余建议放进箱。
    private func commitClassificationSuggestions(_ fresh: [MaterialTaggingState.Suggestion],
                                                 unionWithExisting: Bool = false) async {
        let replay = ClassificationSuggestionEngine.replay(fresh, decisions: tagging.decisions ?? [])

        if !replay.autoApply.isEmpty {
            var applied = 0
            do {
                try await changeTagging(nil, undoable: true) { box, records in
                    for group in replay.autoApply {
                        applied += Self.writeClassification(dimension: group.dimension, name: group.name,
                                                           ids: group.materialIDs, into: &records)
                        for index in (box.suggestions ?? []).indices where box.suggestions?[index].groupKey == group.groupKey {
                            var value = box.suggestions![index]
                            value.status = "已采纳"
                            value.name = group.name
                            value.decidedAt = .now
                            value.detail = Self.replacingNote(in: value.detail, count: group.materialIDs.count)
                            box.suggestions![index] = value
                        }
                    }
                }
            } catch {
                toast = "按既有决定写入分类未成功：\(error.localizedDescription)"
            }
            if applied > 0 { toast = "按你之前的决定补写了 \(applied) 张图片的分类，可撤销" }
        }

        do {
            try await changeTagging(nil, undoable: false) { box, _ in
                let merged = ClassificationSuggestionEngine.mergedBox(box.suggestions ?? [], replay.ask,
                                                                     unionWithExisting: unionWithExisting)
                box.suggestions = merged.isEmpty ? nil : merged
            }
        } catch {
            toast = "分类建议入箱未成功：\(error.localizedDescription)"
            return
        }
        // 报箱里的真实待确认组数，而不是本次扫描涉及的组数：增量入箱时两者不同。
        let pending = tagging.pendingSuggestions.count
        // 导入增量入箱时没有逐张视觉索引，进度为 0 就不该在提示里显示「已索引 0 / 0」。
        let progressNote = suggestionIndexTotal > 0 ? "（已索引 \(suggestionIndexed) / \(suggestionIndexTotal)）" : ""
        toast = pending > 0 ? "已刷新分类建议：\(pending) 组待确认\(progressNote)" : "已扫描完成：没有需要确认的分类建议"
    }
}
