import Foundation

@main
struct CharacterLibrarySelfTest {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw CharacterLibraryError.invalid("FAIL: " + message) }
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw CharacterLibraryError.invalid("FAIL: expected rejection: " + message)
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("assetframe-characters-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("项目A"), secondRoot = root.appendingPathComponent("项目B")
        try fm.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let store = CharacterLibraryStore(root: root)
        let p = try store.addProject(name: "项目A", root: projectRoot)
        let q = try store.addProject(name: "项目B", root: secondRoot)
        let same = try store.addProject(name: "重复目录", root: projectRoot)
        try check(same == p && store.registry.projects.count == 2, "project path deduplication")
        var profile = CharacterProfile(projectID: p, characterID: "N-07")
        profile.fields["姓名"] = .init(text: "陶知夏", review: .confirmed)
        profile.fields["别名"] = .init(text: "陶知微", review: .confirmed)
        profile.fields["性格"] = .init(text: "毒舌心善", review: .confirmed, evidence: "项目已采用")
        profile.fields["一句话身份"] = .init(text: "医馆验药", review: .confirmed)
        profile.fields["图片提示词"] = .init(text: "固定脸\n保留服装\n四宫格", review: .candidate)
        let old = "# 老资料\r\n\r\n保留未知栏目、历史说明与 [旧图](../旧图.png)\r\n"
        let text = try CharacterMarkdown.render(profile, replacing: old)
        try check(text.hasPrefix(old), "legacy bytes remain intact")
        let decoded = try CharacterMarkdown.decode(text, projectID: p, characterID: "N-07")
        try check(decoded == profile, "profile round trip")
        try check(decoded.matches("医馆 + 毒舌") && decoded.matches("陶知微"), "AND query and former name")
        try check(!decoded.matches("医馆 军营"), "AND query doesn't overmatch")
        try check(!decoded.hasConfirmedAsset, "confirmed text is not confirmed visual")
        profile.assets = [.init(materialID: "image-a", role: "主图", status: "已确认", defaultUse: "开局"), .init(materialID: "image-old", role: "主图", status: "历史停用")]
        profile.stories = [.init(episode: "07", summary: "验药", source: "正文/第07集.md#交易", state: "当前正文")]
        try check(profile.hasConfirmedAsset, "current confirmation")
        var invalid = profile; invalid.assets.append(invalid.assets[0])
        try rejects("duplicate asset ID") { try invalid.validate() }
        invalid = profile; invalid.assets.append(.init(materialID: "other", role: "主图", status: "已确认", defaultUse: "开局"))
        try rejects("ambiguous default") { try invalid.validate() }
        let file = projectRoot.appendingPathComponent("旧名.md")
        let final = try CharacterMarkdown.render(profile, replacing: old)
        try Data(final.utf8).write(to: file)
        let entryID = try store.attach(file, projectID: p, characterID: "N-07")
        let duplicate = try store.attach(file, projectID: p, characterID: "N-07")
        try check(duplicate == entryID && store.registry.entries.count == 1, "idempotent attachment")
        try rejects("foreign project cannot silently adopt identity") { _ = try store.attach(file, projectID: q, characterID: "N-07") }
        var other = profile; other.projectID = q
        let otherFile = secondRoot.appendingPathComponent("同名.md")
        try Data(CharacterMarkdown.render(other, replacing: "").utf8).write(to: otherFile)
        _ = try store.attach(otherFile, projectID: q, characterID: "N-07")
        await store.refresh()
        try check(store.loaded.count == 2 && Set(store.loaded.map(\.id)).count == 2, "same name and role ID across projects")
        let loaded = store.loaded.first { $0.id == entryID }!
        var rename = profile; rename.fields["姓名"]?.text = "新姓名"
        let saved = await store.save(profile: rename, loaded: loaded)
        try check(saved && store.loaded.first { $0.id == entryID }?.profile?.name == "新姓名", "rename preserves stable identity")
        let backups = try fm.contentsOfDirectory(at: projectRoot.appendingPathComponent(".assetframe-character-backups"), includingPropertiesForKeys: nil)
        try check(backups.count == 1 && (try Data(contentsOf: backups[0])) == Data(final.utf8), "exact recoverable backup")
        let fresh = store.loaded.first { $0.id == entryID }!
        let external = fresh.text + "\n外部改动\n"
        try Data(external.utf8).write(to: file)
        let conflict = await store.save(profile: profile, loaded: fresh)
        try check(!conflict && (try String(contentsOf: file, encoding: .utf8)) == external, "external change not overwritten")
        await store.refresh()
        try check(store.loaded.first { $0.id == entryID }?.text == external, "refresh reads external file")
        let beforeRegistry = try String(contentsOf: root.appendingPathComponent("character-library.json"), encoding: .utf8)
        try check(!beforeRegistry.contains("毒舌") && !beforeRegistry.contains("新姓名"), "registry has references, no second persona text")
        let reopened = CharacterLibraryStore(root: root); await reopened.refresh()
        try check(reopened.loaded.count == 2, "reopen rebuilds in-memory index")
        try fm.removeItem(at: file); await reopened.refresh()
        try check(reopened.loaded.first { $0.id == entryID }?.error != nil, "missing source retained as error, not empty replacement")
        try rejects("malformed owned block") { _ = try CharacterMarkdown.decode(old + CharacterMarkdown.begin, projectID: p, characterID: "N-07") }
        try rejects("multiple owned blocks") { _ = try CharacterMarkdown.render(profile, replacing: final + final) }
        var marked = profile; marked.fields["姓名"]?.text = "注入\n### 性格\n错误"
        try rejects("structural marker injection") { _ = try CharacterMarkdown.render(marked, replacing: old) }
        let sources = [CharacterExtractionClient.Source(path: "所选.md", text: "陶知夏毒舌心善，负责验药。")]
        let response = """
        {"suggestions":[{"field":"性格","value":"毒舌心善","source":"所选.md","evidence":"毒舌心善","conflict":""}]}
        """
        let result = try CharacterExtractionClient.decode(response, sources: sources)
        try check(result.count == 1, "mock AI response with verified evidence")
        try rejects("fabricated AI evidence") { _ = try CharacterExtractionClient.decode(response.replacingOccurrences(of: "\"evidence\":\"毒舌心善\"", with: "\"evidence\":\"世袭王侯\""), sources: sources) }
        try rejects("unselected source") { _ = try CharacterExtractionClient.decode(response.replacingOccurrences(of: "所选.md", with: "其他.md"), sources: sources) }
        try rejects("AI cannot alter IDs") { _ = try CharacterExtractionClient.decode(response.replacingOccurrences(of: "\"field\":\"性格\"", with: "\"field\":\"characterID\""), sources: sources) }
        // An unreadable registry must never be replaced by an empty one.
        try Data("broken".utf8).write(to: root.appendingPathComponent("character-library.json"))
        let broken = CharacterLibraryStore(root: root)
        try check(!broken.canEdit, "corrupt registry protected")
        try rejects("corrupt registry write") { _ = try broken.addProject(name: "新", root: root) }
        print("CharacterLibrarySelfTest passed: identity, search, status, Markdown preservation, backups, conflicts, missing files, registry recovery, mocked AI evidence")
    }
}
