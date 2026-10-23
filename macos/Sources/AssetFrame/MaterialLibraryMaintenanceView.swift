import SwiftUI
import AppKit

struct MaterialLibraryMaintenanceView: View {
    @ObservedObject var session: LibrarySession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if let store = session.store {
            MaterialMaintenanceContent(store: store, onClose: { dismiss() }).id(session.descriptor?.id)
        } else { Text("请先打开资源库").padding(30) }
    }
}

private struct MaterialMaintenanceContent: View {
    @ObservedObject var store: GlobalMaterialStore
    let onClose: () -> Void
    @State private var job: Task<Void, Never>?
    @State private var busy = false
    @State private var applying = false
    @State private var issue: String?
    @State private var relocation = MaterialRelocationScan.Result()
    @State private var similarity = MaterialSimilarityScan.Result()
    @State private var names: [String: String] = [:]
    @State private var comparison: MaterialComparisonSelection?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("定位、相似素材与整理恢复").font(.title2); Spacer(); Button("完成", action: onClose).disabled(applying) }
            HStack {
                Button("查找移动或改名的文件…", action: chooseRelocationFolder)
                Button("查找同指纹素材") { scanSimilarity(visual: false) }
                Button("查找相似画面") { scanSimilarity(visual: true) }
                if busy { ProgressView().controlSize(.small); Button("停止") { job?.cancel(); busy = false } }
            }.disabled(applying)
            Text("扫描只提供候选；关联前重新核验内容。相似画面不自动合并或删除。").font(.caption).foregroundStyle(.secondary)
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(relocation.candidates) { candidate in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading) {
                                Text(names[candidate.materialID] ?? candidate.materialID)
                                Text(candidate.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button("关联此文件") { applyRelocation(candidate) }.disabled(!store.canWrite || busy || applying)
                        }
                    }
                    ForEach(similarity.groups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.materialIDs.prefix(8).map { names[$0] ?? $0 }.joined(separator: "、")).lineLimit(3)
                            HStack {
                                Text(group.reason).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("比较") { comparison = MaterialComparisonSelection(ids: Array(group.materialIDs.prefix(4))) }
                            }
                        }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            Divider()
            Text("可撤销 \(store.undoHistoryCount) 步 · 可重做 \(store.redoHistoryCount) 步；整理历史与素材修改一起保存，重启后可继续。").font(.caption)
            HStack {
                Button("撤销上次整理") { Task { _ = await store.undoEdit(); issue = store.toast } }.disabled(!store.canUndoEdit || applying || busy)
                Button("重做整理") { Task { _ = await store.undoEdit(redo: true); issue = store.toast } }.disabled(!store.canRedoEdit || applying || busy)
            }
        }.padding(20).frame(width: 840, height: 560)
            .sheet(item: $comparison) { selection in MaterialComparisonView(store: store, ids: selection.ids, onClose: { comparison = nil }) }
            .onDisappear { job?.cancel() }
    }
    private func chooseRelocationFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.title = "选择可能的新文件位置（只读扫描）"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let root = panel.url else { return }
        let records = store.materials
        names = Dictionary(records.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        busy = true; issue = nil; similarity = .init()
        job = Task {
            let worker = Task.detached(priority: .utility) { MaterialRelocationScan.scan(materials: records, directory: root) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            relocation = result; busy = false
            issue = "扫描 \(result.scannedFiles) 个文件，找到 \(result.candidates.count) 个内容匹配位置；\(result.missingWithoutFingerprint) 项缺少可核验指纹\(result.truncated ? "；达到扫描上限，可缩小文件夹重试" : "")"
        }
    }
    private func scanSimilarity(visual: Bool) {
        guard !busy else { return }
        let records = store.materials
        names = Dictionary(records.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        busy = true; issue = nil; relocation = .init()
        job = Task {
            let worker = Task.detached(priority: .utility) { MaterialSimilarityScan.scan(records, includeVisual: visual) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            similarity = result; busy = false
            issue = "找到 \(result.groups.count) 组候选\(visual ? "；检查\(result.inspectedImages)张图片，\(result.unsupportedImages)项未读取" : "")\(result.truncated ? "；结果达到数量上限" : "")"
        }
    }
    private func applyRelocation(_ candidate: MaterialRelocationScan.Candidate) {
        applying = true
        job = Task {
            do {
                try await store.relocate(candidate.materialID, to: URL(fileURLWithPath: candidate.path))
                relocation.candidates.removeAll { $0.materialID == candidate.materialID }
                issue = "已关联原文件；素材编号、标签、评分与引用保留"
            } catch { issue = error.localizedDescription }
            applying = false
        }
    }
}
