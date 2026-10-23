import AppKit
import Foundation
import ImageIO

/// Offline evidence run. It never constructs GlobalMaterialStore or opens a production database.
@main struct MaterialTaggingRealSampleTest {
    struct Sample: Codable, Sendable {
        var ordinal: Int
        var domain: String
        var originalPath: String
        var imageSHA256: String
        var record: MaterialRecord
        var originalDocument: String?
        var fixtureDocument: String?
        var fixtureDerivation: String
    }
    struct Manifest: Decodable { var qaRoot: String; var sources: [MaterialTaggingState.Source]; var samples: [Sample] }
    struct Result: Codable {
        var sample: Sample
        var seconds: Double
        var proposal: MaterialTaggingState.Proposal?
        var failure: String?
        var imageCopySHA256Verified: Bool
    }
    struct QueryMetric: Codable { var query: String; var resultCount: Int; var milliseconds: [Double]; var cached: Bool }
    struct IndexReport: Codable {
        var recordCount: Int
        var images: Int
        var indexBuildMilliseconds: Double
        var indexRecords: Int
        var indexBytes: Int
        var metrics: [QueryMetric]
        var notes: String
    }
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), report = URL(fileURLWithPath: CommandLine.arguments[2])
        guard root.path.hasPrefix("/tmp/assetframe-qa.tagging-samples.") else { throw CocoaError(.fileReadNoPermission) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        precondition(manifest.samples.count == 100 && manifest.samples.filter { $0.domain == "tea" }.count == 50 && manifest.samples.filter { $0.domain == "drama" }.count == 50)
        let state = MaterialTaggingState(sources: manifest.sources)
        let context = try await Task.detached { try MaterialTaggingAnalyzer.prepare(state: state) }.value
        log("Prepared \(context.documents.count) QA source documents; 100 real copied images; network disabled by test design")
        var results: [Result] = []
        let overall = Date()
        // Resume only checkpoints made from the exact same frozen source snapshot and manifest.
        let checkpoint = root.appendingPathComponent("sample-results.json")
        if let data = try? Data(contentsOf: checkpoint), let prior = try? JSONDecoder().decode([Result].self, from: data) {
            results = prior.filter { old in manifest.samples.contains { $0.record.id == old.sample.record.id && $0.imageSHA256 == old.sample.imageSHA256 } }
        }
        for sample in manifest.samples where !results.contains(where: { $0.sample.ordinal == sample.ordinal }) {
            let began = Date()
            let result = await Task.detached(priority: .utility) {
                do {
                    let verified = try MaterialTaggingState.fileDigest(sample.record.sourcePath!) == sample.imageSHA256
                    guard verified else { throw CocoaError(.fileReadCorruptFile) }
                    let proposal = try MaterialTaggingAnalyzer.analyze(record: sample.record, state: state, links: [], context: context)
                    return Result(sample: sample, seconds: Date().timeIntervalSince(began), proposal: proposal, failure: nil, imageCopySHA256Verified: true)
                } catch {
                    let ns = error as NSError
                    return Result(sample: sample, seconds: Date().timeIntervalSince(began), proposal: nil, failure: "\(ns.domain)（\(ns.code)）：\(ns.localizedDescription)", imageCopySHA256Verified: (try? MaterialTaggingState.fileDigest(sample.record.sourcePath!)) == sample.imageSHA256)
                }
            }.value
            results.append(result)
            try writeJSON(results, to: checkpoint)
            try writeJSON(results, to: report.appendingPathComponent("sample-results.json"))
            log("\(sample.ordinal)/100 \(sample.domain) \(result.failure == nil ? "analyzed" : "FAILED") \(String(format: "%.2fs", result.seconds)) \(sample.record.originalFilename)")
        }
        results.sort { $0.sample.ordinal < $1.sample.ordinal }
        var csv = "序号,域,名称,原图片路径,QA图片路径,原始引用文档,秒,识别阶段状态,失败,缺少明确资料,存在冲突,标签,分类,待核对,人工结论\n"
        for row in results {
            let p = row.proposal
            csv += [String(row.sample.ordinal), row.sample.domain, row.sample.record.name, row.sample.originalPath, row.sample.record.sourcePath ?? "", row.sample.originalDocument ?? "", String(format: "%.3f", row.seconds), row.proposal.map { $0.error.isEmpty ? "完整候选" : "部分候选" } ?? "处理失败", row.failure ?? "", p.map { String($0.missingDocuments) } ?? "", p.map { String($0.hasConflict) } ?? "", p?.tags.joined(separator: " | ") ?? "", p?.categories.displayText ?? "", p?.uncertainties.joined(separator: " | ") ?? "", "待人工核对"].map(quote).joined(separator: ",") + "\n"
        }
        try Data(("\u{FEFF}" + csv).utf8).write(to: report.appendingPathComponent("sample-review.csv"))
        let sheets = try contactSheets(results, report: report)
        let index = try await Task.detached { try await indexBenchmark(root: root) }.value
        try writeJSON(index, to: report.appendingPathComponent("index-benchmark.json"))
        let full = results.filter { $0.proposal?.error.isEmpty == true }.count
        let partial = results.filter { $0.proposal != nil && $0.proposal?.error.isEmpty == false }.count
        var markdown = "# 100张真实图片本机标签样例\n\n"
        markdown += "QA 根：`\(root.path)`。本轮只读生产 SQLite（mode=ro）并备份完整索引到 QA；图片逐张复制且校验 SHA-256。未启动正式 App，未发送网络请求，未调用 AI，未修改原图片或项目文档。\n\n"
        markdown += "茶库 50 张、短剧库 50 张；实际完成 \(results.count) 张，完整识别候选 \(full) 张，部分识别候选 \(partial) 张，无法完成读取/识别 \(results.filter { $0.failure != nil }.count) 张。逐图累计识别耗时 \(String(format: "%.1f", results.reduce(0) { $0 + $1.seconds })) 秒；本次进程壁钟 \(String(format: "%.1f", Date().timeIntervalSince(overall))) 秒。\n\n"
        markdown += "真实图片原有明确 Markdown 引用 \(results.filter { $0.sample.originalDocument != nil }.count) 张；Analyzer 判定缺少明确资料 \(results.filter { $0.proposal?.missingDocuments == true }.count) 张；存在冲突 \(results.filter { $0.proposal?.hasConflict == true }.count) 张。上述计数是处理状态，不是准确率。100 张均待人工逐图核对，CSV 最后一列留作人工结论。\n\n"
        markdown += "## 派生样例方法与限制\n\n来源为分类词表已有资料清单。仅当真实原文 Markdown 图片链接解析后精确等于库中原图片路径时，才复制该文档并把原有链接改向 QA 图片副本。没有按文件名构造关联，没有新增不存在的关联，也没有把引用描述升级为实际生成原文或确认状态。复制整文保留多图歧义，由正式 Analyzer 决定可否提取片段。未找到明确引用的样本保持无文档状态。完整出处和原文/副本哈希见 sample-manifest.json。\n\n当前真实候选来自 QA 文档和图片副本；未经人工确认。相同 source SHA 的可执行文件只编译一次，见 source-hashes.json。\n\n"
        markdown += "## 完整索引查询\n\n只测两个完整索引快照合计 \(index.recordCount) 条记录；没有对全库原图运行识别。建立文本索引耗时 \(String(format: "%.1f", index.indexBuildMilliseconds)) ms，覆盖 \(index.indexRecords) 条；每个查询各运行 5 次未缓存和已缓存路径，见 index-benchmark.json。该结果不等于 GUI 响应验收。\n\n"
        markdown += sheets.map { "![真实样例联络图](\($0))" }.joined(separator: "\n\n") + "\n"
        try markdown.write(to: report.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        log("REAL_SAMPLE_RUN_COMPLETE complete=\(full) partial=\(partial) unreadableOrFailed=\(results.filter { $0.failure != nil }.count)/100 missingDocs=\(results.filter { $0.proposal?.missingDocuments == true }.count) indexRecords=\(index.recordCount)")
    }
    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    static func quote(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    static func log(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    static func indexBenchmark(root: URL) async throws -> IndexReport {
        let records = try JSONDecoder().decode([MaterialRecord].self, from: Data(contentsOf: root.appendingPathComponent("full-index-records.json")))
        let fields: Set<MaterialSearchField> = [.name, .tags, .classification]
        let cache = MaterialTextSearchCache()
        let began = Date()
        let prepared = await cache.prepare(key: .init(libraryGeneration: "full-readonly-snapshot", queryRevision: 0, fields: fields), enabled: true, materials: records, links: [], folders: [])
        let elapsed = Date().timeIntervalSince(began) * 1000
        var metrics: [QueryMetric] = []
        for cached in [false, true] {
            for query in ["", "茶", "许长山", "正面", "不存在的测试词_20261023"] {
                var times: [Double] = [], count = 0
                for _ in 0..<5 {
                    var filter = MaterialSearchFilter(); filter.search = query; filter.searchFields = fields
                    let start = Date()
                    let result = GlobalMaterialStore.query(records, links: [], filter: filter, projectID: "", searchIndex: cached ? prepared.index : nil)
                    count = result.count; times.append(Date().timeIntervalSince(start) * 1000)
                }
                metrics.append(.init(query: query, resultCount: count, milliseconds: times, cached: cached))
            }
        }
        return .init(recordCount: records.count, images: records.filter { $0.kind == .image }.count,
                     indexBuildMilliseconds: elapsed, indexRecords: prepared.diagnostics.cachedRecordCount, indexBytes: prepared.diagnostics.estimatedBytes,
                     metrics: metrics, notes: "完整生产索引只读快照；名称/标签/分类字段；每项5轮；不测GUI与全库识图；未缓存与缓存路径结果数应一致")
    }
    @MainActor static func contactSheets(_ rows: [Result], report: URL) throws -> [String] {
        var paths: [String] = []
        for page in 0..<5 {
            let size = NSSize(width: 1400, height: 1280), canvas = NSImage(size: size)
            canvas.lockFocus(); NSColor.white.setFill(); NSBezierPath(rect: .init(origin: .zero, size: size)).fill()
            for (index, row) in rows.dropFirst(page * 20).prefix(20).enumerated() {
                let x = CGFloat(index % 5) * 280 + 8, y = CGFloat(3 - index / 5) * 320 + 75
                if let path = row.sample.record.sourcePath, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                   let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary) {
                    let image = NSImage(cgImage: cg, size: .zero)
                    let factor = min(264 / CGFloat(cg.width), 235 / CGFloat(cg.height))
                    let rect = NSRect(x: x + (264 - CGFloat(cg.width) * factor) / 2, y: y, width: CGFloat(cg.width) * factor, height: CGFloat(cg.height) * factor)
                    image.draw(in: rect)
                }
                let phase = row.proposal.map { $0.error.isEmpty ? "完整" : "部分" } ?? "失败"
                let label = "\(row.sample.ordinal). [\(phase)] \(row.sample.domain) \(row.sample.record.originalFilename)\n\(row.proposal?.categories.displayText ?? row.failure ?? "")"
                (String(label.prefix(140)) as NSString).draw(in: NSRect(x: x, y: y - 66, width: 264, height: 62), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black])
            }
            canvas.unlockFocus()
            let data = NSBitmapImageRep(data: canvas.tiffRepresentation!)!.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!
            let path = report.appendingPathComponent(String(format: "contact-%02d.jpg", page + 1))
            try data.write(to: path); paths.append(path.path)
        }
        return paths
    }
}
