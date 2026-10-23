import Foundation
import SQLite3

struct ProjectSnapshot: Sendable {
    var library: LibraryData
    var exportNames: [String: String]
    var localFolders: [LocalFolderSource] = []
}

enum ProjectDatabaseError: Error, LocalizedError {
    case open(String)
    case execute(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): "无法打开项目数据库：\(message)"
        case .execute(let message): "项目数据库操作失败：\(message)"
        }
    }
}

final class ProjectDatabase: @unchecked Sendable {
    let url: URL

    private let queue: DispatchQueue
    private var database: OpaquePointer?

    init(url: URL) {
        self.url = url
        self.queue = DispatchQueue(label: "com.yidiandian.assetframe.database.\(url.deletingPathExtension().lastPathComponent)")
    }

    deinit {
        // Every queued operation retains this instance through its work closure.
        // At final release no operation can still access the connection. Release
        // may occur on the database queue itself, so dispatching sync would trap.
        if let database { sqlite3_close(database) }
    }

    func isEmpty() async throws -> Bool {
        try await perform {
            try self.openIfNeeded()
            return try self.scalarInt("SELECT COUNT(*) FROM assets") == 0
        }
    }

    func load(progress: (@Sendable (ProjectDatabaseLoadProgress) -> Void)? = nil) async throws -> ProjectSnapshot {
        try await perform {
            try self.openIfNeeded()
            var assets: [AssetItem] = []
            var groups: [AssetGroup] = []
            var relations: [AssetRelation] = []
            var exportNames: [String: String] = [:]
            var assetStacks: [AssetStack] = []
            var scriptExtractions: [ScriptExtractionRecord] = []
            var generationBatches: [GenerationBatchRecord] = []
            var localFolders: [LocalFolderSource] = []

            let countedTables = [
                "assets", "groups", "relations", "export_items", "asset_stacks",
                "script_extractions", "generation_batches", "local_folder_sources"
            ]
            let total = try countedTables.reduce(into: 0) { count, table in
                count += try self.scalarInt("SELECT COUNT(*) FROM \(table)")
            }
            var completed = 0
            progress?(ProjectDatabaseLoadProgress(completed: 0, total: total))
            func reportProgress(force: Bool = false) {
                completed += 1
                if force || completed == total || completed.isMultiple(of: 64) {
                    progress?(ProjectDatabaseLoadProgress(completed: completed, total: total))
                }
            }

            try self.query("SELECT payload FROM assets ORDER BY created_at, id") { statement in
                defer { reportProgress() }
                guard let text = sqlite3_column_text(statement, 0) else { return }
                let data = Data(String(cString: text).utf8)
                if let asset = try? ProjectDatabase.decoder.decode(AssetItem.self, from: data) { assets.append(asset) }
            }
            try self.query("SELECT payload FROM groups ORDER BY id") { statement in
                defer { reportProgress() }
                guard let text = sqlite3_column_text(statement, 0) else { return }
                let data = Data(String(cString: text).utf8)
                if let group = try? ProjectDatabase.decoder.decode(AssetGroup.self, from: data) { groups.append(group) }
            }
            try self.query("SELECT group_id, asset_id FROM relations") { statement in
                defer { reportProgress() }
                guard let group = sqlite3_column_text(statement, 0), let asset = sqlite3_column_text(statement, 1) else { return }
                relations.append(AssetRelation(groupId: String(cString: group), assetId: String(cString: asset)))
            }
            try self.query("SELECT asset_id, export_name FROM export_items ORDER BY added_at") { statement in
                defer { reportProgress() }
                guard let id = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) else { return }
                exportNames[String(cString: id)] = String(cString: name)
            }
            try self.query("SELECT payload FROM asset_stacks ORDER BY id") { statement in
                defer { reportProgress() }
                guard let text = sqlite3_column_text(statement, 0) else { return }
                let data = Data(String(cString: text).utf8)
                if let stack = try? ProjectDatabase.decoder.decode(AssetStack.self, from: data) { assetStacks.append(stack) }
            }
            try self.query("SELECT payload FROM script_extractions ORDER BY id") { statement in
                defer { reportProgress() }
                guard let text = sqlite3_column_text(statement, 0) else { return }
                let data = Data(String(cString: text).utf8)
                if let extraction = try? ProjectDatabase.decoder.decode(ScriptExtractionRecord.self, from: data) { scriptExtractions.append(extraction) }
            }
            try self.query("SELECT payload FROM generation_batches ORDER BY created_at, id") { statement in
                defer { reportProgress() }
                guard let text = sqlite3_column_text(statement, 0) else { return }
                let data = Data(String(cString: text).utf8)
                if let batch = try? ProjectDatabase.decoder.decode(GenerationBatchRecord.self, from: data) { generationBatches.append(batch) }
            }
            try self.query("SELECT payload FROM local_folder_sources ORDER BY created_at, id") { statement in
                defer { reportProgress() }
                guard let text = sqlite3_column_text(statement, 0) else { return }
                let data = Data(String(cString: text).utf8)
                if let folder = try? ProjectDatabase.decoder.decode(LocalFolderSource.self, from: data) {
                    localFolders.append(folder)
                }
            }
            if completed < total {
                progress?(ProjectDatabaseLoadProgress(completed: completed, total: total))
            }
            return ProjectSnapshot(
                library: LibraryData(
                    assets: assets, groups: groups, relations: relations,
                    assetStacks: assetStacks.isEmpty ? nil : assetStacks,
                    scriptExtractions: scriptExtractions.isEmpty ? nil : scriptExtractions,
                    generationBatches: generationBatches.isEmpty ? nil : generationBatches
                ),
                exportNames: exportNames,
                localFolders: localFolders
            )
        }
    }

    func replace(with snapshot: ProjectSnapshot) async throws {
        try await perform {
            try self.openIfNeeded()
            try self.execute("BEGIN IMMEDIATE")
            do {
                try self.execute("DELETE FROM assets")
                try self.execute("DELETE FROM groups")
                try self.execute("DELETE FROM relations")
                try self.execute("DELETE FROM export_items")
                try self.execute("DELETE FROM asset_stacks")
                try self.execute("DELETE FROM script_extractions")
                try self.execute("DELETE FROM generation_batches")
                try self.execute("DELETE FROM local_folder_sources")

                for asset in snapshot.library.assets { try self.insert(asset: asset) }
                for group in snapshot.library.groups { try self.insert(group: group) }
                for relation in snapshot.library.relations { try self.insert(relation: relation) }
                for (assetID, exportName) in snapshot.exportNames { try self.insertExport(assetID: assetID, exportName: exportName) }
                for stack in snapshot.library.assetStacks ?? [] { try self.insert(stack: stack) }
                for extraction in snapshot.library.scriptExtractions ?? [] { try self.insert(extraction: extraction) }
                for batch in snapshot.library.generationBatches ?? [] { try self.insert(batch: batch) }
                for folder in snapshot.localFolders { try self.insert(folder: folder) }
                try self.execute("COMMIT")
            } catch {
                try? self.execute("ROLLBACK")
                throw error
            }
        }
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func openIfNeeded() throws {
        guard database == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            if let pointer { sqlite3_close(pointer) }
            throw ProjectDatabaseError.open(message)
        }
        database = pointer
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("""
        CREATE TABLE IF NOT EXISTS assets (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            decision TEXT NOT NULL,
            category TEXT NOT NULL,
            deleted_at REAL,
            source_missing INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            payload TEXT NOT NULL
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS assets_type_idx ON assets(type)")
        try execute("CREATE INDEX IF NOT EXISTS assets_decision_idx ON assets(decision)")
        try execute("CREATE INDEX IF NOT EXISTS assets_category_idx ON assets(category)")
        try execute("CREATE INDEX IF NOT EXISTS assets_deleted_idx ON assets(deleted_at)")
        try execute("""
        CREATE TABLE IF NOT EXISTS groups (
            id TEXT PRIMARY KEY,
            payload TEXT NOT NULL
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS relations (
            group_id TEXT NOT NULL,
            asset_id TEXT NOT NULL,
            PRIMARY KEY(group_id, asset_id)
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS export_items (
            asset_id TEXT PRIMARY KEY,
            export_name TEXT NOT NULL,
            added_at REAL NOT NULL
        )
        """)
        try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS asset_stacks (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS script_extractions (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS generation_batches (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, created_at REAL NOT NULL, payload TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS local_folder_sources (id TEXT PRIMARY KEY, created_at REAL NOT NULL, payload TEXT NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS generation_batches_project_idx ON generation_batches(project_id)")
        try execute("INSERT OR REPLACE INTO metadata(key, value) VALUES('schema_version', '4')")
    }

    private func insert(asset: AssetItem) throws {
        let payload = String(decoding: try ProjectDatabase.encoder.encode(asset), as: UTF8.self)
        let sql = "INSERT INTO assets(id,type,decision,category,deleted_at,source_missing,created_at,payload) VALUES(?,?,?,?,?,?,?,?)"
        try withStatement(sql) { statement in
            bind(asset.id, at: 1, in: statement)
            bind(asset.type.rawValue, at: 2, in: statement)
            bind(asset.decision.rawValue, at: 3, in: statement)
            bind(asset.category.rawValue, at: 4, in: statement)
            if let deletedAt = asset.deletedAt { sqlite3_bind_double(statement, 5, deletedAt.timeIntervalSince1970) }
            else { sqlite3_bind_null(statement, 5) }
            sqlite3_bind_int(statement, 6, asset.sourceMissing ? 1 : 0)
            sqlite3_bind_double(statement, 7, asset.createdAt.timeIntervalSince1970)
            bind(payload, at: 8, in: statement)
            try step(statement)
        }
    }

    private func insert(group: AssetGroup) throws {
        let payload = String(decoding: try ProjectDatabase.encoder.encode(group), as: UTF8.self)
        try withStatement("INSERT INTO groups(id,payload) VALUES(?,?)") { statement in
            bind(group.id, at: 1, in: statement); bind(payload, at: 2, in: statement); try step(statement)
        }
    }

    private func insert(relation: AssetRelation) throws {
        try withStatement("INSERT OR IGNORE INTO relations(group_id,asset_id) VALUES(?,?)") { statement in
            bind(relation.groupId, at: 1, in: statement); bind(relation.assetId, at: 2, in: statement); try step(statement)
        }
    }

    private func insertExport(assetID: String, exportName: String) throws {
        try withStatement("INSERT OR REPLACE INTO export_items(asset_id,export_name,added_at) VALUES(?,?,?)") { statement in
            bind(assetID, at: 1, in: statement); bind(exportName, at: 2, in: statement)
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970); try step(statement)
        }
    }

    private func insert(stack: AssetStack) throws {
        let payload = String(decoding: try ProjectDatabase.encoder.encode(stack), as: UTF8.self)
        try withStatement("INSERT INTO asset_stacks(id,payload) VALUES(?,?)") { statement in
            bind(stack.id, at: 1, in: statement); bind(payload, at: 2, in: statement); try step(statement)
        }
    }

    private func insert(extraction: ScriptExtractionRecord) throws {
        let payload = String(decoding: try ProjectDatabase.encoder.encode(extraction), as: UTF8.self)
        try withStatement("INSERT INTO script_extractions(id,payload) VALUES(?,?)") { statement in
            bind(extraction.id, at: 1, in: statement); bind(payload, at: 2, in: statement); try step(statement)
        }
    }

    private func insert(batch: GenerationBatchRecord) throws {
        let payload = String(decoding: try ProjectDatabase.encoder.encode(batch), as: UTF8.self)
        try withStatement("INSERT INTO generation_batches(id,project_id,created_at,payload) VALUES(?,?,?,?)") { statement in
            bind(batch.id, at: 1, in: statement)
            bind(batch.projectID, at: 2, in: statement)
            sqlite3_bind_double(statement, 3, batch.createdAt.timeIntervalSince1970)
            bind(payload, at: 4, in: statement)
            try step(statement)
        }
    }

    private func insert(folder: LocalFolderSource) throws {
        let payload = String(decoding: try ProjectDatabase.encoder.encode(folder), as: UTF8.self)
        try withStatement("INSERT INTO local_folder_sources(id,created_at,payload) VALUES(?,?,?)") { statement in
            bind(folder.id, at: 1, in: statement)
            sqlite3_bind_double(statement, 2, folder.createdAt.timeIntervalSince1970)
            bind(payload, at: 3, in: statement)
            try step(statement)
        }
    }

    private func query(_ sql: String, row: (OpaquePointer) throws -> Void) throws {
        try withStatement(sql) { statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_ROW { try row(statement) }
                else if result == SQLITE_DONE { break }
                else { throw ProjectDatabaseError.execute(errorMessage) }
            }
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var value = 0
        try query(sql) { statement in value = Int(sqlite3_column_int64(statement, 0)) }
        return value
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw ProjectDatabaseError.open("数据库尚未打开") }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw ProjectDatabaseError.execute(message)
        }
    }

    private func withStatement(_ sql: String, body: (OpaquePointer) throws -> Void) throws {
        guard let database else { throw ProjectDatabaseError.open("数据库尚未打开") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ProjectDatabaseError.execute(errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        try body(statement)
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ProjectDatabaseError.execute(errorMessage) }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private var errorMessage: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder
    }
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
