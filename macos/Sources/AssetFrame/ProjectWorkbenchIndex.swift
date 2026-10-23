import Foundation
import ImageIO

/// Rebuildable presentation index; original Markdown and explicit version bindings remain authoritative.
struct ProjectWorkbenchIndex: Sendable {
    struct Episode: Identifiable, Sendable {
        var id: String
        var title: String
        var paths: Set<String>
        var subjectIDs: Set<String> = []
        var status: String
    }
    struct Fact: Identifiable, Sendable {
        var label: String
        var value: String
        var source: String
        var evidence: String
        var id: String { label }
    }
    struct Media: Identifiable, Sendable {
        var id: String
        var material: MaterialRecord
        var variant: String
        var role: String
        var status: String
        var source: String
        var evidence: String
        var prompt = ""
        var reuse = ""
        var isDefault = false
        var exists: Bool
        var promptSources: [String] = []
    }
    struct Subject: Identifiable, Sendable {
        var id: String
        var name: String
        var kind: String
        var sources: Set<String> = []
        var facts: [Fact] = []
        var media: [Media] = []
        var issue = ""
        var introductionPaths: [String] = []
        var summary: String { facts.first { $0.label == "身份" }?.value ?? "资料已关联，查看详情" }
        var images: [Media] { media.filter { $0.material.kind == .image } }
        var audio: [Media] { media.filter { $0.material.kind == .audio } }
        var variants: [String] { Array(Set(media.map(\.variant))).sorted() }
    }
    var documents: [CharacterProjectDocument] = []
    var episodes: [Episode] = []
    var subjects: [Subject] = []
    var warnings: [String] = []
    var fileIndex = ProjectSourceFileIndex()
    struct ImageContext: Sendable {
        var media: Media
        var introductionPaths: [String]
    }
    var imageContexts: [String: ImageContext] = [:]

    static func header(_ text: String) -> [String: String] {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else { return [:] }
        return Dictionary(text[..<end.lowerBound].split(separator: "\n").compactMap { line -> (String, String)? in
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            return (String(pair[0]).trimmingCharacters(in: .whitespaces), String(pair[1]).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))))
        }, uniquingKeysWith: { a, _ in a })
    }
    static func captures(_ pattern: String, _ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }
    static func episodeID(_ text: String) -> String? {
        if let digits = captures(#"(?:^|[/\s])EP-(\d{1,4})(?=[/\s.]|$)"#, text).first, let n = Int(digits) { return String(format: "EP-%03d", n) }
        if let digits = captures(#"第\s*([0-9]{1,4})\s*集"#, text).first, let n = Int(digits) { return String(format: "EP-%03d", n) }
        return nil
    }
    static func isHistorical(_ path: String) -> Bool { ["历史", "停用", "归档", "备份"].contains { path.contains($0) } }
    static func title(_ doc: CharacterProjectDocument) -> String {
        doc.text.components(separatedBy: .newlines).first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? URL(fileURLWithPath: doc.path).deletingPathExtension().lastPathComponent
    }
    static func facts(_ text: String, source: String) -> [Fact] {
        let aliases: [(String, [String])] = [
            ("姓名", ["姓名", "正式姓名"]), ("年龄", ["年龄", "穿越后原身年龄", "现代年龄"]),
            ("性别", ["性别"]), ("身高", ["身高", "穿越后原身身高"]), ("体重", ["体重"]),
            ("身份", ["一句话身份", "穿越后身份", "身份"]), ("外貌", ["外貌", "外貌特征", "固定特征"]),
            ("性格", ["性格", "性格特点"]), ("人物关系", ["人物关系", "子女"]), ("说话特点", ["说话特点", "语言特点", "用词习惯"])
        ]
        var table: [String: (String, String)] = [:]
        for line in text.components(separatedBy: .newlines) where line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "") }
            if cells.count >= 2, let value = cells.last, !value.isEmpty { table[cells[0]] = (value, line) }
        }
        var result: [Fact] = []
        for (label, keys) in aliases {
            if let key = keys.first(where: { table[$0] != nil }), let (value, evidence) = table[key] {
                result.append(.init(label: label, value: value, source: source, evidence: evidence))
            }
        }
        for (label, headings) in [("性格", ["外在性格", "性格与可见行为"]), ("说话特点", ["动作与语言习惯", "说话特点"]), ("身份", ["一句话人物"])] where !result.contains(where: { $0.label == label }) {
            if let body = section(text, matching: headings), !body.isEmpty { result.append(.init(label: label, value: body, source: source, evidence: body)) }
        }
        return result
    }
    static func section(_ text: String, matching names: [String]) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let i = lines.firstIndex(where: { $0.hasPrefix("#") && names.contains(where: $0.contains) }) else { return nil }
        let depth = lines[i].prefix(while: { $0 == "#" }).count
        var body: [String] = []
        for line in lines.dropFirst(i + 1) {
            if line.hasPrefix("#"), line.prefix(while: { $0 == "#" }).count <= depth { break }
            body.append(line)
        }
        return body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func build(projectID: String, root: URL, documents: [CharacterProjectDocument], people: [CharacterLibraryStore.Loaded], graph: ProjectAssetGraph,
                      resources: [ProjectCatalogResource], materials: [MaterialRecord], links: [ProjectMaterialLink], jobs: [ProjectAutomationState.Job], documentLinks: [String: ProjectAutomationState.AssetDocumentLink] = [:]) -> Self {
        var result = Self(documents: documents)
        let docs = Dictionary(documents.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let inventory = CharacterWorkflowBridge.inventory(documents: documents, root: root, projectID: projectID)
        var subjects: [String: Subject] = [:]
        for person in inventory.people {
            let active = person.paths.filter { path in
                guard let doc = docs[path] else { return false }
                return !doc.text.contains("document_type: 停用人物追溯卡") && !doc.text.contains("status: 暂不启用")
            }
            guard !active.isEmpty else { continue }
            subjects[person.id] = Subject(id: person.id, name: person.name, kind: "人物", sources: active, issue: person.conflict ? "身份资料存在冲突" : "")
        }
        for person in people where person.entry.projectID == projectID {
            let id = person.entry.characterID
            if subjects[id] == nil, let profile = person.profile, person.text.contains(CharacterMarkdown.begin) { subjects[id] = Subject(id: id, name: profile.name, kind: "人物") }
            subjects[id]?.sources.insert(CharacterProjectModules.relative(URL(fileURLWithPath: person.entry.sourcePath), root: root))
        }
        for subject in graph.subjects {
            var merged = subjects[subject.id] ?? Subject(id: subject.id, name: subject.name, kind: subject.kind)
            merged.name = subject.name
            merged.kind = subject.kind
            if !subject.sourcePath.isEmpty { merged.sources.insert(subject.sourcePath) }
            subjects[subject.id] = merged
        }
        for doc in documents where !isHistorical(doc.path) {
            if let target = ProjectAutomationState.legacyAssetTarget(doc.text) {
                if subjects[target.id] == nil { subjects[target.id] = Subject(id: target.id, name: target.name, kind: target.kind) }
                subjects[target.id]?.sources.insert(doc.path)
            }
        }
        for job in jobs where job.active {
            if let target = job.target, subjects[target.id] != nil { subjects[target.id]?.sources.insert(job.path) }
        }
        // Explicit character_source links bind outfit cards; a filename or matching name alone cannot do so.
        for doc in documents {
            let meta = header(doc.text)
            if let assetID = meta["asset_id"], subjects[assetID] != nil {
                subjects[assetID]?.sources.insert(doc.path)
            }
            if let assetID = meta["asset_id"], meta["asset_type"]?.contains("人物") == true, subjects[assetID] == nil {
                let owners = subjects.keys.filter { assetID.hasPrefix($0 + "-") && subjects[$0]?.kind == "人物" }
                if owners.count == 1, let owner = owners.first {
                    subjects[owner]?.sources.insert(doc.path)
                    subjects[owner]?.issue = "部分形态按声明资产 ID 的层级展示，身份与用途仍以来源核对为准"
                }
            }
            if let path = meta["character_source"] {
                let url = CharacterProjectModules.resolve(doc.path, root: root).deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
                let relative = CharacterProjectModules.relative(url, root: root)
                for id in subjects.keys where subjects[id]?.sources.contains(relative) == true { subjects[id]?.sources.insert(doc.path) }
            }
        }
        let stored = Dictionary(materials.filter { $0.deletedAt == nil }.compactMap { m in m.sourcePath.map { (URL(fileURLWithPath: $0).standardizedFileURL.path, m) } }, uniquingKeysWith: { a, _ in a })
        func media(path: String, variant: String, role: String, status: String, source: String, evidence: String, prompt: String = "", reuse: String = "", isDefault: Bool = false) -> Media? {
            let url = CharacterProjectModules.resolve(path, root: root).standardizedFileURL
            let ext = url.pathExtension.lowercased()
            let kind: MaterialKind
            if ["png", "jpg", "jpeg", "webp", "heic", "tif", "tiff", "gif"].contains(ext) { kind = .image }
            else if ["mp3", "wav", "m4a", "aac", "aiff", "flac"].contains(ext) { kind = .audio }
            else if ["mp4", "mov"].contains(ext) { kind = .video } else { return nil }
            let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let key = CharacterMarkdown.fingerprint(Data(url.path.utf8))
            var record = stored[url.path] ?? MaterialRecord(id: "project-preview-" + key, kind: kind, name: url.deletingPathExtension().lastPathComponent, sourcePath: url.path, originalFilename: url.lastPathComponent, fingerprint: key, sourceLocations: [url.path], fileSize: attrs?.fileSize.map(Int64.init), createdAt: .distantPast, tags: [], rating: 0, note: "")
            // Always preview this exact referenced path, never a legacy higher resolution substitution.
            record.sourcePath = url.path; record.sourceLocations = [url.path]; record.legacyAsset = nil
            record.sourceModifiedAt = attrs?.contentModificationDate
            if kind == .image, let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] {
                var metadata = record.mediaMetadata ?? MaterialMediaMetadata()
                metadata.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
                metadata.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
                record.mediaMetadata = metadata
            }
            return Media(id: key, material: record, variant: variant, role: role, status: status, source: source, evidence: evidence, prompt: prompt, reuse: reuse, isDefault: isDefault, exists: FileManager.default.fileExists(atPath: url.path))
        }
        for id in subjects.keys.sorted() {
            guard var subject = subjects[id] else { continue }
            var assets: [Media] = []
            func append(_ item: Media?) { if let item, !assets.contains(where: { $0.id == item.id }) { assets.append(item) } }
            for asset in graph.assets where asset.subjectID == id {
                let verified = (try? ProjectAssetGraph.verify(asset, root: root)) != nil
                append(media(path: asset.path, variant: graph.variants.first { $0.id == asset.variantID }?.name ?? "待归组", role: asset.role,
                    status: verified ? asset.status : "指纹变化或失联 · 待核对", source: CharacterProjectModules.relative(ProjectAssetGraph.url(root: root), root: root), evidence: asset.evidence, prompt: asset.originalPrompt, reuse: asset.reuseTemplate, isDefault: verified && asset.isDefault))
            }
            for person in people where person.entry.projectID == projectID && person.entry.characterID == id {
                for receipt in person.receipts {
                    let receiptSource = documents.first { doc in
                        guard doc.kind == "确认记录", let record = try? CharacterProjectModules.decode(CharacterProjectModules.Receipt.self, text: doc.text, marker: "assetframe-confirmation") else { return false }
                        return record.id == receipt.id && record.sha256 == receipt.sha256 && record.originalPrompt == receipt.originalPrompt
                    }?.path ?? receipt.profilePath
                    append(media(path: receipt.assetPath, variant: receipt.variant, role: receipt.role, status: receipt.status, source: receiptSource, evidence: receipt.confirmationEvidence, prompt: receipt.originalPrompt, reuse: receipt.normalizedPrompt.keys.sorted().map { $0 + "：" + (receipt.normalizedPrompt[$0] ?? "") }.joined(separator: "\n")))
                }
                if let profile = person.profile {
                    for asset in profile.assets {
                        if let m = materials.first(where: { $0.id == asset.materialID && $0.deletedAt == nil }), let path = m.sourcePath {
                            append(media(path: path, variant: asset.variant, role: asset.role, status: "档案标注：" + asset.status, source: person.entry.sourcePath, evidence: "档案引用；确认指纹见制作记录"))
                        }
                    }
                    for (key, field) in profile.fields where !field.text.isEmpty && person.text.contains(CharacterMarkdown.begin) {
                        let label = key == "一句话身份" ? "身份" : key
                        subject.facts.append(.init(label: label, value: field.text, source: person.entry.sourcePath, evidence: field.evidence))
                    }
                }
            }
            for path in subject.sources.sorted() {
                guard let doc = docs[path] else { continue }
                let meta = header(doc.text)
                if meta["document_type"] == "人物角色卡" || doc.text.contains(CharacterMarkdown.begin) {
                    for fact in facts(doc.text, source: path) where !subject.facts.contains(where: { $0.label == fact.label }) { subject.facts.append(fact) }
                }
                // Shared sources are not automatically treated as this subject's own images.
                guard !CharacterWorkflowBridge.sharedKinds.contains(doc.kind), doc.kind != "剧情正文", doc.kind != "分镜记录", doc.kind != "制作接口" else { continue }
                let variant = meta["variant"] ?? meta["asset_name"] ?? "待归组"
                let prompt = section(doc.text, matching: ["原始生成提示词", "原始提示词"]) ?? ""
                for link in CharacterProjectScanner.assetLinks(doc, root: root) {
                    append(media(path: link.path, variant: variant, role: "原文引用", status: isHistorical(path) ? "历史资料" : "来源已关联 · 用途待核对", source: path, evidence: link.evidence, prompt: prompt))
                }
            }
            for resource in resources where resource.id == id || resource.id.hasPrefix(id + "-") {
                append(media(path: resource.path, variant: "待归组", role: "资源索引", status: resource.status, source: resource.source, evidence: resource.id + " → " + resource.path))
            }
            let accepted = jobs.filter { $0.target?.id == id && ["整理完成", "已采用"].contains($0.status) }.flatMap { job in
                (job.result?.fields ?? []).map { Fact(label: $0.name == "一句话身份" ? "身份" : $0.name, value: $0.value, source: job.path, evidence: "AI 整理 · 原文依据：" + $0.evidence) }
            }
            for label in Set(accepted.map(\.label)).sorted() where !subject.facts.contains(where: { $0.label == label }) {
                let facts = accepted.filter { $0.label == label }
                if Set(facts.map(\.value)).count == 1, let fact = facts.first { subject.facts.append(fact) }
            }
            subject.media = assets.sorted { a, b in a.isDefault != b.isDefault ? a.isDefault : a.material.name < b.material.name }
            subjects[id] = subject
        }
        // Resources with explicit IDs but no known subject stay visible independently, not assigned by name.
        for resource in resources where ["image", "audio", "video"].contains(resource.kind) && !subjects.values.contains(where: { $0.media.contains { $0.material.sourcePath == resource.path } }) {
            guard let item = media(path: resource.path, variant: "待归组", role: "资源索引", status: resource.status, source: resource.source, evidence: resource.id) else { continue }
            let kind = resource.id.hasPrefix("SC-") ? "场景" : resource.id.hasPrefix("PR-") ? "道具" : "其他"
            subjects[resource.id] = Subject(id: resource.id, name: item.material.name, kind: kind, sources: [resource.source], media: [item], issue: "资源索引关联；主体或用途待核对")
        }
        // Link prompt documents only through an exact image reference or an explicit prompt-MD link.
        func hasPrompt(_ doc: CharacterProjectDocument) -> Bool {
            doc.kind == "生成提示词" || doc.path.contains("提示词") ||
                doc.text.range(of: #"(?m)^#{1,6}\s+[^\n]*提示词"#, options: .regularExpression) != nil
        }
        var promptsByImage: [String: Set<String>] = [:]
        for doc in documents {
            var promptPaths: Set<String> = hasPrompt(doc) ? [doc.path] : []
            for linked in CharacterProjectScanner.markdownLinks(doc, root: root) {
                if let target = docs[linked], hasPrompt(target) { promptPaths.insert(linked) }
            }
            for raw in captures(#"\[[^\]]*(?:提示词|[Pp]rompt)[^\]]*\]\(<?([^>\n]+?)>?\)"#, doc.text) where !raw.contains("://") {
                let path = raw.components(separatedBy: "#")[0].removingPercentEncoding ?? raw
                let parent = CharacterProjectModules.resolve(doc.path, root: root).deletingLastPathComponent()
                let url = CharacterProjectModules.resolve(path, root: parent)
                if ["md", "markdown"].contains(url.pathExtension.lowercased()) { promptPaths.insert(CharacterProjectModules.relative(url, root: root)) }
            }
            guard !promptPaths.isEmpty else { continue }
            for image in CharacterProjectScanner.assetLinks(doc, root: root) { promptsByImage[URL(fileURLWithPath: image.path).resolvingSymlinksInPath().standardizedFileURL.path, default: []].formUnion(promptPaths) }
        }
        for id in subjects.keys.sorted() {
            guard var subject = subjects[id] else { continue }
            let introKey = ProjectAutomationState.assetDocumentKey(projectID: projectID, target: id, kind: "人物介绍")
            var introductions = Set(documentLinks[introKey]?.paths ?? [])
            if subject.kind == "人物" {
                for path in subject.sources {
                    if let doc = docs[path], doc.kind == "人物档案",
                       (header(doc.text)["document_type"] == "人物角色卡" || doc.text.contains(CharacterMarkdown.begin)) { introductions.insert(path) }
                }
                for person in people where person.entry.projectID == projectID && person.entry.characterID == id && person.profile != nil { introductions.insert(person.entry.sourcePath) }
            }
            subject.introductionPaths = introductions.sorted()
            for i in subject.media.indices {
                guard let path = subject.media[i].material.sourcePath else { continue }
                let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                let key = ProjectAutomationState.assetDocumentKey(projectID: projectID, target: canonical, kind: "生成提示词")
                var promptPaths = promptsByImage[canonical] ?? []
                promptPaths.formUnion(documentLinks[key]?.paths ?? [])
                if (!subject.media[i].prompt.isEmpty || !subject.media[i].reuse.isEmpty), ["md", "markdown"].contains(URL(fileURLWithPath: subject.media[i].source).pathExtension.lowercased()) { promptPaths.insert(subject.media[i].source) }
                subject.media[i].promptSources = promptPaths.sorted()
                if subject.media[i].material.kind == .image {
                    if var existing = result.imageContexts[canonical] {
                        existing.introductionPaths = Array(Set(existing.introductionPaths + subject.introductionPaths)).sorted()
                        existing.media.promptSources = Array(Set(existing.media.promptSources + subject.media[i].promptSources)).sorted()
                        result.imageContexts[canonical] = existing
                    } else { result.imageContexts[canonical] = .init(media: subject.media[i], introductionPaths: subject.introductionPaths) }
                }
            }
            subjects[id] = subject
        }
        result.subjects = subjects.values.sorted { ($0.kind, $0.id) < ($1.kind, $1.id) }
        var episodes: [String: Episode] = [:]
        for doc in documents where !isHistorical(doc.path) {
            guard let id = episodeID(doc.path) else { continue }
            if episodes[id] == nil { episodes[id] = Episode(id: id, title: id.replacingOccurrences(of: "EP-", with: "第 ") + " 集", paths: [], status: "来源待核对") }
            episodes[id]?.paths.insert(doc.path)
            if doc.path.hasSuffix("生产卡.md") {
                episodes[id]?.status = doc.text.components(separatedBy: .newlines).first { $0.hasPrefix("状态：") }.map { String($0.dropFirst(3)) } ?? "已读取生产卡"
                episodes[id]?.paths.formUnion(CharacterProjectScanner.markdownLinks(doc, root: root))
            }
        }
        for id in episodes.keys {
            guard var episode = episodes[id] else { continue }
            for path in episode.paths {
                guard let doc = docs[path] else { continue }
                let references = Set(captures(#"(?<![A-Za-z0-9])([A-Z][A-Z0-9]*-\d+(?:-[A-Z0-9]+)*)(?![A-Za-z0-9])"#, doc.text))
                for subject in result.subjects where references.contains(subject.id) || !subject.sources.isDisjoint(with: CharacterProjectScanner.markdownLinks(doc, root: root)) { episode.subjectIDs.insert(subject.id) }
            }
            for link in links where link.projectID == projectID && episodeID(link.episode ?? "") == id { if let subject = link.subjectID { episode.subjectIDs.insert(subject) } }
            episodes[id] = episode
        }
        result.episodes = episodes.values.sorted { $0.id < $1.id }
        return result
    }
}
