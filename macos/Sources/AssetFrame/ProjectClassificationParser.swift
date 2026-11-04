import Foundation
import CryptoKit

/// 有界、只读的 Markdown 索引解析。只读取用户选定的索引正文，其他文件只作路径核验。
enum ProjectClassificationParser {
    enum ParseError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
    }

    private static let maximumEntries = 12_000
    private static let maximumIndexBytes = 2_000_000
    private static let mediaExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tif", "tiff", "bmp", "avif", "svg",
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "mp3", "wav", "m4a", "aac", "aiff", "flac", "ogg"
    ]
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mkd"]

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
            .precomposedStringWithCanonicalMapping
    }

    static func path(_ candidate: String, isInside root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root == "/" ? "/" : root + "/")
    }

    static func isWithin(_ path: String, roots: [String]) -> Bool {
        let candidate = canonical(path)
        return roots.contains { Self.path(candidate, isInside: canonical($0)) }
    }

    /// 禁止沿授权根内部的符号链接读取或匹配；允许系统 /tmp 本身的系统级路径别名。
    static func isSafePath(_ candidate: String, roots: [String]) -> Bool {
        let lexical = URL(fileURLWithPath: (candidate as NSString).expandingTildeInPath).standardizedFileURL.path
        for root in roots {
            let originalRoot = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).standardizedFileURL.path
            let lexicalRoot = path(lexical, isInside: originalRoot) ? originalRoot : canonical(root)
            guard path(lexical, isInside: lexicalRoot) else { continue }
            var current = lexicalRoot
            if isSymlink(current) { continue }
            let suffix = String(lexical.dropFirst(lexicalRoot.count))
            var safe = true
            for component in suffix.split(separator: "/") {
                current = (current as NSString).appendingPathComponent(String(component))
                if isSymlink(current) { safe = false; break }
            }
            if safe && path(canonical(lexical), isInside: canonical(root)) { return true }
        }
        return false
    }

    private static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private static func excluded(_ name: String) -> Bool {
        let lower = name.lowercased()
        return name.hasPrefix(".") || ["node_modules", "dist", "build", "backup", "backups", "cache", "caches", "rollback"].contains(lower)
            || ["历史", "备份", "缓存", "回滚", "归档"].contains(where: name.contains)
    }

    private static func catalog(roots: [String]) throws -> [String] {
        guard !roots.isEmpty else { throw ParseError.invalid("尚未选择项目目录。") }
        var result: Set<String> = []
        var visited: Set<String> = []
        var inspected = 0
        for rawRoot in roots {
            var isDirectory: ObjCBool = false
            guard isSafePath(rawRoot, roots: roots), FileManager.default.fileExists(atPath: rawRoot, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ParseError.invalid("项目目录不存在、不是文件夹或为符号链接：\(rawRoot)")
            }
            var pending: [(String, Int)] = [(rawRoot, 0)]
            while let (folder, depth) = pending.popLast() {
                guard visited.insert(canonical(folder)).inserted else { continue }
                guard depth <= 24 else { throw ParseError.invalid("项目目录层级超过 24 层，请缩小索引目录范围。") }
                let children = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey], options: [])
                    .sorted { $0.path < $1.path }
                for child in children {
                    inspected += 1
                    guard inspected <= maximumEntries else { throw ParseError.invalid("项目扫描超过 \(maximumEntries) 项，请缩小目录范围。") }
                    if excluded(child.lastPathComponent) { continue }
                    let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
                    guard values.isSymbolicLink != true, isSafePath(child.path, roots: roots) else { continue }
                    if values.isDirectory == true {
                        result.insert(canonical(child.path)); pending.append((child.path, depth + 1))
                    } else if values.isRegularFile == true { result.insert(canonical(child.path)) }
                }
            }
        }
        return result.sorted()
    }

    static func discover(roots: [String]) throws -> [String] {
        try catalog(roots: roots).filter { markdownExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    static func fingerprint(_ path: String) throws -> String {
        let lexical = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        var prefix = "/"
        for component in lexical.split(separator: "/") {
            prefix = (prefix as NSString).appendingPathComponent(String(component))
            if isSymlink(prefix) {
                let systemAlias = ["/tmp": "/private/tmp", "/var": "/private/var", "/etc": "/private/etc"]
                let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: prefix)
                guard let expected = systemAlias[prefix], destination == expected || destination == String(expected.dropFirst()) else {
                    throw ParseError.invalid("来源路径经过符号链接，未读取：\(path)")
                }
            }
        }
        let values = try FileManager.default.attributesOfItem(atPath: path)
        guard values[.type] as? FileAttributeType == .typeRegular else { throw ParseError.invalid("来源必须是普通文件，不能是符号链接：\(path)") }
        guard (values[.size] as? NSNumber)?.intValue ?? Int.max <= maximumIndexBytes else { throw ParseError.invalid("索引超过 2 MB，请拆分后重试。") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count <= maximumIndexBytes else { throw ParseError.invalid("读取时索引超过 2 MB，请拆分后重试。") }
        return digest(data)
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func stableID(_ components: [String]) -> String {
        "pcat-" + digest(Data(components.map { "\($0.utf8.count):\($0)" }.joined().utf8))
    }
    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    private struct Link {
        var target: String
        var label: String
        var wiki: Bool
    }
    private struct Association {
        var key: String
        var ids: Set<String>
        var warnings: [String]
    }

    static func parse(roots: [String], indexPaths: [String], materials: [MaterialRecord]) throws -> ProjectClassificationDraft {
        guard !indexPaths.isEmpty else { throw ParseError.invalid("请选择至少一份索引。") }
        // 索引验证在正文读取之前完成；失败不会产生半份可采用草稿。
        for file in indexPaths {
            guard isSafePath(file, roots: roots), isWithin(file, roots: roots) else { throw ParseError.invalid("索引越出项目目录或经过符号链接：\(file)") }
            guard markdownExtensions.contains((file as NSString).pathExtension.lowercased()) else { throw ParseError.invalid("首版仅支持 Markdown 索引：\(file)") }
        }
        let files = try catalog(roots: roots)
        let scope = roots.map(canonical).sorted().joined(separator: "\u{0}")
        let available = materials.filter { $0.deletedAt == nil }
        var pathIDs: [String: Set<String>] = [:]
        for material in available {
            for source in ([material.sourcePath].compactMap { $0 } + material.sourceLocations) where isWithin(source, roots: roots) {
                pathIDs[canonical(source), default: []].insert(material.id)
            }
        }
        var draft = ProjectClassificationDraft(sources: [], dimensions: [], warnings: [])
        var seenSources: Set<String> = []
        for rawSource in indexPaths {
            let source = canonical(rawSource)
            guard seenSources.insert(source).inserted else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: rawSource)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= maximumIndexBytes else {
                throw ParseError.invalid("索引不是普通文件或超过 2 MB：\(rawSource)")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: rawSource))
            guard data.count <= maximumIndexBytes else { throw ParseError.invalid("读取时索引超过 2 MB，请拆分后重试。") }
            guard let content = String(data: data, encoding: .utf8) else { throw ParseError.invalid("索引不是 UTF-8 文本：\(source)") }
            draft.sources.append(ProjectClassificationSource(path: source, fingerprint: digest(data)))
            let lines = content.components(separatedBy: .newlines)
            var section = "目录导航"
            var priority: Int? = nil
            var headers: [String]? = nil
            var inCode = false
            for (offset, rawLine) in lines.enumerated() {
                let line = normalized(rawLine)
                if line.hasPrefix("```") || line.hasPrefix("~~~") { inCode.toggle(); continue }
                if inCode { continue }
                let evidence = ProjectClassificationEvidence(path: source, line: offset + 1, text: String(rawLine.prefix(800)))
                if let heading = headingText(line) {
                    section = cleanLabel(heading)
                    priority = priorityValue(heading)
                    headers = nil
                    continue
                }
                if line.contains("|") {
                    let cells = tableCells(line)
                    if cells.count >= 2 {
                        if cells.allSatisfy({ $0.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
                        if cells.contains(where: { isTypeHeader($0) }) {
                            headers = cells; continue
                        }
                        if let headers, let typeColumn = headers.firstIndex(where: isTypeHeader), cells.indices.contains(typeColumn) {
                            let type = cleanLabel(cells[typeColumn])
                            guard !type.isEmpty, type != "-" else { continue }
                            var associations: [Association] = []
                            for (column, cell) in cells.enumerated() where column != typeColumn {
                                var found = links(in: cell)
                                if found.isEmpty, headers.indices.contains(column), isPathHeader(headers[column]), looksLikeLocalPath(cell) {
                                    found = [Link(target: cell.trimmingCharacters(in: CharacterSet(charactersIn: "` ")), label: cell, wiki: false)]
                                }
                                associations += found.map { associate($0, source: source, roots: roots, files: files, pathIDs: pathIDs) }
                            }
                            var ids = Set<String>()
                            var warnings: [String] = []
                            for association in associations { ids.formUnion(association.ids); warnings += association.warnings }
                            if associations.isEmpty { warnings.append("该类型行没有可识别的素材链接。") }
                            addOption(scope: scope, dimension: "类型", optionKey: "type:" + type, label: type,
                                      ids: ids, warnings: warnings, evidence: evidence, priority: nil, draft: &draft)
                            continue
                        }
                    }
                } else { headers = nil }
                for link in links(in: line) {
                    let association = associate(link, source: source, roots: roots, files: files, pathIDs: pathIDs)
                    let label = cleanLabel(link.label.isEmpty ? (link.target as NSString).lastPathComponent : link.label)
                    addOption(scope: scope, dimension: section, optionKey: association.key, label: label,
                              ids: association.ids, warnings: association.warnings, evidence: evidence, priority: priority, draft: &draft)
                }
            }
        }
        // 优先级仅建立默认次序；保存后人工 order 的含义保持一致。
        draft.dimensions.sort {
            if $0.priority != $1.priority { return ($0.priority ?? Int.max) < ($1.priority ?? Int.max) }
            return $0.order < $1.order
        }
        for index in draft.dimensions.indices { draft.dimensions[index].order = index }
        if draft.dimensions.isEmpty { draft.warnings.append("所选索引没有可识别的类型表或链接导航，请检查格式。") }
        draft.warnings = Array(Set(draft.warnings)).sorted()
        return draft
    }

    private static func addOption(scope: String, dimension: String, optionKey: String, label: String, ids: Set<String>,
                                  warnings: [String], evidence: ProjectClassificationEvidence, priority: Int?, draft: inout ProjectClassificationDraft) {
        let dimensionID = stableID([scope, "dimension", dimension])
        if !draft.dimensions.contains(where: { $0.id == dimensionID }) {
            draft.dimensions.append(ProjectClassificationDimension(id: dimensionID, sourceName: dimension, displayName: "", order: draft.dimensions.count, priority: priority))
        }
        guard let d = draft.dimensions.firstIndex(where: { $0.id == dimensionID }) else { return }
        let optionID = stableID([dimensionID, optionKey])
        if let o = draft.dimensions[d].options.firstIndex(where: { $0.id == optionID }) {
            draft.dimensions[d].options[o].materialIDs.formUnion(ids)
            if !draft.dimensions[d].options[o].evidence.contains(evidence) { draft.dimensions[d].options[o].evidence.append(evidence) }
            draft.dimensions[d].options[o].warnings = Array(Set(draft.dimensions[d].options[o].warnings + warnings)).sorted()
        } else {
            draft.dimensions[d].options.append(ProjectClassificationOption(id: optionID, sourceName: label, order: draft.dimensions[d].options.count,
                                                                           materialIDs: ids, evidence: [evidence], warnings: Array(Set(warnings)).sorted()))
        }
        draft.warnings += warnings.map { "\((evidence.path as NSString).lastPathComponent):\(evidence.line)：\($0)" }
    }

    private static func associate(_ link: Link, source: String, roots: [String], files: [String], pathIDs: [String: Set<String>]) -> Association {
        var raw = normalized(link.target).replacingOccurrences(of: "\\|", with: "|")
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        if raw.hasPrefix("#") || raw.isEmpty { return Association(key: "anchor:" + raw, ids: [], warnings: ["页内导航不自动关联素材。 "]) }
        if raw.lowercased().hasPrefix("file://"), let url = URL(string: raw), url.isFileURL { raw = url.path }
        else if raw.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil {
            return Association(key: "remote:" + raw, ids: [], warnings: ["外部链接仅保留导航，不访问或关联素材：\(raw)"])
        }
        raw = raw.components(separatedBy: "#")[0].components(separatedBy: "?")[0]
        raw = raw.removingPercentEncoding ?? raw
        raw = normalized(raw)
        let folder = (source as NSString).deletingLastPathComponent
        let relative = raw.hasPrefix("/") ? raw : (folder as NSString).appendingPathComponent(raw)
        guard isWithin(relative, roots: roots) else { return Association(key: "path:" + canonical(relative), ids: [], warnings: ["链接越出项目目录：\(raw)"]) }
        guard isSafePath(relative, roots: roots) else { return Association(key: "path:" + canonical(relative), ids: [], warnings: ["链接经过符号链接，未访问：\(raw)"]) }
        var candidates: Set<String> = []
        let variants = (raw as NSString).pathExtension.isEmpty ? [raw, raw + ".md"] : [raw]
        for variant in variants {
            let direct = variant.hasPrefix("/") ? variant : (folder as NSString).appendingPathComponent(variant)
            if isSafePath(direct, roots: roots), FileManager.default.fileExists(atPath: direct) { candidates.insert(canonical(direct)) }
        }
        // 明确相对路径首先按索引所在目录解释；Obsidian 短双链才作根内唯一搜索。
        if candidates.isEmpty {
            for root in roots {
                for variant in variants where !variant.hasPrefix("/") {
                    let candidate = (root as NSString).appendingPathComponent(variant)
                    if isSafePath(candidate, roots: roots), FileManager.default.fileExists(atPath: candidate) { candidates.insert(canonical(candidate)) }
                }
            }
            if candidates.isEmpty && link.wiki && !raw.contains("/") {
                let names = Set(variants)
                candidates.formUnion(files.filter { names.contains(($0 as NSString).lastPathComponent) })
            }
        }
        guard candidates.count <= 1 else { return Association(key: "ambiguous:" + raw, ids: [], warnings: ["链接重名多义，需明确路径：\(raw)"]) }
        guard let target = candidates.first else { return Association(key: "path:" + canonical(relative), ids: [], warnings: ["链接失效或目标不存在：\(raw)"]) }
        guard isWithin(target, roots: roots) else { return Association(key: "path:" + target, ids: [], warnings: ["链接越出项目目录：\(raw)"]) }
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            let ids = pathIDs.filter { path($0.key, isInside: target) }.reduce(into: Set<String>()) { $0.formUnion($1.value) }
            return Association(key: "path:" + target, ids: ids, warnings: ids.isEmpty ? ["目录内没有已入库素材：\(raw)"] : [])
        }
        let ext = (target as NSString).pathExtension.lowercased()
        guard mediaExtensions.contains(ext) else {
            return Association(key: "path:" + target, ids: [], warnings: ["文档仅作导航，不自动推断图片：\(raw)"])
        }
        let ids = pathIDs[target] ?? []
        guard ids.count <= 1 else { return Association(key: "path:" + target, ids: [], warnings: ["同一路径对应多个素材，关联存在歧义：\(raw)"]) }
        return Association(key: "path:" + target, ids: ids, warnings: ids.isEmpty ? ["媒体尚未入库：\(raw)"] : [])
    }

    static func adopting(_ draft: ProjectClassificationDraft, into profile: ProjectClassificationProfile) -> ProjectClassificationProfile {
        var result = profile
        result.sources = draft.sources
        result.issue = draft.warnings.isEmpty ? nil : draft.warnings.joined(separator: "\n")
        result.dimensions = draft.dimensions.map { dimension in
            guard let old = profile.dimensions.first(where: { $0.id == dimension.id }) else { return dimension }
            var updated = dimension
            updated.displayName = old.displayName
            updated.order = old.order
            updated.pinned = old.pinned
            updated.manualOrder = old.manualOrder
            updated.options = dimension.options.map { option in
                guard let previous = old.options.first(where: { $0.id == option.id }) else { return option }
                var option = option
                option.displayName = previous.displayName
                option.order = previous.order
                option.pinned = previous.pinned
                option.manualOrder = previous.manualOrder
                option.manualMaterialIDs = previous.manualMaterialIDs
                option.manualPaths = previous.manualPaths
                option.mergedIDs = previous.mergedIDs
                return option
            }
            let mergedMembers = old.options.reduce(into: Set<String>()) { $0.formUnion($1.mergedIDs) }
            for previous in old.options where !updated.options.contains(where: { $0.id == previous.id }) && !mergedMembers.contains(previous.id) {
                updated.options.append(unavailable(previous))
            }
            // 合并是持久校正：刷新后仍把源成员折入目标，不让源选项复活。
            for index in updated.options.indices where !updated.options[index].mergedIDs.isEmpty {
                var merged = updated.options[index].mergedIDs
                var pending = Array(merged)
                while let id = pending.popLast() {
                    guard let member = updated.options.first(where: { $0.id == id }) else { continue }
                    let additions = member.mergedIDs.subtracting(merged)
                    merged.formUnion(additions)
                    pending.append(contentsOf: additions)
                    updated.options[index].materialIDs.formUnion(member.materialIDs)
                    updated.options[index].manualMaterialIDs.formUnion(member.manualMaterialIDs)
                    updated.options[index].manualPaths = Array(Set(updated.options[index].manualPaths + member.manualPaths)).sorted()
                    updated.options[index].evidence = Array(Set(updated.options[index].evidence + member.evidence))
                        .sorted { $0.path == $1.path ? $0.line < $1.line : $0.path < $1.path }
                    updated.options[index].warnings = Array(Set(updated.options[index].warnings + member.warnings)).sorted()
                    if !member.unavailable { updated.options[index].unavailable = false }
                }
                updated.options[index].mergedIDs = merged
            }
            updated.options.removeAll { mergedMembers.contains($0.id) }
            return updated
        }
        for old in profile.dimensions where !result.dimensions.contains(where: { $0.id == old.id }) {
            var old = old
            old.options = old.options.map(unavailable)
            result.dimensions.append(old)
        }
        // 选择故意不裁剪；过期条件可见且为零命中，用户可以主动移除。
        return result
    }

    private static func unavailable(_ option: ProjectClassificationOption) -> ProjectClassificationOption {
        var option = option
        option.materialIDs = []
        option.unavailable = true
        let warning = "该选项已从索引移除；自动关联已停用，请检查或移除条件。"
        if !option.warnings.contains(warning) { option.warnings.append(warning) }
        return option
    }

    private static func headingText(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let prefix = line.prefix(while: { $0 == "#" })
        guard prefix.count <= 6, line.dropFirst(prefix.count).first?.isWhitespace == true else { return nil }
        return normalized(String(line.dropFirst(prefix.count))).trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    }

    private static func priorityValue(_ text: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: "(?:优先级|priority)\\s*[:：=]\\s*(\\d+)", options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    private static func cleanLabel(_ text: String) -> String {
        var result = normalized(text).replacingOccurrences(of: "\\|", with: "|")
        result = result.replacingOccurrences(of: "[\\[（(]?(?:优先级|priority)\\s*[:：=]\\s*\\d+[\\]）)]?", with: "", options: [.regularExpression, .caseInsensitive])
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "`*_ "))
    }

    private static func isTypeHeader(_ text: String) -> Bool {
        ["类型", "素材类型", "资产类型", "type", "asset type", "asset_type"].contains(cleanLabel(text).lowercased())
    }
    private static func isPathHeader(_ text: String) -> Bool {
        let name = cleanLabel(text).lowercased()
        return ["path", "file", "image", "url", "link", "路径", "图片", "文件", "链接"].contains(where: name.contains)
    }
    private static func looksLikeLocalPath(_ text: String) -> Bool {
        let text = cleanLabel(text)
        return text.contains("/") || mediaExtensions.contains((text as NSString).pathExtension.lowercased()) || markdownExtensions.contains((text as NSString).pathExtension.lowercased())
    }

    private static func tableCells(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var escaping = false
        var wikiDepth = 0
        let characters = Array(line)
        for (index, char) in characters.enumerated() {
            if escaping { current.append("\\"); current.append(char); escaping = false; continue }
            if char == "\\" { escaping = true; continue }
            if char == "[", index + 1 < characters.count, characters[index + 1] == "[" { wikiDepth += 1 }
            if char == "]", index + 1 < characters.count, characters[index + 1] == "]" { wikiDepth = max(0, wikiDepth - 1) }
            if char == "|" && wikiDepth == 0 { result.append(normalized(current)); current = "" }
            else { current.append(char) }
        }
        if escaping { current.append("\\") }
        result.append(normalized(current))
        if line.hasPrefix("|"), result.first == "" { result.removeFirst() }
        if line.hasSuffix("|"), result.last == "" { result.removeLast() }
        return result
    }

    private static func links(in text: String) -> [Link] {
        let text = text.replacingOccurrences(of: #"\\+\|"#, with: "|", options: .regularExpression)
        var located: [(Int, Link)] = []
        var occupied: [NSRange] = []
        if let expression = try? NSRegularExpression(pattern: "!?\\[\\[([^\\]]+)\\]\\]") {
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let parts = String(text[range]).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let target = normalized(String(parts[0]))
                located.append((match.range.location, Link(target: target, label: parts.count > 1 ? normalized(String(parts[1])) : (target as NSString).lastPathComponent, wiki: true)))
                occupied.append(match.range)
            }
        }
        if let expression = try? NSRegularExpression(pattern: "!?\\[([^\\]]*)\\]\\((<[^>]*>|[^)]*)\\)") {
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if occupied.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
                guard let labelRange = Range(match.range(at: 1), in: text), let targetRange = Range(match.range(at: 2), in: text) else { continue }
                var target = normalized(String(text[targetRange]))
                if target.hasPrefix("<"), let end = target.firstIndex(of: ">") { target = String(target[target.index(after: target.startIndex)..<end]) }
                else { target = target.replacingOccurrences(of: "\\s+[\"'][^\"']*[\"']$", with: "", options: .regularExpression) }
                located.append((match.range.location, Link(target: target, label: String(text[labelRange]), wiki: false)))
            }
        }
        return located.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
}
