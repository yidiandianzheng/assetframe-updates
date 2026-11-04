import Foundation
import SQLite3

@main struct ProjectClassificationPersistenceSelfTest {
    static func check(_ value: Bool, _ message: String) { precondition(value, message); print("PASS " + message) }
    static func sql(_ root: URL, _ text: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("global-material-library.sqlite").path, &db) == SQLITE_OK else { throw MaterialDatabase.error("QA SQL open failed") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw MaterialDatabase.error("QA SQL failed") }
    }
    static func profileTable(_ root: URL) -> Bool {
        var db: OpaquePointer?; var statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_open_v2(root.appendingPathComponent("global-material-library.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE name='tagging_project_classifications'", -1, &statement, nil) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_ROW
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: "/tmp/assetframe-qa.pcat-persistence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try JSONDecoder().decode(MaterialTaggingState.self, from: Data(#"{"terms":[],"sources":[],"bindings":[],"proposals":[],"jobs":[]}"#.utf8))
        check(legacy.projectClassifications == nil && legacy.isEmpty, "旧 JSON 缺失分类字段仍可解码")
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        let database = MaterialDatabase(root: a)
        let empty = try await database.load()
        check(!profileTable(a), "打开旧结构不会创建分类配置表")
        var ordinary = empty
        ordinary.tagging = .init(terms: [.init(name: "保留词条")])
        try await database.commit(ordinary, previous: empty)
        check(!profileTable(a), "普通整理保存不创建分类配置表")
        let store = GlobalMaterialStore(rootURL: a, managedRoot: root.appendingPathComponent("Managed"))
        await store.waitUntilReady()
        let profile = ProjectClassificationProfile(id: "same-project", name: "项目甲", roots: [root.path])
        try await store.changeTagging(undoable: true) { state, _ in state.projectClassifications = [profile] }
        check(profileTable(a), "首次采用分类时才创建配置表")
        let adopted = try await database.load()
        check(adopted.tagging?.projectClassifications == [profile], "仅分类配置也真实写入 SQLite")
        check(await store.undoEdit(), "首次采用可以撤销")
        check(store.tagging.projectClassifications == nil && store.tagging.terms.first?.name == "保留词条", "撤销保留原词条并恢复 nil")
        check(await store.undoEdit(redo: true), "采用可以重做")
        try await store.changeTagging(undoable: true) { state, _ in state.projectClassifications?[0].name = "项目改名" }
        try await store.changeTagging(undoable: true) { state, _ in state.projectClassifications = nil }
        check(store.tagging.projectClassifications == nil, "删除分类配置保存")
        check(await store.undoEdit(), "撤销删除")
        check(store.tagging.projectClassifications?.first?.name == "项目改名", "撤销删除恢复改名配置")
        check(await store.undoEdit(), "撤销改名")
        check(store.tagging.projectClassifications?.first?.name == "项目甲", "撤销改名恢复原值")
        check(await store.undoEdit(redo: true), "重做改名")
        let reloaded = try await database.load()
        check(reloaded.tagging?.projectClassifications?.first?.name == "项目改名", "重新读取保持分类状态")
        let backup = root.appendingPathComponent("backup.sqlite")
        try await database.backup(to: backup)
        let databaseB = MaterialDatabase(root: b)
        _ = try await databaseB.load()
        try await databaseB.restore(from: backup)
        let restored = try await databaseB.load()
        check(restored.tagging?.projectClassifications == reloaded.tagging?.projectClassifications, "SQLite 备份恢复包含项目分类")
        var bNew = restored
        bNew.tagging?.projectClassifications?[0].name = "独立乙库"
        try await databaseB.commit(bNew, previous: restored)
        let aStill = try await database.load()
        check(aStill.tagging?.projectClassifications?.first?.name == "项目改名", "相同项目 ID 的两个库保持隔离")
        var bStale = restored
        bStale.tagging?.projectClassifications?[0].name = "过期覆盖"
        do { try await databaseB.commit(bStale, previous: restored); preconditionFailure("stale write must fail") }
        catch { print("PASS 旧基线并发覆盖被拒绝") }
        let afterConflict = try await databaseB.load()
        check(afterConflict.tagging?.projectClassifications?.first?.name == "独立乙库", "并发冲突后原配置不被覆盖")
        let beforeFailure = store.tagging
        try sql(a, "CREATE TRIGGER reject_profile BEFORE UPDATE ON tagging_project_classifications BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        do { try await store.changeTagging(undoable: true) { state, _ in state.projectClassifications?[0].name = "不得保存" }; preconditionFailure("injected failure must fail") }
        catch { print("PASS 注入 SQL 失败整体回滚") }
        check(store.tagging == beforeFailure, "事务失败不发布内存配置")
        let afterFailure = try await database.load()
        check(afterFailure.tagging == beforeFailure, "事务失败不保存配置或撤销历史")
        try sql(a, "DROP TRIGGER reject_profile")
        let json = root.appendingPathComponent("backup.json")
        try JSONEncoder().encode(reloaded).write(to: json)
        try await databaseB.restore(from: json)
        let jsonRestored = try await databaseB.load()
        check(jsonRestored.tagging?.projectClassifications == reloaded.tagging?.projectClassifications, "JSON 快照恢复包含分类配置")
        let first = try await databaseB.load()
        var last = first; last.tagging?.projectClassifications = nil
        try await databaseB.commit(last, previous: first)
        let removed = try await databaseB.load()
        check(removed.tagging?.projectClassifications?.isEmpty != false, "清空后的配置重开为空")
        print("ProjectClassificationPersistenceSelfTest passed")
    }
}
