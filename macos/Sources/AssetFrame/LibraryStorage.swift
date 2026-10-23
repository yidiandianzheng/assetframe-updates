import Foundation
import SQLite3
import Darwin
import CryptoKit
import UniformTypeIdentifiers

struct LibraryDescriptor: Codable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var formatVersion: Int = 1
    static let filename = "assetframe-library.json"
    static func read(_ root: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: root.appendingPathComponent(filename)))
        guard value.formatVersion == 1, UUID(uuidString: value.id) != nil, !value.name.isEmpty else {
            throw MaterialDatabase.error("不支持的资源库格式或版本")
        }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("global-material-library.sqlite").path) else {
            throw MaterialDatabase.error("资源库数据库缺失；不会创建空库替代")
        }
        return value
    }
    func write(_ root: URL) throws { try JSONEncoder().encode(self).write(to: root.appendingPathComponent(Self.filename), options: .atomic) }
}

struct LibraryLocation: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var path: String
}
struct LibraryRegistry: Codable, Sendable {
    var locations: [LibraryLocation] = []
    var currentID: String?
    static func read(_ root: URL) throws -> Self {
        let url = root.appendingPathComponent("libraries.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    func save(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: root.appendingPathComponent("libraries.json"), options: .atomic)
    }
    mutating func record(_ descriptor: LibraryDescriptor, root: URL) {
        locations.removeAll { $0.id == descriptor.id }
        locations.insert(LibraryLocation(id: descriptor.id, name: descriptor.name, path: root.path), at: 0)
        currentID = descriptor.id
    }

    mutating func remove(_ id: String) {
        locations.removeAll { $0.id == id }
        if currentID == id { currentID = locations.first?.id }
    }
}

/// flock is process-owned and released on crash. Do not delete the lock inode.
final class LibraryWriteLease: @unchecked Sendable {
    private let fd: Int32
    init(_ root: URL) throws {
        let opened = Darwin.open(root.appendingPathComponent(".writer.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard opened >= 0 else { throw MaterialDatabase.error("资源库离线或没有写入权限") }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else { close(opened); throw MaterialDatabase.error("资源库已被其他会话占用") }
        fd = opened
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}

struct LibraryMergeReport: Sendable {
    var snapshot: MaterialSnapshot
    var added = 0
    var reused = 0
    var conflicts = 0
    var groups = 0
}

enum LibraryTransfer {
    private final class MetadataRead: @unchecked Sendable {
        let lock = NSLock()
        let finished = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
    }

    /// A removable disk or File Provider can stall even opening a small JSON file.
    /// Never activate a partially migrated library when that happens.
    static func readLegacyMetadata(_ file: URL, project: ProjectRecord? = nil,
                                   timeout: TimeInterval = 15,
                                   reader: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) throws -> Data {
        let state = MetadataRead()
        DispatchQueue.global(qos: .userInitiated).async {
            var scopedRoot: URL?
            if let bookmark = project?.bookmarkData {
                var stale = false
                scopedRoot = try? URL(resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                    bookmarkDataIsStale: &stale)
            }
            let accessed = scopedRoot?.startAccessingSecurityScopedResource() ?? false
            defer { if accessed { scopedRoot?.stopAccessingSecurityScopedResource() } }
            let result = Result { try reader(file) }
            state.lock.lock(); state.result = result; state.lock.unlock()
            state.finished.signal()
        }
        guard state.finished.wait(timeout: .now() + timeout) == .success else {
            throw MaterialDatabase.error("读取旧素材清单超时，迁移尚未启用；请确认磁盘连接和目录访问后重试：\(file.path)")
        }
        state.lock.lock(); let result = state.result!; state.lock.unlock()
        return try result.get()
    }
    static func stableID(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func merge(source: MaterialSnapshot, sourceID: String, into target: MaterialSnapshot) throws -> LibraryMergeReport {
        var report = LibraryMergeReport(snapshot: target)
        var org = target.organization ?? LibraryOrganization()
        let sourceOrg = source.organization ?? LibraryOrganization()
        var materialMap: [String: String] = [:]
        var projectMap: [String: String] = [:]
        var newlyAdded: Set<String> = []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var paths = Dictionary(grouping: target.materials, by: { $0.sourcePath ?? $0.sourceURL ?? $0.id })
        for item in source.materials {
            let key = "merge:\(sourceID):\(item.id)"
            let sourcePayload = try encoder.encode(item)
            let signatureKey = "signature:" + key
            let revisionKey = key + ":" + stableID(sourcePayload.base64EncodedString())
            if let existing = org.legacyMapping[revisionKey] {
                materialMap[item.id] = existing; org.legacyMapping[key] = existing
                org.legacyPayloads[signatureKey] = sourcePayload; report.reused += 1; continue
            }
            if let existing = org.legacyMapping[key], org.legacyPayloads[signatureKey] == sourcePayload {
                materialMap[item.id] = existing; report.reused += 1; continue
            }
            let candidates = paths[item.sourcePath ?? item.sourceURL ?? item.id] ?? []
            let match = candidates.first { other in
                var a = item, b = other
                a.id = ""; b.id = ""; a.createdAt = .distantPast; b.createdAt = .distantPast
                return a == b
            }
            if let match { materialMap[item.id] = match.id; org.legacyMapping[key] = match.id; report.reused += 1 }
            else {
                var value = item; value.id = stableID(revisionKey)
                if !candidates.isEmpty { value.migrationConflict = "来自 \(sourceID) 的同来源记录，人工字段或版本不同，已保留"; report.conflicts += 1 }
                report.snapshot.materials.append(value); newlyAdded.insert(value.id)
                materialMap[item.id] = value.id; org.legacyMapping[key] = value.id; report.added += 1
                paths[item.sourcePath ?? item.sourceURL ?? item.id, default: []].append(value)
            }
            org.legacyMapping[revisionKey] = materialMap[item.id]
            org.legacyPayloads[signatureKey] = sourcePayload
        }
        for project in sourceOrg.projects {
            var p = project; p.id = stableID("project:\(sourceID):\(project.id)")
            projectMap[project.id] = p.id
            if !org.projects.contains(where: { $0.id == p.id }) { org.projects.append(p); report.groups += 1 }
        }
        for link in source.links {
            var l = link; l.id = stableID("link:\(sourceID):\(link.id)")
            l.materialID = materialMap[link.materialID] ?? link.materialID
            if let previous = report.snapshot.links.first(where: { $0.id == l.id }), previous.materialID != l.materialID {
                l.id = stableID("link-revision:\(sourceID):\(link.id):\(l.materialID)")
                l.selection = "候选"; l.use = .candidate
            }
            l.projectID = projectMap[link.projectID] ?? stableID("project:\(sourceID):\(link.projectID)")
            if !org.projects.contains(where: { $0.id == l.projectID }) {
                org.projects.append(ProjectRecord(id: l.projectID, name: "项目 \(link.projectID)", rootPath: "", databasePath: "", isLegacy: true, lastOpenedAt: .now))
            }
            if !report.snapshot.links.contains(where: { $0.id == l.id }) { report.snapshot.links.append(l) }
        }
        for index in report.snapshot.materials.indices where newlyAdded.contains(report.snapshot.materials[index].id) {
            if var p = report.snapshot.materials[index].production {
                p.inputMaterialIDs = p.inputMaterialIDs.map { materialMap[$0] ?? $0 }
                p.versionGroupID = p.versionGroupID.map { materialMap[$0] ?? stableID("version:\(sourceID):\($0)") }
                if var provenance = p.provenance {
                    provenance.parentAssetID = provenance.parentAssetID.flatMap { materialMap[$0] }
                    provenance.batchID = stableID("batch:\(sourceID):\(provenance.batchID)")
                    provenance.parentBatchID = provenance.parentBatchID.map { stableID("batch:\(sourceID):\($0)") }
                    p.provenance = provenance
                }
                report.snapshot.materials[index].production = p
            }
            if let id = report.snapshot.materials[index].duplicateContentOf { report.snapshot.materials[index].duplicateContentOf = materialMap[id] }
        }
        for folder in sourceOrg.folders {
            var f = folder; f.id = stableID("folder:\(sourceID):\(folder.id)")
            if !org.folders.contains(where: { $0.id == f.id }) { org.folders.append(f) }
            org.folderProjects[f.id] = (sourceOrg.folderProjects[folder.id] ?? []).compactMap { projectMap[$0] }
        }
        for (id, name) in sourceOrg.exportNames { if let mapped = materialMap[id] { org.exportNames[mapped] = name } }
        for (key, data) in sourceOrg.legacyPayloads { org.legacyPayloads["\(sourceID):\(key)"] = data }
        for preset in source.presets ?? [] {
            var p = preset; p.id = stableID("preset:\(sourceID):\(p.id)")
            if !(report.snapshot.presets ?? []).contains(where: { $0.id == p.id }) { report.snapshot.presets = (report.snapshot.presets ?? []) + [p] }
        }
        report.snapshot.organization = org
        return report
    }

    static func create(at root: URL, name: String, snapshot: MaterialSnapshot) async throws -> LibraryDescriptor {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { throw MaterialDatabase.error("目标目录已存在，请选择新的资源库名称") }
        // Caller chooses an existing parent; never manufacture an offline mount.
        guard fm.fileExists(atPath: root.deletingLastPathComponent().path) else { throw MaterialDatabase.error("目标磁盘未连接") }
        let staging = root.deletingLastPathComponent().appendingPathComponent(".library-staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        let database = MaterialDatabase(root: staging)
        let empty = try await database.load()
        try await database.commit(snapshot, previous: empty)
        let checked = try await database.load()
        guard checked.materials == snapshot.materials, checked.links == snapshot.links, checked.organization == snapshot.organization, (checked.presets ?? []) == (snapshot.presets ?? []) else { throw MaterialDatabase.error("资源库写入核对失败，临时库已保留") }
        let descriptor = LibraryDescriptor(name: name)
        try descriptor.write(staging)
        try fm.moveItem(at: staging, to: root)
        return descriptor
    }

    /// Read SQLite using READONLY. No schema creation or silent payload skipping in migration.
    static func legacyRows(_ url: URL, table: String) throws -> [Data] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw MaterialDatabase.error("无法读取旧数据库：\(url.path)") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM \(table)", -1, &statement, nil) == SQLITE_OK else { throw MaterialDatabase.error("旧库表读取失败：\(table) · \(String(cString: sqlite3_errmsg(db)))") }
        defer { sqlite3_finalize(statement) }
        var result: [Data] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw MaterialDatabase.error("旧库包含空记录") }
            result.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw MaterialDatabase.error("旧库读取中断") }
        return result
    }


    static func legacyPairs(_ url: URL, table: String, columns: String) throws -> [(String, String)] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw MaterialDatabase.error("旧库无法读取") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT \(columns) FROM \(table)", -1, &statement, nil) == SQLITE_OK else { throw MaterialDatabase.error("旧库引用表缺失：\(table)") }
        defer { sqlite3_finalize(statement) }
        var result: [(String, String)] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let a = sqlite3_column_text(statement, 0), let b = sqlite3_column_text(statement, 1) else { throw MaterialDatabase.error("旧库引用记录损坏") }
            result.append((String(cString: a), String(cString: b))); status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw MaterialDatabase.error("旧库引用读取中断") }
        return result
    }

    static func backupAndMigrate(root: URL) async throws -> MaterialSnapshot {
        let fm = FileManager.default
        let backup = root.appendingPathComponent("BeforeUnifiedLibrary-" + UUID().uuidString)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        func copyFile(_ from: URL, _ to: URL) throws {
            guard fm.fileExists(atPath: from.path) else { return }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if from.pathExtension == "sqlite" { try sqliteBackup(from: from, to: to) }
            else { try fm.copyItem(at: from, to: to) }
        }
        for name in ["library.json", "global-material-library.sqlite", "global-material-library.json", "optimization-notes.json", "material-import-resume.json"] {
            try copyFile(root.appendingPathComponent(name), backup.appendingPathComponent(name))
        }
        let registryFile = root.appendingPathComponent("projects.json")
        if fm.fileExists(atPath: registryFile.path) {
            let originalRegistry = try Data(contentsOf: registryFile)
            try originalRegistry.write(to: backup.appendingPathComponent("projects.original.json"))
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            var registry = try decoder.decode(ProjectRegistryData.self, from: originalRegistry)
            func capture(_ project: ProjectRecord) throws -> ProjectRecord {
                let source = URL(fileURLWithPath: project.databasePath)
                guard fm.fileExists(atPath: source.path) else { throw MaterialDatabase.error("旧项目数据库缺失：\(project.name)") }
                let target = backup.appendingPathComponent("Projects/" + stableID(project.id) + "/project.sqlite")
                try copyFile(source, target)
                let folder = source.deletingLastPathComponent()
                for relative in ["PendingImports/.assetframe-pending.json", "PendingImports/.assetframe-import-journal.ndjson", "image-import-resume.json"] {
                    try copyFile(folder.appendingPathComponent(relative), target.deletingLastPathComponent().appendingPathComponent(relative))
                }
                var copied = project; copied.databasePath = target.path; return copied
            }
            registry.projects = try registry.projects.map(capture)
            registry.removedProjects = try registry.removedProjects?.map(capture)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(registry).write(to: backup.appendingPathComponent("projects.json"), options: .atomic)
        }
        return try await migrateLegacy(root: backup)
    }
    private static func sqliteBackup(from source: URL, to target: URL) throws {
        var input: OpaquePointer?, output: OpaquePointer?
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let input else { throw MaterialDatabase.error("无法备份旧数据库") }
        defer { sqlite3_close(input) }
        guard sqlite3_open(target.path, &output) == SQLITE_OK, let output else { throw MaterialDatabase.error("无法写入备份") }
        defer { sqlite3_close(output) }
        guard let copy = sqlite3_backup_init(output, "main", input, "main") else { throw MaterialDatabase.error("备份初始化失败") }
        let status = sqlite3_backup_step(copy, -1)
        let finish = sqlite3_backup_finish(copy)
        guard status == SQLITE_DONE && finish == SQLITE_OK else { throw MaterialDatabase.error("旧库正在写入或备份失败，请关闭旧版后重试") }
        // sqlite3_backup copies the WAL-mode header too. Normalize the destination
        // before closing it so a subsequent READONLY connection needs no recovery.
        guard sqlite3_exec(output, "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;", nil, nil, nil) == SQLITE_OK else {
            throw MaterialDatabase.error("数据库备份日志整理失败")
        }
    }

    static func migrateLegacy(root: URL) async throws -> MaterialSnapshot {
        let fm = FileManager.default
        var result = MaterialSnapshot(materials: [], links: [], organization: LibraryOrganization())
        let materialDB = root.appendingPathComponent("global-material-library.sqlite")
        if fm.fileExists(atPath: materialDB.path) {
            result.materials = try legacyRows(materialDB, table: "materials").map { try JSONDecoder().decode(MaterialRecord.self, from: $0) }
            result.links = try legacyRows(materialDB, table: "links").map { try JSONDecoder().decode(ProjectMaterialLink.self, from: $0) }
            result.presets = try legacyRows(materialDB, table: "presets").map { try JSONDecoder().decode(MaterialFilterPreset.self, from: $0) }
        } else if fm.fileExists(atPath: root.appendingPathComponent("global-material-library.json").path) {
            result = try JSONDecoder().decode(MaterialSnapshot.self, from: Data(contentsOf: root.appendingPathComponent("global-material-library.json")))
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let registryURL = root.appendingPathComponent("projects.json")
        var org = result.organization ?? LibraryOrganization()
        if fm.fileExists(atPath: registryURL.path) {
            let registry = try decoder.decode(ProjectRegistryData.self, from: Data(contentsOf: registryURL))
            org.projects = registry.projects + (registry.removedProjects ?? [])
            for project in org.projects {
                let dbURL = URL(fileURLWithPath: project.databasePath)
                guard fm.fileExists(atPath: dbURL.path) else { throw MaterialDatabase.error("旧项目数据库缺失：\(project.name)") }
                let assets = try legacyRows(dbURL, table: "assets").map { try decoder.decode(AssetItem.self, from: $0) }
                for asset in assets { appendLegacy(asset, project: project, result: &result, org: &org) }
                for (assetID, name) in try legacyPairs(dbURL, table: "export_items", columns: "asset_id,export_name") {
                    guard let materialID = org.legacyMapping["legacy:\(project.id):\(assetID)"] else { throw MaterialDatabase.error("旧导出引用缺失") }
                    org.exportNames[materialID] = name
                    if let i = result.links.firstIndex(where: { $0.projectID == project.id && $0.materialID == materialID }) { result.links[i].selection = "选用" }
                }
                let relations = try legacyPairs(dbURL, table: "relations", columns: "group_id,asset_id")
                org.legacyPayloads["\(project.id):relations"] = try JSONEncoder().encode(relations.map { [$0.0, $0.1] })
                let folders = try legacyRows(dbURL, table: "local_folder_sources").map { try decoder.decode(LocalFolderSource.self, from: $0) }
                for folder in folders {
                    var f = folder; f.id = stableID("\(project.id):folder:\(folder.id)")
                    org.folders.append(f); org.folderProjects[f.id] = [project.id]
                }
                // Retain complete historical production payloads in the unified database.
                for table in ["groups", "asset_stacks", "script_extractions", "generation_batches"] {
                    let rows = try legacyRows(dbURL, table: table)
                    org.legacyPayloads["\(project.id):\(table)"] = try JSONEncoder().encode(rows)
                }
                for stack in try legacyRows(dbURL, table: "asset_stacks").map({ try decoder.decode(AssetStack.self, from: $0) }) {
                    let versionGroup = stableID("legacy-version:\(project.id):\(stack.id)")
                    for oldID in stack.memberAssetIDs {
                        if let materialID = org.legacyMapping["legacy:\(project.id):\(oldID)"], let i = result.materials.firstIndex(where: { $0.id == materialID }) {
                            result.materials[i].production?.versionGroupID = versionGroup
                        }
                    }
                }
                let support = dbURL.deletingLastPathComponent()
                let manifests = [support.appendingPathComponent("PendingImports/.assetframe-pending.json"), URL(fileURLWithPath: project.rootPath).appendingPathComponent("00_向量时刻待导入/.assetframe-pending.json")]
                let journal = support.appendingPathComponent("PendingImports/.assetframe-import-journal.ndjson")
                var seen: Set<String> = []
                for file in manifests where fm.fileExists(atPath: file.path) {
                    let data = try readLegacyMetadata(file, project: project)
                    org.legacyPayloads["\(project.id):pending:" + stableID(file.path)] = data
                    for pending in try decoder.decode([PendingImportItem].self, from: data) where seen.insert(pending.id).inserted {
                        appendPending(pending, project: project, result: &result, org: &org)
                    }
                }
                if fm.fileExists(atPath: journal.path) {
                    let data = try readLegacyMetadata(journal, project: project)
                    org.legacyPayloads["\(project.id):pending-journal"] = data
                    for line in data.split(separator: 0x0A) {
                        let pending = try decoder.decode(PendingImportItem.self, from: Data(line))
                        if seen.insert(pending.id).inserted { appendPending(pending, project: project, result: &result, org: &org) }
                    }
                }
            }
        } else if fm.fileExists(atPath: root.appendingPathComponent("library.json").path) {
            let library = try decoder.decode(LibraryData.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
            let project = ProjectRecord(id: "legacy-library", name: "原素材库", rootPath: root.path, databasePath: "", isLegacy: true, lastOpenedAt: .now)
            org.projects.append(project)
            for asset in library.assets { appendLegacy(asset, project: project, result: &result, org: &org) }
            org.legacyPayloads["legacy-library:library"] = try Data(contentsOf: root.appendingPathComponent("library.json"))
        }
        for link in result.links where !org.projects.contains(where: { $0.id == link.projectID }) {
            org.projects.append(ProjectRecord(id: link.projectID, name: "项目 \(link.projectID)", rootPath: "", databasePath: "", isLegacy: true, lastOpenedAt: .now))
        }
        for index in result.materials.indices {
            guard let asset = result.materials[index].legacyAsset,
                  let projectID = result.links.first(where: { $0.materialID == result.materials[index].id })?.projectID,
                  let oldParent = asset.generationProvenance?.parentAssetID else { continue }
            if let parent = org.legacyMapping["legacy:\(projectID):\(oldParent)"] {
                result.materials[index].production?.provenance?.parentAssetID = parent
                result.materials[index].production?.inputMaterialIDs = [parent]
            }
        }
        result.organization = org
        return result
    }
    private static func appendPending(_ pending: PendingImportItem, project: ProjectRecord,
                                      result: inout MaterialSnapshot, org: inout LibraryOrganization) {
        var asset = pending.makePreviewAsset(checkSourceAvailability: false)
        asset.sourceOriginalPath = pending.originalSourcePath
        appendLegacy(asset, project: project, result: &result, org: &org)
    }
    private static func appendLegacy(_ asset: AssetItem, project: ProjectRecord, result: inout MaterialSnapshot, org: inout LibraryOrganization) {
        let key = "legacy:\(project.id):\(asset.id)"
        guard org.legacyMapping[key] == nil else { return }
        let id = stableID(key)
        if let payload = try? JSONEncoder().encode(asset) { org.legacyPayloads[key] = payload }
        if let existing = result.materials.first(where: { $0.id == asset.materialID && $0.sourcePath == asset.imagePath && $0.name == asset.name && $0.tags == asset.normalizedTags && $0.rating == asset.starRating && $0.note == asset.note && $0.deletedAt == asset.deletedAt }) {
            org.legacyMapping[key] = existing.id
            if !result.links.contains(where: { $0.projectID == project.id && $0.materialID == existing.id }) {
                result.links.append(ProjectMaterialLink(id: stableID("link:" + key), projectID: project.id, materialID: existing.id, use: .candidate, createdAt: asset.createdAt))
            }
            return
        }
        var p = MaterialProductionMetadata(); p.purpose = asset.purpose.rawValue; p.review = asset.decision.rawValue
        p.versionName = asset.version; p.platform = asset.generationPlatform; p.prompt = asset.promptSource; p.provenance = asset.generationProvenance; p.isCommon = asset.category == .common
        let type = UTType(filenameExtension: URL(fileURLWithPath: asset.imagePath).pathExtension)
        let kind: MaterialKind = type?.conforms(to: .movie) == true ? .video : type?.conforms(to: .audio) == true ? .audio : .image
        let m = MaterialRecord(id: id, kind: kind, name: asset.name, sourcePath: asset.imagePath,
            sourceURL: asset.sourceURL, originalFilename: asset.originalFilename, fingerprint: "source:legacy:\(id)",
            contentFingerprint: asset.fingerprint.isEmpty ? nil : asset.fingerprint, sourceLocations: Array(Set([asset.imagePath, asset.sourceOriginalPath].compactMap { $0 })).sorted(),
            fileSize: asset.sourceFileSize, sourceCreatedAt: asset.sourceCreatedAt, sourceModifiedAt: asset.sourceModifiedAt,
            mediaMetadata: MaterialMediaMetadata(pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight), production: p,
            createdAt: asset.createdAt, tags: asset.normalizedTags, rating: asset.starRating, note: asset.note,
            lastUsedAt: asset.lastUsedAt, assetType: asset.type, legacyAsset: asset, migrationConflict: result.materials.contains(where: { $0.sourcePath == asset.imagePath }) ? "同来源的旧项目记录已独立保留，待核对" : nil, deletedAt: asset.deletedAt)
        result.materials.append(m); org.legacyMapping[key] = id
        for (number, version) in (asset.sourceVersions ?? []).enumerated() where version.path != asset.imagePath {
            var previous = m; previous.id = stableID(key + ":version:" + version.path)
            previous.sourcePath = version.path; previous.originalFilename = version.filename; previous.sourceLocations = [version.path]
            previous.fileSize = version.fileSize; previous.sourceModifiedAt = version.modifiedAt
            previous.fingerprint = "source:legacy:" + previous.id; previous.contentFingerprint = nil
            previous.production?.versionGroupID = id; previous.production?.versionName = "历史版本 \(number + 1)"
            previous.mediaMetadata = MaterialMediaMetadata(pixelWidth: version.pixelWidth, pixelHeight: version.pixelHeight)
            result.materials.append(previous)
        }
        result.links.append(ProjectMaterialLink(id: stableID("link:\(key)"), projectID: project.id, materialID: id, use: .candidate, episode: asset.episodes.joined(separator: "、"), createdAt: asset.createdAt))
    }
}

extension LibraryTransfer {
    static func readLibrary(_ root: URL) throws -> MaterialSnapshot {
        _ = try LibraryDescriptor.read(root)
        let db = root.appendingPathComponent("global-material-library.sqlite"), decoder = JSONDecoder()
        return try MaterialSnapshot(materials: legacyRows(db, table: "materials").map { try decoder.decode(MaterialRecord.self, from: $0) },
            links: legacyRows(db, table: "links").map { try decoder.decode(ProjectMaterialLink.self, from: $0) },
            presets: legacyRows(db, table: "presets").map { try decoder.decode(MaterialFilterPreset.self, from: $0) },
            organization: legacyRows(db, table: "organization").first.map { try decoder.decode(LibraryOrganization.self, from: $0) })
    }
}
