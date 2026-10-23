import Foundation

/// Read-only adapter for existing production Markdown. Grouping is a navigation hint,
/// never a declaration that a persona, asset, episode, or generation is confirmed.
enum CharacterWorkflowBridge {
    struct Person: Identifiable, Sendable {
        var id: String
        var name: String
        var paths: Set<String> = []
        var evidence: [String] = []
        var conflict = false
    }
    struct Inventory: Sendable {
        var people: [Person] = []
        var warnings: [String] = []
        var references: [CharacterProjectModules.Reference] = []
        func isUnchanged(_ doc: CharacterProjectDocument, characterID: String) -> Bool {
            references.contains { $0.characterID == characterID && $0.path == doc.path && $0.fingerprint == doc.fingerprint }
        }
    }
    static let sharedKinds: Set<String> = ["人物总表", "剧集索引", "项目入口", "资产注册表"]
    static func isStandard(_ doc: CharacterProjectDocument) -> Bool {
        if doc.kind == "制作接口" { return true }
        if doc.kind == "资产注册表" && doc.path.hasSuffix(".json") { return true }
        return [CharacterMarkdown.begin, "<!-- assetframe-confirmation:v1 -->", "<!-- assetframe-project-index:v1 -->", "<!-- assetframe-production:v1 -->"].contains { doc.text.contains($0) }
    }
    static func isHistoricalHint(_ path: String) -> Bool {
        ["候选", "历史", "停用", "归档", "备份"].contains { path.contains($0) }
    }
    private static func captures(_ pattern: String, _ text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { i in Range(match.range(at: i), in: text).map { String(text[$0]) } ?? "" }
        }
    }
    static func inventory(documents: [CharacterProjectDocument], root: URL, projectID: String) -> Inventory {
        var result = Inventory(), people: [String: Person] = [:]
        func add(_ id: String, _ name: String, path: String, evidence: String) {
            guard !id.isEmpty, !name.isEmpty else { return }
            if var old = people[id] {
                if old.name != name {
                    old.conflict = true
                    result.warnings.append("人物 ID \(id) 有不同姓名：\(old.name)／\(name)。保留来源，请核对改名或身份冲突。")
                }
                old.paths.insert(path); old.evidence.append(evidence); people[id] = old
            } else { people[id] = Person(id: id, name: name, paths: [path], evidence: [evidence]) }
        }
        // Standard identities are authoritative for identity, but not inferred facts.
        for doc in documents where doc.text.contains(CharacterMarkdown.begin) {
            do {
                guard let identity = try CharacterMarkdown.identity(doc.text), identity.projectID == projectID else {
                    result.warnings.append("标准档案属于其他项目，未归组：" + doc.path); continue
                }
                let profile = try CharacterMarkdown.decode(doc.text, projectID: projectID, characterID: identity.characterID)
                add(identity.characterID, profile.name, path: doc.path, evidence: doc.path + " · 标准身份")
            } catch { result.warnings.append("标准档案无法读取：" + doc.path) }
        }
        // Legacy modular cards declare identity in front matter; names belong to cards, not index labels.
        for doc in documents where !isStandard(doc) {
            guard doc.text.hasPrefix("---\n"), let end = doc.text.range(of: "\n---", range: doc.text.index(doc.text.startIndex, offsetBy: 4)..<doc.text.endIndex) else { continue }
            let header = String(doc.text[..<end.lowerBound])
            guard let id = captures(#"^character_id:\s*([A-Z][A-Z0-9]*-[0-9]+)\s*$"#, header).first?.first else { continue }
            // Asset cards reference a character, but do not own its name.
            guard header.contains("人物角色卡") || header.contains("人物卡") else { continue }
            let names = doc.text.components(separatedBy: .newlines).compactMap { line -> String? in
                let cells = line.split(separator: "|", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
                guard cells.count >= 2, ["正式姓名", "姓名"].contains(cells[0]), let value = cells.last else { return nil }
                let name = value.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "✅", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }
            guard let name = names.first else { continue }
            add(id, name, path: doc.path, evidence: doc.path + " · character_id 与姓名字段")
        }
        // Existing character interface tables already have IDs. No IDs from filenames.
        for doc in documents where doc.kind == "人物总表" {
            for line in doc.text.components(separatedBy: .newlines) {
                let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                for match in captures(#"^\|\s*([A-Z][A-Z0-9]*-[0-9]+)\s+([^|]+)\|"#, plain) {
                    guard captures(#"\b([A-Z][A-Z0-9]*-[0-9]+)\b"#, match[1]).isEmpty else {
                        result.warnings.append("人物表包含多人合并行，未自动拆分：" + doc.path + " · " + match[0]); continue
                    }
                    let name = match[1].trimmingCharacters(in: .whitespaces).components(separatedBy: "（")[0].trimmingCharacters(in: .whitespaces)
                    add(match[0], name, path: doc.path, evidence: doc.path + "\n" + line)
                }
            }
        }
        do { result.references = try CharacterProjectModules.readIndex(root: root, projectID: projectID).0.references }
        catch { result.warnings.append("模块索引未采用：" + error.localizedDescription) }
        // Follow explicit MD references from the character interface, including old-name paths.
        // A shared relationship document may legitimately be context for multiple characters.
        let available = Set(documents.map(\.path))
        for doc in documents where doc.kind == "人物总表" {
            for line in doc.text.components(separatedBy: .newlines) {
                let ids = Set(captures(#"\b([A-Z][A-Z0-9]*-[0-9]+)\b"#, line).map { $0[0] })
                guard !ids.isEmpty else { continue }
                for match in captures(#"\[[^\]]*\]\(<?([^>\n]+?)>?\)"#, line) {
                    let raw = match[0].components(separatedBy: "#")[0]
                    guard !raw.contains("://"), !raw.isEmpty else { continue }
                    let path = raw.removingPercentEncoding ?? raw
                    let parent = CharacterProjectModules.resolve(doc.path, root: root).deletingLastPathComponent()
                    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : parent.appendingPathComponent(path)
                    let relative = CharacterProjectModules.relative(url, root: root)
                    guard available.contains(relative) else { continue }
                    for id in ids where people[id] != nil { people[id]?.paths.insert(relative) }
                }
            }
        }
        for doc in documents where !isStandard(doc) && !sharedKinds.contains(doc.kind) {
            let explicitIDs = Set(captures(#"^\|\s*(?:角色[／/]资产 ID|人物 ID|角色 ID)\s*\|\s*`?([A-Z][A-Z0-9]*-[0-9]+)(?:[／/\s`|])"#, doc.text).map { $0[0] })
            let indexedIDs = Set(result.references.filter { $0.path == doc.path }.map(\.characterID))
            let ids = explicitIDs.union(indexedIDs)
            if ids.count > 1 {
                result.warnings.append("资料有多个人物 ID，未自动归组：" + doc.path); continue
            }
            if let id = ids.first, var person = people[id] {
                person.paths.insert(doc.path); people[id] = person
            } else if ids.isEmpty {
                let matches = people.values.filter { !doc.name.isEmpty && $0.name == doc.name }
                if matches.count == 1, let person = matches.first {
                    result.warnings.append("姓名关联建议（未自动采用）：\(doc.path) → \(person.id) \(person.name)")
                }
            }
        }
        // Explicit front-matter references attach asset and voice cards without guessing from names.
        for doc in documents where !isStandard(doc) {
            guard doc.text.hasPrefix("---\n"), let end = doc.text.range(of: "\n---", range: doc.text.index(doc.text.startIndex, offsetBy: 4)..<doc.text.endIndex) else { continue }
            let header = String(doc.text[..<end.lowerBound])
            if let id = captures(#"^character_id:\s*([A-Z][A-Z0-9]*-[0-9]+)\s*$"#, header).first?.first, people[id] != nil {
                people[id]?.paths.insert(doc.path)
            }
        }
        // Receipts bind to an exact project and person; content hash still checked on import.
        for doc in documents where doc.kind == "确认记录" {
            if let receipt = try? CharacterProjectModules.decode(CharacterProjectModules.Receipt.self, text: doc.text, marker: "assetframe-confirmation"),
               receipt.projectID == projectID, var person = people[receipt.characterID] {
                person.paths.insert(doc.path); people[person.id] = person
            }
        }
        result.people = people.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        return result
    }
    static func recommended(_ person: Person, documents: [CharacterProjectDocument], inventory: Inventory, changedOnly: Bool) -> Set<String> {
        guard !person.conflict else { return [] }
        return Set(documents.filter {
            person.paths.contains($0.path) && !isHistoricalHint($0.path) &&
            (!changedOnly || !inventory.isUnchanged($0, characterID: person.id))
        }.map(\.path))
    }
    static func handoff(projectID: String, root: URL, documents: [CharacterProjectDocument], characterID: String, name: String) -> String {
        let refs = documents.map { "- \($0.kind)：\($0.path)\n  SHA-256：\($0.fingerprint)" }.joined(separator: "\n")
        return """
        # 漫剧人物工作流交接

        项目根目录：\(root.path)
        项目 ID：\(projectID)
        人物 ID：\(characterID)
        人物姓名候选：\(name)

        ## 本次选取的来源
        \(refs)

        ## 读取与回写约定
        1. 先核对上述来源当前内容与指纹。人物总表管身份，剧集索引定位当前正文，专属资产说明管具体视觉用途；路径和版本号不证明当前生效。
        2. 沿用项目 ID 与稳定人物 ID。改名保留 ID；多个来源有冲突时列出依据，不另造人物或静默覆盖。
        3. 人物库索引/索引.md 只保存引用与指纹。已有标准人物 MD 是唯一标准档案，直接关联；原说明书、原始生成提示词、历史记录保持原路径。
        4. 生成后保存实际文件、原始提示词、平台/模型及参考来源。缺失信息留空；标准化模板另存，不能冒充实际生成原文。
        5. 用户确认具体结果后才登记确认，绑定实际文件 SHA-256、用途和适用阶段；视觉确认、声线确认、技术 QA、剧情事实分别记录。使用软件“记录资产确认”或现有 assetframe-confirmation:v1 规范，不凭“已确认”文件名推断。
        6. 修改前核对文件漂移并备份，保留未知段落。下游分镜只引用本次需要的具体版本；新图不自动替换旧分镜、LibTV 或剪映内容。
        7. DeepSeek 只整理本次主动选定的 MD，输出候选字段、逐字依据和冲突；不自动确认、生成、发布或改写正式项目。

        以上是交接上下文，不是自动授权修改。执行范围仍按用户当前请求。
        """
    }
}
