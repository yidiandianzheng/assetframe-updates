import SwiftUI

struct MaterialImportProgressCard: View {
    @ObservedObject var store: GlobalMaterialStore
    @ObservedObject private var progress: MaterialImportController
    let receivingDrop: Bool

    init(store: GlobalMaterialStore, receivingDrop: Bool) {
        self.store = store
        self.progress = store.importController
        self.receivingDrop = receivingDrop
    }
    @State private var showsDetails = false

    private var active: Bool { receivingDrop || store.isImporting }
    private var remainingText: String? {
        guard let seconds = store.importEstimatedRemainingSeconds else { return nil }
        if seconds <= 0 { return nil }
        if seconds < 60 { return "预计剩余约 \(Int(ceil(seconds))) 秒" }
        return "预计剩余约 \(Int(ceil(seconds / 60))) 分钟"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(receivingDrop ? "正在接收拖入项目…" : store.importPhase)
                    .font(.headline)
                Spacer()
                if active {
                    if !receivingDrop {
                        Button("暂停") { store.pauseImport() }
                            .disabled(store.importPhase == "正在暂停" || store.importPhase == "正在取消")
                        Button("取消") { store.cancelImport() }
                            .disabled(store.importPhase == "正在取消" || store.importPhase == "正在暂停")
                    }
                } else {
                    Button { store.dismissImportProgress() } label: {
                        Image(systemName: "xmark")
                    }.accessibilityLabel("关闭导入结果")
                }
            }
            if let job = progress.job {
                Text("本次任务 \(job.id.uuidString.prefix(8)) · \(job.startedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if receivingDrop || (store.isImporting && store.importProcessed == 0) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(receivingDrop ? "读取文件位置" : "已发现 \(store.importDiscovered) 个文件")
                }
            } else if store.isImporting {
                if store.importScanCompleted {
                ProgressView(
                    value: Double(store.importProcessed),
                    total: Double(max(1, store.importScanCompleted ? store.importTotal : store.importDiscovered))
                )
                } else { ProgressView().controlSize(.small) }
                Text("已有 \(store.importAdded) 项可浏览 · 已处理 \(store.importProcessed) / \(max(store.importTotal, store.importDiscovered))")
                    .monospacedDigit()
                if let remainingText {
                    Text(remainingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if !store.importScanCompleted {
                    Text("仍在发现文件，完成扫描后显示预估时间")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let job = progress.job, !job.finished {
                    Text(job.waiting(at: context.date) ? "正在等待：\(job.stage)" : "已用 \(Int(context.date.timeIntervalSince(job.startedAt))) 秒")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !receivingDrop && !store.importCurrentFile.isEmpty {
                Text(store.importCurrentFile).lineLimit(2).truncationMode(.middle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !receivingDrop && !store.importResults.isEmpty {
                Text("新增 \(store.importAdded) · 重复 \(store.importDuplicate) · 失败 \(store.importFailed) · 跳过 \(store.importSkipped) · 取消 \(store.importCancelled)")
                    .font(.caption).monospacedDigit()
                Button(store.importFailed > 0 ? "查看失败与详情" : "展开详情") { showsDetails = true }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.3)))
        
        .sheet(isPresented: $showsDetails) {
            VStack(alignment: .leading) {
                HStack {
                    Text("本次导入详情").font(.headline)
                    Spacer()
                    Button("完成") { showsDetails = false }
                }.padding()
                List(store.importResults) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.path).lineLimit(2).truncationMode(.middle)
                        Text(result.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(width: 640, height: 420)
        }
    }
}
