import Foundation
import SQLite3

struct MaterialSnapshot: Codable, Sendable {
    var materials: [MaterialRecord]
    var links: [ProjectMaterialLink]
    var presets: [MaterialFilterPreset]? = nil
    var organization: LibraryOrganization? = nil
    var editHistory: MaterialUndoPatch.History? = nil
    var tagging: MaterialTaggingState? = nil
}

/// All decoding, migration and transactions run on this serial worker, never on the UI thread.
final class MaterialDatabase: @unchecked Sendable {
    let root: URL
    var url: URL { root.appendingPathComponent("global-material-library.sqlite") }
    private let queue = DispatchQueue(label: "assetframe.material-database", qos: .userInitiated)
    // Accessed only on the database worker.
    private var loadedOnce = false
    #if ASSETFRAME_SELF_TEST
    // Present only in the isolated test executable, never in application builds.
    var transactionCheckpoint: (@Sendable (String) -> Void)?
    #endif
    private func requireMountedVolume() throws {
        let path = root.standardizedFileURL.path
        guard path.hasPrefix("/Volumes/") else { return }
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { throw Self.error("资源库磁盘未连接") }
        let mount = "/Volumes/" + parts[1]
        guard FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil)?.contains(where: { $0.standardizedFileURL.path == mount }) == true else {
            throw Self.error("资源库磁盘未连接；不会创建目录或空库替代")
        }
    }
    init(root: URL) { self.root = root }

    func load() async throws -> MaterialSnapshot {
        try await work {
            try self.requireMountedVolume()
            let fm = FileManager.default
            let legacy = self.root.appendingPathComponent("global-material-library.json")
            let exists = fm.fileExists(atPath: self.url.path)
            guard exists || !self.loadedOnce else { throw Self.error("已打开的资源库数据库缺失；不会创建空库替代") }
            // Decode BEFORE creating SQLite. A bad JSON must never become an empty successful migration.
            let migrated: MaterialSnapshot? = !exists && fm.fileExists(atPath: legacy.path)
                ? try JSONDecoder().decode(MaterialSnapshot.self, from: Data(contentsOf: legacy)) : nil
            if let migrated { try Self.validate(migrated) }
            try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
            if let migrated {
                let backup = self.root.appendingPathComponent("global-material-library.pre-sqlite-backup.json")
                if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: legacy, to: backup) }
                let staging = self.root.appendingPathComponent("migration-\(UUID().uuidString).sqlite")
                defer { try? fm.removeItem(at: staging) }
                try self.connection(at: staging) { db in try self.write(migrated, previous: nil, db: db) }
                try fm.moveItem(at: staging, to: self.url)
            }
            let value = try self.connection(at: self.url, createIfNeeded: !self.loadedOnce) { db in
                let result = MaterialSnapshot(materials: try self.rows("materials", db: db), links: try self.rows("links", db: db), presets: try self.rows("presets", db: db), organization: (try self.rows("organization", db: db) as [LibraryOrganization]).first, editHistory: (try self.rows("history", db: db) as [MaterialUndoPatch.History]).first, tagging: try self.taggingRows(db: db))
                try Self.validate(result)
                return result
            }
            self.loadedOnce = true
            return value
        }
    }

    func commit(_ snapshot: MaterialSnapshot, previous: MaterialSnapshot) async throws {
        try await work {
            try self.requireMountedVolume()
            try Self.validate(snapshot)
            try self.connection(at: self.url, createIfNeeded: false) { db in try self.write(snapshot, previous: previous, db: db) }
        }
    }

    func backup(to destination: URL) async throws {
        try await work {
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw Self.error("备份目标已存在") }
            // Connections are closed between transactions; DELETE journal leaves a self-contained file.
            try FileManager.default.copyItem(at: self.url, to: destination)
        }
    }

    func restore(from source: URL) async throws {
        try await work {
            try self.requireMountedVolume()
            let fm = FileManager.default
            let staging = self.root.appendingPathComponent("restore-\(UUID().uuidString).sqlite")
            try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            if source.pathExtension.lowercased() == "json" {
                let snapshot = try JSONDecoder().decode(MaterialSnapshot.self, from: Data(contentsOf: source))
                try Self.validate(snapshot)
                try self.connection(at: staging) { db in try self.write(snapshot, previous: nil, db: db) }
            } else {
                try fm.copyItem(at: source, to: staging)
                try self.connection(at: staging) { db in
                    let snapshot = MaterialSnapshot(materials: try self.rows("materials", db: db), links: try self.rows("links", db: db), presets: try self.rows("presets", db: db), organization: (try self.rows("organization", db: db) as [LibraryOrganization]).first, editHistory: (try self.rows("history", db: db) as [MaterialUndoPatch.History]).first, tagging: try self.taggingRows(db: db))
                    try Self.validate(snapshot)
                }
            }
            if fm.fileExists(atPath: self.url.path) {
                try fm.copyItem(at: self.url, to: self.root.appendingPathComponent("before-restore-\(UUID().uuidString).sqlite"))
                _ = try fm.replaceItemAt(self.url, withItemAt: staging)
            } else { try fm.moveItem(at: staging, to: self.url) }
        }
    }

    private static func validate(_ snapshot: MaterialSnapshot) throws {
        guard Set(snapshot.materials.map(\.id)).count == snapshot.materials.count,
              Set(snapshot.links.map(\.id)).count == snapshot.links.count else { throw error("素材库含重复标识，请先恢复备份") }
        if let history = snapshot.editHistory {
            guard history.id == "history", history.version == 1, history.undo.count <= 20, history.redo.count <= 20,
                  (history.undo + history.redo).reduce(0, { $0 + $1.estimatedBytes }) <= 20 * 1024 * 1024 else { throw error("整理历史格式或大小不合法") }
        }
        if let value = snapshot.tagging {
            for ids in [value.terms.map(\.id), value.sources.map(\.id), value.bindings.map(\.id), value.proposals.map(\.id), value.jobs.map(\.id)] {
                guard Set(ids).count == ids.count else { throw error("标签整理记录含重复标识") }
            }
            guard value.terms.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  value.proposals.allSatisfy({ ["待确认", "已确认", "已忽略", "已过期", "处理失败"].contains($0.status) }) else { throw error("标签整理记录格式不合法") }
        }
        let ids = Set(snapshot.materials.map(\.id))
        guard snapshot.links.allSatisfy({ ids.contains($0.materialID) }) else { throw error("素材库存在失效版本引用") }
    }

    private func connection<T>(at url: URL, createIfNeeded: Bool = true, _ body: (OpaquePointer) throws -> T) throws -> T {
        let existed = FileManager.default.fileExists(atPath: url.path)
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (createIfNeeded ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(url.path, &pointer, flags, nil) == SQLITE_OK, let db = pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw Self.error("无法打开素材数据库")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        if existed {
            var check: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('materials','links','presets')", -1, &check, nil) == SQLITE_OK else { throw Self.error("数据库损坏") }
            defer { sqlite3_finalize(check) }
            guard sqlite3_step(check) == SQLITE_ROW, sqlite3_column_int(check, 0) == 3 else { throw Self.error("不是有效的 AssetFrame 素材库") }
        }
        try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;", db: db)
        for table in ["materials", "links", "presets", "organization", "history", "tagging_terms", "tagging_sources", "tagging_bindings", "tagging_proposals", "tagging_jobs"] {
            try execute("CREATE TABLE IF NOT EXISTS \(table)(id TEXT PRIMARY KEY, payload BLOB NOT NULL)", db: db)
        }
        return try body(db)
    }

    private func taggingRows(db: OpaquePointer) throws -> MaterialTaggingState? {
        let value = MaterialTaggingState(terms: try rows("tagging_terms", db: db), sources: try rows("tagging_sources", db: db),
            bindings: try rows("tagging_bindings", db: db), proposals: try rows("tagging_proposals", db: db), jobs: try rows("tagging_jobs", db: db))
        return value.isEmpty ? nil : value
    }

    private func rows<T: Decodable>(_ table: String, db: OpaquePointer) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM \(table) ORDER BY rowid", -1, &statement, nil) == SQLITE_OK else { throw Self.error(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw Self.error("素材记录为空") }
            result.append(try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw Self.error(String(cString: sqlite3_errmsg(db))) }
        return result
    }

    private func write(_ snapshot: MaterialSnapshot, previous: MaterialSnapshot?, db: OpaquePointer) throws {
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            try sync(snapshot.materials, old: previous?.materials ?? [], table: "materials", db: db)
            #if ASSETFRAME_SELF_TEST
            transactionCheckpoint?("materials-written")
            #endif
            try sync(snapshot.links, old: previous?.links ?? [], table: "links", db: db)
            try sync(snapshot.presets ?? [], old: previous?.presets ?? [], table: "presets", db: db)
            try sync(snapshot.organization.map { [$0] } ?? [], old: previous?.organization.map { [$0] } ?? [], table: "organization", db: db)
            try sync(snapshot.editHistory.map { [$0] } ?? [], old: previous?.editHistory.map { [$0] } ?? [], table: "history", db: db)
            let nextTags = snapshot.tagging ?? MaterialTaggingState(), oldTags = previous?.tagging ?? MaterialTaggingState()
            try sync(nextTags.terms, old: oldTags.terms, table: "tagging_terms", db: db)
            try sync(nextTags.sources, old: oldTags.sources, table: "tagging_sources", db: db)
            try sync(nextTags.bindings, old: oldTags.bindings, table: "tagging_bindings", db: db)
            try sync(nextTags.proposals, old: oldTags.proposals, table: "tagging_proposals", db: db)
            try sync(nextTags.jobs, old: oldTags.jobs, table: "tagging_jobs", db: db)
            try execute("COMMIT", db: db)
            #if ASSETFRAME_SELF_TEST
            transactionCheckpoint?("committed")
            #endif
        } catch { try? execute("ROLLBACK", db: db); throw error }
    }

    private func row<T: Decodable>(_ table: String, id: String, db: OpaquePointer) throws -> T? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM \(table) WHERE id=?", -1, &statement, nil) == SQLITE_OK else { throw Self.error("无法核验原记录") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw Self.error("原记录不可读取") }
        return try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }

    private func sync<T: Codable & Hashable & Identifiable>(_ records: [T], old: [T], table: String, db: OpaquePointer) throws where T.ID == String {
        let existing = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let ids = Set(records.map(\.id))
        let desired = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for record in old where desired[record.id] != record {
            let persisted: T? = try row(table, id: record.id, db: db)
            guard persisted == record else { throw Self.error("资料已被其他操作更改，整批提交已取消；重新加载后重试") }
        }
        for record in records where existing[record.id] == nil {
            let persisted: T? = try row(table, id: record.id, db: db)
            guard persisted == nil else { throw Self.error("资料编号已存在，整批提交已取消") }
        }
        for record in old where !ids.contains(record.id) { try bind("DELETE FROM \(table) WHERE id=?", id: record.id, data: nil, db: db) }
        for record in records where existing[record.id] != record {
            try bind("INSERT INTO \(table)(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", id: record.id, data: JSONEncoder().encode(record), db: db)
        }
    }

    private func bind(_ sql: String, id: String, data: Data?, db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.error(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id, -1, transient)
        if let data { _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) } }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.error(String(cString: sqlite3_errmsg(db))) }
    }
    private func execute(_ sql: String, db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Self.error(String(cString: sqlite3_errmsg(db))) }
    }
    static func error(_ message: String) -> NSError { NSError(domain: "AssetFrame.Materials", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func work<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in queue.async { continuation.resume(with: Result { try body() }) } }
    }
}
