import Foundation

@main struct CharacterWorkflowBridgeSelfTest {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw CharacterLibraryError.invalid("FAIL: " + message) }
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("workflow-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("人物/人物接口.md", """
        # 人物接口
        | 人物 | 性格 |
        |---|---|
        | P-01 许长山 | 谨慎 |
        | P-02 许安宁 | 活泼 |
        | N-07 陶知夏 | 毒舌心善 |
        | P-01 测试组合、P-02 许安宁 | 多人行不自动拆分 |
        N-07 的[关系资料](<陶知微/关系.md>)保留旧名路径。
        ![别人的图](../其他.png)
        """)
        try write("人物/陶知微/关系.md", "# 人物关系\n陶知夏有自己的想法。")
        try write("人物/陶知微/人物资产说明书_陶知微_已确认.md", """
        # 旧路径保持兼容
        | 角色／资产 ID | N-07／N-07-开局 |
        当前名陶知夏。性格毒舌心善，旧图不默认采用。
        """)
        try write("人物/许长山/人物资产说明书_许长山_已确认.md", "# 人物\n| 角色／资产 ID | P-01／P-01-开局 |\n仅为说明，不自动确认。")
        try write("人物/许长山/人物资产说明书_许长山_候选_v999.md", "# 人物候选\n全新造型尚未确认。")
        try write("正文/00_剧集索引.md", "# 当前入口\n[当前](第001集/旧编号_v02.md)\n旧v999保留追溯。")
        try write("正文/第001集/旧编号_v02.md", "# 第1集\n人物P-01许长山。")
        try write("分镜/第001集/分镜.md", "# 分镜\n仅候选，未装配。")
        var profile = CharacterProfile(projectID: "demo", characterID: "P-01")
        profile.fields["姓名"] = .init(text: "许长山", review: .confirmed)
        try write("人物库索引/主角.md", CharacterMarkdown.render(profile, replacing: "# 标准档案\n"))
        var foreign = profile; foreign.projectID = "other"; foreign.characterID = "OTHER"
        try write("人物库索引/外项目.md", CharacterMarkdown.render(foreign, replacing: ""))
        let first = try CharacterProjectScanner.scan(root: root)
        let interface = first.documents.first { $0.kind == "人物总表" }!
        let doc = first.documents.first { $0.name == "陶知微" }!
        let refs = [CharacterProjectModules.Reference(characterID: "N-07", kind: doc.kind, path: doc.path, fingerprint: doc.fingerprint)]
        try CharacterProjectModules.writeIndex(.init(projectID: "demo", references: refs), root: root, expected: nil)
        let inventory = CharacterWorkflowBridge.inventory(documents: first.documents, root: root, projectID: "demo")
        try check(inventory.people.count == 3, "IDs deduplicate standard and interface; foreign project excluded")
        let renamed = inventory.people.first { $0.id == "N-07" }!
        try check(renamed.name == "陶知夏" && renamed.paths.contains(doc.path), "old directory follows explicit stable ID, not name guesses")
        try check(renamed.paths.contains("人物/陶知微/关系.md"), "explicit interface links preserve renamed source navigation")
        try check(inventory.isUnchanged(doc, characterID: "N-07") && !inventory.isUnchanged(doc, characterID: "P-01"), "indexed changes scoped by person")
        let changed = CharacterWorkflowBridge.recommended(renamed, documents: first.documents, inventory: inventory, changedOnly: true)
        try check(changed.contains(interface.path) && !changed.contains(doc.path), "new context remains, unchanged linked source omitted")
        var modified = doc; modified.fingerprint = "new-fingerprint"
        try check(!inventory.isUnchanged(modified, characterID: "N-07"), "changed source eligible for rereading")
        let parent = inventory.people.first { $0.id == "P-01" }!
        try check(!parent.conflict, "multi-person row cannot create a fake name conflict")
        let choices = CharacterWorkflowBridge.recommended(parent, documents: first.documents, inventory: inventory, changedOnly: false)
        try check(!choices.contains(where: { $0.contains("v999") }), "highest candidate version is not selected by default")
        try check(first.documents.contains { $0.kind == "剧集索引" } && first.documents.contains { $0.kind == "剧情正文" } && first.documents.contains { $0.kind == "分镜记录" }, "workflow classes distinct")
        try check(CharacterWorkflowBridge.isStandard(first.documents.first { $0.path == "人物库索引/主角.md" }!), "standard profile bypasses AI")
        var conflicting = interface
        conflicting.text += "\n| P-01 另一个名字 | 冲突 |\n"
        let conflicted = CharacterWorkflowBridge.inventory(documents: [conflicting], root: root, projectID: "demo")
        let conflictPerson = conflicted.people.first { $0.id == "P-01" }!
        try check(conflictPerson.conflict && CharacterWorkflowBridge.recommended(conflictPerson, documents: [conflicting], inventory: conflicted, changedOnly: false).isEmpty, "conflicting names never silently selected")
        let response = """
        {"documents":[{"path":"人物/人物接口.md","name":"许安宁","kind":"人物总表","evidence":"活泼","conflict":"","suggestions":[]}]}
        """
        do {
            _ = try CharacterProjectScanner.decode(response, documents: [interface], targetName: "许长山")
            throw CharacterLibraryError.invalid("FAIL: wrong target accepted")
        } catch CharacterLibraryError.invalid(let text) { try check(text.contains("目标以外"), "wrong AI character rejected") }
        let handoff = CharacterWorkflowBridge.handoff(projectID: "demo", root: root, documents: [doc], characterID: "N-07", name: "陶知夏")
        try check(handoff.contains(doc.fingerprint) && handoff.contains("人物 ID：N-07") && handoff.contains("旧分镜"), "Codex context preserves identity, provenance and downstream boundary")
        print("CharacterWorkflowBridgeSelfTest passed: stable IDs, renamed paths, cross-project exclusion, conflict blocking, indexed changes, standard bypass, workflow classes, target validation, Codex handoff")
        if let realRoot = ProcessInfo.processInfo.environment["ASSETFRAME_WORKFLOW_READONLY_ROOT"] {
            let url = URL(fileURLWithPath: realRoot)
            let scan = try CharacterProjectScanner.scan(root: url)
            let inventory = CharacterWorkflowBridge.inventory(documents: scan.documents, root: url, projectID: "readonly-probe")
            let counts = Dictionary(grouping: scan.documents, by: \.kind).mapValues(\.count)
            print("READONLY \(counts) · people=\(inventory.people.count) · warnings=\(scan.warnings.count + inventory.warnings.count)")
            for warning in scan.warnings + inventory.warnings { print("READONLY WARNING " + warning) }
            for person in inventory.people where ["P-01", "N-07"].contains(person.id) { print("READONLY \(person.id) \(person.name) sources=\(person.paths.count) conflict=\(person.conflict)") }
        }
    }
}
