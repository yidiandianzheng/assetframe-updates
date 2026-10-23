import SwiftUI

struct PreviewCacheManagerView: View {
    @ObservedObject var session: LibrarySession
    @Environment(\.dismiss) private var dismiss
    @State private var inventory: PreviewCacheInventory?
    @State private var issue: String?
    @State private var busy = false
    @State private var budget: PreviewCacheBudget.Report?
    @State private var refresh = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("预览缓存与诊断").font(.title2); Spacer(); Button("完成") { dismiss() } }
            if let inventory {
                Text("当前资源库缓存：\(ByteCountFormatter.string(fromByteCount: inventory.bytes, countStyle: .file)) · \(inventory.files) 个文件")
                ForEach(inventory.categories.keys.sorted(), id: \.self) { category in
                    HStack { Text(category); Spacer(); Text(ByteCountFormatter.string(fromByteCount: inventory.categories[category]!, countStyle: .file)) }
                }
                Text("缓存代次 \(inventory.generations.count) · 切库用时 \(session.lastOpenSeconds, specifier: "%.3f") 秒\(session.lastOpenReusedStore ? "（复用已暂停库）" : "")")
                if inventory.truncated { Text("扫描达到时间或数量上限，以上为已扫描部分。").foregroundStyle(.orange) }
            } else { ProgressView("正在统计…") }
            if let budget {
                Text(budget.scanning ? "正在分段统计当前缓存：已检查\(budget.visitedFiles)项 · \(budget.scanChunks)段" : budget.checked ? "当前缓存统计完成：\(ByteCountFormatter.string(fromByteCount: budget.observedBytes, countStyle: .file))" : "当前缓存尚未完成统计")
                    .font(.caption).foregroundStyle(.secondary)
                if budget.readErrors > 0 || budget.limitReached { Text("统计不完整，自动清理已暂停；可检查磁盘后重试。").font(.caption).foregroundStyle(.orange) }
            Text("当前预览缓存自动预算：\(ByteCountFormatter.string(fromByteCount: budget.byteBudget, countStyle: .binary))；磁盘可用空间低于\(ByteCountFormatter.string(fromByteCount: budget.reserveBytes, countStyle: .binary))时暂停写缓存。旧缓存代次仍由下方按钮管理。")
                .font(.caption).foregroundStyle(.secondary)
            }
            Text("清理仅作用于本软件生成的预览缓存。旧缓存清理保留最近一代；原始素材、数据库和标签不在清理范围内。").font(.caption).foregroundStyle(.secondary)
            if let issue { Text(issue).foregroundStyle(.orange) }
            HStack {
                Button("释放预览内存") { PreviewImagePipeline.shared.cancelPendingAndClearMemory(); issue = "已释放可重建预览内存" }
                Button("重新生成缓存") { Task { busy = true; await session.clearCache(); busy = false; refresh = UUID() } }
                Button("清理更旧缓存") { Task {
                    guard let id = session.descriptor?.id else { return }; busy = true
                    do { let n = try await Task.detached { try SSDPreviewCache.pruneObsolete(id) }.value; issue = "已清理 \(n) 个旧缓存代次" }
                    catch { issue = error.localizedDescription }
                    busy = false; refresh = UUID()
                } }
            }.disabled(busy || session.busy)
        }.padding(24).frame(width: 620, height: 470)
        .task {
            while !Task.isCancelled {
                budget = PreviewCacheBudget.shared.snapshot(root: SSDPreviewCache.root)
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
        }
        .task(id: refresh) {
            guard let id = session.descriptor?.id else { return }
            do { let root = try SSDPreviewCache.libraryRoot(id); inventory = await Task.detached { PreviewCacheInventory.read(root: root) }.value }
            catch { issue = error.localizedDescription }
        }
    }
}
