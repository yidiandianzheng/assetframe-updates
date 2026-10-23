import Foundation
import Combine

@MainActor
final class MaterialTaggingController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var progress = ""
    @Published var issue: String?
    private let store: GlobalMaterialStore
    private var task: Task<Void, Never>?
    private var runID = UUID()

    init(store: GlobalMaterialStore) { self.store = store }

    func start(ids: Set<String>, retryFailed: Bool = false) {
        guard !busy else { return }
        let valid = store.materials.filter { ids.contains($0.id) && $0.kind == .image && $0.deletedAt == nil }.map(\.id).sorted()
        guard !valid.isEmpty else { issue = "所选范围没有可整理的图片"; return }
        if retryFailed, let previous = store.tagging.jobs.last {
            let retry = valid.filter { previous.failed.contains($0) }
            guard !retry.isEmpty else { issue = "所选范围没有失败项"; return }
            launch(ids: retry, jobID: nil, forceRetry: true)
        } else { launch(ids: valid, jobID: nil) }
    }

    func resume() {
        guard !busy, let job = store.tagging.jobs.last else { return }
        let complete = Set(job.completed + job.failed)
        let remaining = job.materialIDs.filter { !complete.contains($0) }
        guard !remaining.isEmpty else { progress = "本批处理完毕；失败项可单独重试"; return }
        launch(ids: remaining, jobID: job.id, forceRetry: job.forceRetry ?? false)
    }

    func pause() { task?.cancel() }
    func stop() { pause() }

    private func launch(ids: [String], jobID: String?, forceRetry: Bool = false) {
        let token = UUID(); runID = token; busy = true; issue = nil
        task = Task { [weak self] in
            guard let self else { return }
            let id = jobID ?? UUID().uuidString
            do {
                try await store.changeTagging { state, _ in
                    try Task.checkCancellation()
                    if let index = state.jobs.firstIndex(where: { $0.id == id }) { state.jobs[index].status = "进行中" }
                    else { state.jobs.append(.init(id: id, materialIDs: ids, status: "进行中", forceRetry: forceRetry)) }
                }
                let initialState = store.tagging
                let preparation = Task.detached(priority: .utility) { try MaterialTaggingAnalyzer.prepare(state: initialState) }
                let context = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
                for materialID in ids {
                    try Task.checkCancellation()
                    guard runID == token else { throw CancellationError() }
                    guard store.tagging.relationKey == initialState.relationKey else { throw CharacterLibraryError.invalid("资料来源或图文绑定已变化，请重新启动本机整理") }
                    guard let record = store.materials.first(where: { $0.id == materialID && $0.deletedAt == nil }) else {
                        try await markFailure(materialID, jobID: id, message: "图片记录已移除"); continue
                    }
                    let state = store.tagging, links = store.links.filter { $0.materialID == materialID }
                    let job = state.jobs.first { $0.id == id }
                    progress = "本机整理 \(Set((job?.completed ?? []) + (job?.failed ?? [])).count + 1)/\(job?.materialIDs.count ?? ids.count)"
                    do {
                        let work = Task.detached(priority: .utility) {
                            try MaterialTaggingAnalyzer.analyze(record: record, state: state, links: links, context: context, forceRetry: forceRetry)
                        }
                        let proposal = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                        try Task.checkCancellation()
                        let currentLinks = store.links.filter { $0.materialID == materialID }
                        guard MaterialTaggingAnalyzer.linkDigest(links) == MaterialTaggingAnalyzer.linkDigest(currentLinks) else { throw CharacterLibraryError.invalid("整理期间图文关联变化，请重试") }
                        try await store.changeTagging(validating: [proposal]) { state, _ in
                            try Task.checkCancellation()
                            // Exact same inputs preserve confirmed/ignored decisions and prior manual edits.
                            if forceRetry || !state.proposals.contains(where: { $0.materialID == materialID && $0.inputKey == proposal.inputKey && !["已过期", "处理失败"].contains($0.status) && ($0.error.isEmpty || ["已确认", "已忽略"].contains($0.status)) }) {
                                for index in state.proposals.indices where state.proposals[index].materialID == materialID && state.proposals[index].status == "待确认" {
                                    state.proposals[index].status = "已过期"
                                }
                                state.proposals.append(proposal)
                            }
                            if let index = state.jobs.firstIndex(where: { $0.id == id }) {
                                if !state.jobs[index].completed.contains(materialID) { state.jobs[index].completed.append(materialID) }
                                if proposal.error.isEmpty { state.jobs[index].failed.removeAll { $0 == materialID } }
                                else if !state.jobs[index].failed.contains(materialID) { state.jobs[index].failed.append(materialID) }
                            }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { try await markFailure(materialID, jobID: id, message: error.localizedDescription) }
                }
                try await setJobStatus(id, "已完成")
                progress = "本机整理完成；请检查候选并确认"
            } catch is CancellationError {
                do { try await setJobStatus(id, "已暂停") } catch { issue = "暂停进度保存失败：" + error.localizedDescription }
                progress = "已暂停，可手动继续"
            } catch {
                issue = error.localizedDescription
                try? await setJobStatus(id, "已暂停")
            }
            if runID == token { busy = false; task = nil }
        }
    }

    private func markFailure(_ materialID: String, jobID: String, message: String) async throws {
        try Task.checkCancellation()
        try await store.changeTagging { state, records in
            try Task.checkCancellation()
            if let index = state.jobs.firstIndex(where: { $0.id == jobID }), !state.jobs[index].failed.contains(materialID) { state.jobs[index].failed.append(materialID) }
            // A failed attempt is separate from usable prior candidates.
            if let record = records.first(where: { $0.id == materialID }) {
                var failure = MaterialTaggingState.Proposal(materialID: materialID, inputKey: UUID().uuidString,
                    imagePath: record.sourcePath ?? "", imageDigest: "", catalogKey: state.catalogKey, relationKey: state.relationKey)
                failure.status = "处理失败"; failure.error = message
                state.proposals.removeAll { $0.materialID == materialID && $0.status == "处理失败" }
                state.proposals.append(failure)
            }
        }
    }
    private func setJobStatus(_ id: String, _ status: String) async throws {
        // The paused checkpoint must survive cancellation of the worker itself.
        let checkpoint = Task { @MainActor [store] in
            try await store.changeTagging { state, _ in
                if let index = state.jobs.firstIndex(where: { $0.id == id }) { state.jobs[index].status = status }
            }
        }
        try await checkpoint.value
    }

    /// The view must first show service/model/count/input scope and receive an explicit Send action.
    func correct(ids: Set<String>, mode: String) {
        guard !busy else { return }
        guard !ids.isEmpty, ids.count <= 20 else { issue = "每批请选择 1–20 张图片校正"; return }
        guard mode == "文本" || mode == "看图" else { issue = "请选择文本或看图校正"; return }
        let token = UUID(); runID = token; busy = true; issue = nil
        task = Task { [weak self] in
            guard let self else { return }
            var failures: [String] = []
            let configuration: MaterialTaggingAIClient.Configuration
            do { configuration = try MaterialTaggingAIClient.configuration(mode: mode) }
            catch { issue = error.localizedDescription; busy = false; task = nil; return }
            for (offset, id) in ids.sorted().enumerated() {
                if Task.isCancelled { break }
                progress = "AI 校正 \(offset + 1)/\(ids.count)（每张单次请求）"
                do {
                    guard let record = store.materials.first(where: { $0.id == id && $0.deletedAt == nil }),
                          let proposal = store.tagging.proposals.last(where: { $0.materialID == id && $0.status != "处理失败" && $0.status != "已过期" }) else {
                        throw CharacterLibraryError.invalid("请先进行本机整理")
                    }
                    let links = store.links.filter { $0.materialID == id }
                    let linkKey = MaterialTaggingAnalyzer.linkDigest(links)
                    let updated = try await MaterialTaggingAIClient.correct(record: record, proposal: proposal, state: store.tagging, mode: mode, links: links, configuration: configuration)
                    try Task.checkCancellation()
                    guard MaterialTaggingAnalyzer.linkDigest(store.links.filter { $0.materialID == id }) == linkKey else { throw CharacterLibraryError.invalid("请求期间图文关联变化，请重新整理") }
                    try await store.changeTagging(validating: [updated]) { state, _ in
                        try Task.checkCancellation()
                        // Preserve the previous decided proposal; the online result is a fresh pending candidate.
                        for index in state.proposals.indices where state.proposals[index].materialID == id && state.proposals[index].status == "待确认" { state.proposals[index].status = "已过期" }
                        state.proposals.append(updated)
                    }
                } catch is CancellationError { break }
                catch {
                    failures.append("第 \(offset + 1) 张：" + error.localizedDescription)
                    // Missing/invalid settings are shared by the batch; don't prompt Keychain repeatedly.
                    if offset == 0 && (error is MaterialTaggingAPISettings.Failure) { break }
                }
            }
            if !failures.isEmpty { issue = failures.joined(separator: "\n") }
            progress = Task.isCancelled ? "AI 校正已停止，已完成候选保留" : "AI 校正结束，待人工确认"
            if runID == token { busy = false; task = nil }
        }
    }
}
