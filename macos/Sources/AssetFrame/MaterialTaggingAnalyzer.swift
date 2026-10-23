import Foundation
import ImageIO

/// Read-only local analysis. Project automation (and therefore online extraction) is never started.
enum MaterialTaggingAnalyzer {
    typealias Proposal = MaterialTaggingState.Proposal
    struct Document: Sendable {
        var root: String
        var scopes: [String]
        var path: String
        var text: String
        var digest: String
    }
    struct Context: Sendable {
        var documents: [Document] = []
        var warnings: [String] = []
        var directories: [MaterialTaggingState.Evidence] = []
    }

    static func prepare(state: MaterialTaggingState) throws -> Context {
        var context = Context()
        var seen = Set<String>()
        for source in state.sources {
            try Task.checkCancellation()
            do {
                let root = URL(fileURLWithPath: source.path).resolvingSymlinksInPath().standardizedFileURL
                let directoryStamp = try MaterialTaggingState.directoryDigest(root.path)
                let scan = try CharacterProjectScanner.scan(root: root)
                guard try MaterialTaggingState.directoryDigest(root.path) == directoryStamp else { throw CharacterLibraryError.conflict }
                context.directories.append(.init(kind: "资料目录清单", path: root.path, digest: directoryStamp))
                context.warnings += scan.warnings
                for doc in scan.documents {
                    let path = CharacterProjectModules.resolve(doc.path, root: root).resolvingSymlinksInPath().standardizedFileURL.path
                    guard seen.insert(path).inserted else { continue }
                    context.documents.append(Document(root: root.path, scopes: [source.name, source.scope ?? ""].filter { !$0.isEmpty }, path: path, text: doc.text,
                                                      digest: doc.fingerprint))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { context.warnings.append("资料目录不可读：" + source.name) }
        }
        for binding in state.bindings {
            let path = URL(fileURLWithPath: binding.documentPath).resolvingSymlinksInPath().standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            do {
                let (text, fingerprint) = try CharacterMarkdown.read(URL(fileURLWithPath: path))
                guard text.utf8.count <= 256 * 1024 else { context.warnings.append("绑定资料超过 256 KiB，未读取"); continue }
                context.documents.append(Document(root: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                                                  scopes: [], path: path, text: text,
                                                  digest: fingerprint))
            } catch { context.warnings.append("绑定资料不可读") }
        }
        return context
    }

    static func analyze(record: MaterialRecord, state: MaterialTaggingState, links: [ProjectMaterialLink]) throws -> Proposal {
        try analyze(record: record, state: state, links: links, context: prepare(state: state))
    }

    static func analyze(record: MaterialRecord, state: MaterialTaggingState, links: [ProjectMaterialLink], context: Context, forceRetry: Bool = false) throws -> Proposal {
        try Task.checkCancellation()
        guard record.kind == .image, record.deletedAt == nil, let path = record.sourcePath else { throw VisionAPIClientError.unreadableImage }
        let digest = try MaterialTaggingState.fileDigest(path)
        var proposal = Proposal(materialID: record.id, inputKey: "", imagePath: path, imageDigest: digest,
                                catalogKey: state.catalogKey, relationKey: state.relationKey)
        proposal.evidence += context.directories
        let imagePath = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        var scopes = Set<String>()
        var promptEvidence = false
        func append(_ kind: String, _ text: String, document: Document? = nil, digest: String = "") {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            proposal.evidence.append(.init(kind: kind, path: document?.path ?? "", excerpt: String(text.prefix(12000)), digest: document?.digest ?? digest))
            if let document { scopes.formUnion(document.scopes) }
            promptEvidence = true
        }
        let prompt = record.production?.prompt ?? ""
        proposal.evidence.append(.init(kind: "素材生成提示词", excerpt: String(prompt.prefix(12000)), digest: MaterialTaggingState.digest(Data(prompt.utf8))))
        if !prompt.isEmpty { promptEvidence = true }
        let relevantLinks = links.filter { $0.materialID == record.id }
        for link in relevantLinks {
            if let fp = link.boundFingerprint, !fp.isEmpty, fp != digest, fp != record.fingerprint, fp != record.contentFingerprint {
                proposal.uncertainties.append("关联素材指纹变化，提示词未提取"); continue
            }
            if let prompt = link.originalPrompt, !prompt.isEmpty {
                append("关联实际生成原文", prompt)
            }
            if let template = link.reuseTemplate, !template.isEmpty { append("复用模板", template) }
        }
        // Hash the exact material links, including empty sets, to invalidate added/removed relations.
        proposal.evidence.append(.init(kind: "素材关联快照", digest: linkDigest(relevantLinks)))
        for doc in context.documents {
            try Task.checkCancellation()
            let root = URL(fileURLWithPath: doc.root)
            if let receipt = try? CharacterProjectModules.decode(CharacterProjectModules.Receipt.self, text: doc.text, marker: "assetframe-confirmation"),
               (try? receipt.validate()) != nil,
               CharacterProjectModules.resolve(receipt.assetPath, root: root).resolvingSymlinksInPath().standardizedFileURL.path == imagePath {
                if receipt.sha256 == digest {
                    append("确认记录·实际生成原文", receipt.originalPrompt, document: doc)
                    append("确认依据", receipt.confirmationEvidence, document: doc)
                    if receipt.status == "已确认" { proposal.categories.add("已确认", in: "usage") }
                } else { proposal.uncertainties.append("确认记录的图片指纹不符，未继承确认状态") }
                continue
            }
            if let graph = try? CharacterProjectModules.decode(ProjectAssetGraph.self, text: doc.text, marker: ProjectAssetGraph.marker) {
                for asset in graph.assets where CharacterProjectModules.resolve(asset.path, root: root).resolvingSymlinksInPath().standardizedFileURL.path == imagePath {
                    if asset.sha256 == digest {
                        append("项目资产·实际生成原文", asset.originalPrompt, document: doc)
                        append("复用模板", asset.reuseTemplate, document: doc)
                        if asset.status == "已确认", !asset.evidence.isEmpty {
                            append("确认依据", asset.evidence, document: doc)
                            proposal.categories.add("已确认", in: "usage")
                        }
                    } else { proposal.uncertainties.append("项目资产指纹不符，未继承生成资料") }
                }
                continue
            }
            let binding = state.bindings.first { $0.materialID == record.id && canonical($0.documentPath) == doc.path }
            let linkedDocument = relevantLinks.contains { link in
                guard let source = link.sourceDocument else { return false }
                return canonical(CharacterProjectModules.resolve(source, root: root).path) == doc.path
            }
            let scanDoc = CharacterProjectDocument(path: doc.path, text: doc.text, fingerprint: doc.digest, kind: "其他", name: "", evidence: "", warning: "")
            let references = CharacterProjectScanner.assetLinks(scanDoc, root: root)
            let exact = references.contains { $0.path == imagePath }
            guard binding != nil || exact || linkedDocument else {
                let stem = URL(fileURLWithPath: imagePath).deletingPathExtension().lastPathComponent
                let sameFolder = URL(fileURLWithPath: doc.path).deletingLastPathComponent().path == URL(fileURLWithPath: imagePath).deletingLastPathComponent().path
                if proposal.evidence.filter({ $0.kind == "待关联" }).count < 8 && (sameFolder || (stem.count >= 3 && URL(fileURLWithPath: doc.path).lastPathComponent.contains(stem))) {
                    proposal.evidence.append(.init(kind: "待关联", path: doc.path, excerpt: "仅文件名或同目录相近，未自动提取标签", digest: doc.digest))
                }
                continue
            }
            // Archive/candidate prose never gains authority merely by containing a matching image.
            if ["历史", "归档", "停用", "备份"].contains(where: { doc.path.contains($0) }) {
                proposal.uncertainties.append("发现历史资料引用，保留待核对：" + URL(fileURLWithPath: doc.path).lastPathComponent)
                proposal.evidence.append(.init(kind: "历史引用·待关联", path: doc.path, excerpt: "历史引用未用于自动提取", digest: doc.digest))
                continue
            }
            let excerpt: String?
            if let selected = binding?.excerpt, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let occurrences = doc.text.components(separatedBy: selected).count - 1
                excerpt = selected.count <= 12000 && occurrences == 1 ? selected : nil
            } else {
                excerpt = relevantExcerpt(doc.text, imagePath: imagePath, documentPath: doc.path, imageCount: references.count, explicitlyBound: binding != nil || linkedDocument)
            }
            if let excerpt {
                append(binding?.kind ?? "明确图片引用", excerpt, document: doc)
            } else {
                proposal.evidence.append(.init(kind: "待关联", path: doc.path, excerpt: "多图或多段提示词，无法确定对应片段", digest: doc.digest))
                proposal.uncertainties.append("资料含多个对象，请绑定对应提示词片段")
            }
        }
        // Only affirmative passages contribute candidates. Negative and workflow state dimensions never leak into visible-content labels.
        for evidence in proposal.evidence where !["确认依据", "待关联", "历史引用·待关联", "素材关联快照"].contains(evidence.kind) {
            let evidenceScopes = context.documents.first { $0.path == evidence.path }.map { Set($0.scopes) } ?? scopes
            extract(text: evidence.excerpt, terms: state.effectiveTerms, scopes: evidenceScopes, into: &proposal)
        }
        proposal.inputKey = inputKey(proposal)
        if !forceRetry, let previous = state.proposals.last(where: { $0.materialID == record.id && ($0.baseInputKey ?? $0.inputKey) == proposal.inputKey && !["处理失败", "已过期"].contains($0.status) && ($0.error.isEmpty || ["已确认", "已忽略"].contains($0.status)) }),
           state.isCurrent(previous, material: record, links: links) { return previous }
        let local = try MaterialTaggingLocalVision.analyze(record)
        let mapping = ["person": "人物角色", "human": "人物角色", "portrait": "人物角色", "tea": "茶叶", "teapot": "茶壶", "cup": "茶杯", "forest": "树林", "sky": "天空", "building": "建筑", "flower": "花朵", "mountain": "山", "water": "水", "indoor": "室内", "outdoor": "室外"]
        for raw in local.tags {
            if let translated = mapping[raw.lowercased()] {
                if let term = state.term(translated), term.dimension != "entity", term.dimension != "usage", term.dimension != "negative" {
                    add(term, into: &proposal)
                } else { proposal.tags.append(translated) }
            } else if let term = state.term(raw), !["entity", "usage", "negative", "quality"].contains(term.dimension) {
                add(term, into: &proposal)
            } else {
                proposal.uncertainties.append("本机识别待核对：" + raw)
            }
        }
        proposal.evidence += local.evidence
        if !local.warnings.isEmpty {
            proposal.uncertainties += local.warnings
            proposal.error = "部分识图未完成：" + local.warnings.joined(separator: "；")
            proposal.engine = "本机 · 部分识别"
        }
        if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 {
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            let rotated = (5...8).contains(orientation)
            let w = rotated ? height : width, h = rotated ? width : height
            // Actual pixels take precedence over a prompt's desired output.
            for value in ["横屏", "竖屏", "方形"] { proposal.categories.remove(value, in: "shot") }
            proposal.categories.add(w == h ? "方形" : w > h ? "横屏" : "竖屏", in: "shot")
            proposal.tags.append("\(w)×\(h)")
            let longest = max(w, h)
            let resolution = longest >= 3840 ? "4K" : longest >= 2048 ? "2K" : longest >= 1024 ? "1K" : nil
            if let resolution, let term = state.term(resolution, dimension: "quality") { add(term, into: &proposal) }
            proposal.evidence.append(.init(kind: "实际图片尺寸", excerpt: "\(w)×\(h) 像素"))
        }
        proposal.missingDocuments = !promptEvidence
        if !promptEvidence { proposal.uncertainties.append("缺少明确对应资料；可在资料来源中绑定文档") }
        proposal.uncertainties += context.warnings
        proposal.tags = Array(Set(proposal.tags)).sorted()
        proposal.uncertainties = Array(Set(proposal.uncertainties)).sorted()
        for group in proposal.categories.groups where !ClassificationVocabulary.allowsMultiple(group.dimension) && group.terms.count > 1 {
            proposal.uncertainties.append("单选分类出现多个候选，请人工选择：" + group.terms.joined(separator: "、"))
            proposal.hasConflict = true
        }
        proposal.hasConflict = proposal.hasConflict || MaterialTaggingState.conflicts(proposal, with: record)
        proposal.inputKey = inputKey(proposal)
        guard try MaterialTaggingState.fileDigest(path) == digest else { throw CocoaError(.fileReadUnknown) }
        return proposal
    }

    static func linkDigest(_ links: [ProjectMaterialLink]) -> String {
        MaterialTaggingState.linkDigest(links)
    }
    static func inputKey(_ proposal: Proposal) -> String {
        let evidence = proposal.evidence.filter { !["电脑识图与文字识别", "实际图片尺寸", "本机图像分类", "本机文字识别"].contains($0.kind) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(evidence)) ?? Data()
        return MaterialTaggingState.digest(Data(("material-tagging-v1|" + proposal.imageDigest + proposal.catalogKey + proposal.relationKey).utf8) + data)
    }
    private static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
    static func relevantExcerpt(_ text: String, imagePath: String, documentPath: String, imageCount: Int, explicitlyBound: Bool) -> String? {
        if imageCount == 0 && explicitlyBound {
            let markers = text.components(separatedBy: .newlines).filter { $0.hasPrefix("#") && ($0.contains("提示词") || $0.localizedCaseInsensitiveContains("prompt")) }
            return text.count <= 12000 && markers.count <= 1 ? text : nil
        }
        let lines = text.components(separatedBy: .newlines)
        let filename = URL(fileURLWithPath: imagePath).lastPathComponent
        let matching = lines.indices.filter { lines[$0].contains(filename) || lines[$0].contains(filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename) }
        guard matching.count == 1, let index = matching.first else { return nil }
        // A table row is its own unambiguous record; otherwise only the current heading section is eligible.
        if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            let row = CharacterProjectDocument(path: documentPath, text: lines[index], fingerprint: "", kind: "其他", name: "", evidence: "", warning: "")
            let refs = CharacterProjectScanner.assetLinks(row, root: URL(fileURLWithPath: documentPath).deletingLastPathComponent())
            return refs.count == 1 && refs[0].path == canonical(imagePath) ? lines[index] : nil
        }
        let start = lines[..<index].lastIndex { $0.hasPrefix("#") } ?? index
        let end = lines[(index + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.count
        let section = lines[start..<end].joined(separator: "\n")
        let doc = CharacterProjectDocument(path: documentPath, text: section, fingerprint: "", kind: "其他", name: "", evidence: "", warning: "")
        let count = CharacterProjectScanner.assetLinks(doc, root: URL(fileURLWithPath: documentPath).deletingLastPathComponent()).count
        guard count == 1, section.count <= 12000 else { return nil }
        return section
    }
    static func extract(text: String, terms: [MaterialTaggingState.Term], scopes: Set<String>, into proposal: inout Proposal) {
        let negative = ["禁止", "不要", "不得", "避免", "不含", "没有", "无水印", "负面", "negative", "without", "exclude", "no ", "未确认", "待确认", "不应", "不出现", "不能有", "不是"]
        var inNegativeSection = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let header = trimmed.hasPrefix("#") || trimmed.hasSuffix(":") || trimmed.hasSuffix("：")
            if header {
                if ["负面", "禁止项", "negative", "排除项"].contains(where: { trimmed.localizedCaseInsensitiveContains($0) }) { inNegativeSection = true; continue }
                if trimmed.hasPrefix("#") || trimmed.contains("正面") || trimmed.contains("生成提示词") { inNegativeSection = false }
            }
            if inNegativeSection { continue }
            let clauses = line.components(separatedBy: CharacterSet(charactersIn: "。；;！？!?"))
            for clause in clauses {
                if negative.contains(where: { clause.localizedCaseInsensitiveContains($0) }) { continue }
                if clause.range(of: #"(^|[，,、：:\s])(无|不|非|未)"#, options: .regularExpression) != nil { continue }
                var matches: [(term: MaterialTaggingState.Term, name: String)] = []
                for term in terms where term.enabled && term.dimension != "negative" && term.dimension != "usage" && term.dimension != "quality" {
                    if term.dimension == "entity" && !scopes.contains(term.scope) { continue }
                    let names = ([term.name] + term.aliases).filter { !$0.isEmpty && affirmative($0, in: clause) }
                    if let longest = names.max(by: { $0.count < $1.count }) { matches.append((term, longest)) }
                }
                for match in matches {
                    // A precise phrase such as 中近景 suppresses its shorter alias 近景 in the same dimension.
                    if matches.contains(where: { $0.term.dimension == match.term.dimension && $0.name.count > match.name.count && $0.name.localizedCaseInsensitiveContains(match.name) }) { continue }
                    add(match.term, into: &proposal)
                }
            }
        }
    }
    /// Match-local negation also catches conjunctions such as “与无人物”, without a punctuation boundary.
    private static func affirmative(_ name: String, in text: String) -> Bool {
        var remainder = text.startIndex..<text.endIndex
        while let range = text.range(of: name, options: [.caseInsensitive], range: remainder) {
            let prefix = String(text[..<range.lowerBound].suffix(16))
            if prefix.range(of: #"(?:无|非|不是|没有|不含|未见|未出现|不出现|不得|禁止|不要|不能有)(?:任何|额外|多余|其他|明显|新增)?\s*$"#, options: .regularExpression) == nil { return true }
            remainder = range.upperBound..<text.endIndex
        }
        return false
    }
    private static func add(_ term: MaterialTaggingState.Term, into proposal: inout Proposal) {
        if term.dimension.isEmpty { proposal.tags.append(term.name) }
        else { proposal.categories.add(term.name, in: term.dimension) }
    }
}
