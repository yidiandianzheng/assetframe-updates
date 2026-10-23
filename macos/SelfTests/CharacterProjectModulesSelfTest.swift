import Foundation

@main struct CharacterProjectModulesSelfTest {
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw CharacterLibraryError.invalid("FAIL: " + message) } }
    static func rejects(_ message: String, _ block: () throws -> Void) throws {
        do { try block() } catch { return }; throw CharacterLibraryError.invalid("FAIL expected rejection: " + message)
    }
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("character-project-\(UUID())")
        try fm.createDirectory(at: root.appendingPathComponent("人物/许长山"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let asset = root.appendingPathComponent("当前 图.png")
        try Data("asset-original-bytes".utf8).write(to: asset)
        let source = root.appendingPathComponent("人物/许长山/人物资产说明书_许长山_已确认.md")
        let old = "# 人物资产说明书｜许长山\n\n旧版已确认，但现已停用。新稿尚未确认。\n![当前图](<../../当前 图.png>)\n![旧图](../../旧图.png)\n## 性格\n毒舌，话短。\n"
        try Data(old.utf8).write(to: source)
        let history = root.appendingPathComponent("历史确认_停用")
        try fm.createDirectory(at: history, withIntermediateDirectories: true)
        try Data(old.utf8).write(to: history.appendingPathComponent("人物资产说明书_旧版.md"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("外链"), withDestinationURL: history)
        let scan = try CharacterProjectScanner.scan(root: root)
        try check(scan.documents.count == 1, "history and symlink directories skipped")
        let doc = scan.documents[0]
        try check(doc.name == "许长山" && doc.kind == "资产说明" && doc.warning.contains("不能证明"), "filename remains a hint, negative text is not confirmation")
        let links = CharacterProjectScanner.assetLinks(doc, root: root)
        try check(links.count == 2 && links[0].path == asset.path && links[0].evidence.contains("当前图"), "relative media links resolve from document, evidence preserved")
        try CharacterProjectScanner.verifyUnchanged([doc], root: root)
        try Data((old + "外部编辑").utf8).write(to: source)
        try rejects("source drift") { try CharacterProjectScanner.verifyUnchanged([doc], root: root) }
        try Data(old.utf8).write(to: source)
        let response = """
        {"documents":[{"path":"人物/许长山/人物资产说明书_许长山_已确认.md","name":"许长山","kind":"资产说明","evidence":"毒舌，话短。","conflict":"旧版停用与新稿未确认","suggestions":[{"field":"性格","value":"毒舌","source":"人物/许长山/人物资产说明书_许长山_已确认.md","evidence":"毒舌","conflict":""}]}]}
        """
        let parsed = try CharacterProjectScanner.decode(response, documents: [doc])
        try check(parsed.count == 1 && parsed[0].suggestions[0].value == "毒舌", "mock AI evidence accepted")
        try rejects("invented evidence") { _ = try CharacterProjectScanner.decode(response.replacingOccurrences(of: "\"evidence\":\"毒舌\"", with: "\"evidence\":\"帝王\""), documents: [doc]) }
        try rejects("invented confirmation") { _ = try CharacterProjectScanner.decode(response.replacingOccurrences(of: "\"kind\":\"资产说明\"", with: "\"kind\":\"确认记录\""), documents: [doc]) }
        try rejects("foreign input") { _ = try CharacterProjectScanner.decode(response, documents: []) }
        let profilePath = root.appendingPathComponent("人物/许长山/人设.md")
        let profile = CharacterProfile(projectID: "project-a", characterID: "P-01")
        try Data(CharacterMarkdown.render(profile, replacing: "").utf8).write(to: profilePath)
        let receipt = CharacterProjectModules.Receipt(projectID: "project-a", characterID: "P-01", assetPath: "当前 图.png", sha256: try CharacterProjectModules.fileHash(asset), materialID: "asset-id", variant: "开局", role: "主图", stage: "开局", confirmationEvidence: "用户已查看此图并确认", platform: "Codex", model: "", originalPrompt: "原始提示词\n保留完整内容与参数 --ar 9:16", normalizedPrompt: ["固定特征":"清瘦猎户", "禁改项":"身份不变"], profilePath: "人物/许长山/人设.md", sourcePaths: [doc.path])
        let receiptFile = try CharacterProjectModules.saveReceipt(receipt, root: root)
        let duplicate = try CharacterProjectModules.saveReceipt(receipt, root: root)
        try check(receiptFile == duplicate, "same receipt is idempotent")
        let decoded = try CharacterProjectModules.decode(CharacterProjectModules.Receipt.self, text: CharacterMarkdown.read(receiptFile).0, marker: "assetframe-confirmation")
        try check(decoded == receipt, "exact generation prompt and normalized template both retained")
        try CharacterProjectModules.verify(decoded, root: root, projectID: "project-a")
        try rejects("cross-project receipt") { try CharacterProjectModules.verify(decoded, root: root, projectID: "project-b") }
        try Data("changed asset".utf8).write(to: asset)
        try rejects("changed asset cannot keep confirmation") { try CharacterProjectModules.verify(decoded, root: root, projectID: "project-a") }
        var modified = receipt; modified.originalPrompt = "new"
        try rejects("receipt immutable") { _ = try CharacterProjectModules.saveReceipt(modified, root: root) }
        let snapshot = try CharacterProjectModules.readIndex(root: root, projectID: "project-a")
        let ref = CharacterProjectModules.Reference(characterID: "P-01", kind: "确认记录", path: CharacterProjectModules.relative(receiptFile, root: root), fingerprint: try CharacterMarkdown.read(receiptFile).1)
        let index = CharacterProjectModules.upsert([ref, ref], into: snapshot.0)
        try check(index.references.count == 1, "modular refs deduplicated")
        try CharacterProjectModules.writeIndex(index, root: root, expected: snapshot.1)
        let stored = try CharacterProjectModules.readIndex(root: root, projectID: "project-a")
        try check(stored.0 == index, "portable index round trip")
        try rejects("foreign project index") { _ = try CharacterProjectModules.readIndex(root: root, projectID: "project-b") }
        let indexURL = CharacterProjectModules.indexURL(root: root)
        let oldIndex = try Data(contentsOf: indexURL)
        try Data((String(decoding: oldIndex, as: UTF8.self) + "external").utf8).write(to: indexURL)
        try rejects("index concurrent change") { try CharacterProjectModules.writeIndex(index, root: root, expected: stored.1) }
        try Data(oldIndex).write(to: indexURL)
        try CharacterProjectModules.writeIndex(index, root: root, expected: stored.1)
        let backups = try fm.contentsOfDirectory(at: indexURL.deletingLastPathComponent().appendingPathComponent(".assetframe-character-backups"), includingPropertiesForKeys: nil)
        try check(backups.count == 1 && (try Data(contentsOf: backups[0])) == oldIndex, "index exact-byte backup")
        let noteText = try String(contentsOf: indexURL, encoding: .utf8) + "\n人工备注：保留本段。\n"
        try Data(noteText.utf8).write(to: indexURL)
        let withNote = try CharacterProjectModules.readIndex(root: root, projectID: "project-a")
        try CharacterProjectModules.writeIndex(index, root: root, expected: withNote.1)
        try check(try String(contentsOf: indexURL, encoding: .utf8).hasSuffix("人工备注：保留本段。\n"), "index preserves unowned notes")
        var wrongPerson = receipt; wrongPerson.characterID = "P-02"
        try rejects("receipt must match source persona identity") { try CharacterProjectModules.verify(wrongPerson, root: root, projectID: "project-a") }
        try Data("corrupted".utf8).write(to: indexURL)
        try rejects("corrupt index not overwritten") { _ = try CharacterProjectModules.readIndex(root: root, projectID: "project-a") }
        try check(try String(contentsOf: source, encoding: .utf8) == old, "source persona docs unmodified")
        print("CharacterProjectModulesSelfTest passed: bounded discovery, historical exclusion, link resolution, source drift, mock AI evidence, immutable confirmation, file hash, cross-project isolation, index deduplication/backup/conflicts")
    }
}
