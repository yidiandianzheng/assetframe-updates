import Foundation
import SQLite3

final class ProjectRegistry {
    private(set) var data: ProjectRegistryData

    private let rootURL: URL
    private let projectsURL: URL
    private let registryURL: URL
    private let legacyAssetsURL: URL

    init(rootURL: URL, legacyAssetsURL: URL) {
        self.rootURL = rootURL
        self.projectsURL = rootURL.appendingPathComponent("Projects", isDirectory: true)
        self.registryURL = rootURL.appendingPathComponent("projects.json")
        self.legacyAssetsURL = legacyAssetsURL
        try? FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)

        if let stored = try? Data(contentsOf: registryURL),
           let decoded = try? ProjectRegistry.decoder.decode(ProjectRegistryData.self, from: stored),
           !decoded.projects.isEmpty {
            data = decoded
            if deduplicateProjectsIfNeeded(originalRegistryData: stored) { save() }
        } else {
            let hasLegacyLibrary = FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("library.json").path)
            let initialID = hasLegacyLibrary ? "legacy-library" : "default-library"
            let databaseURL = projectsURL.appendingPathComponent(initialID, isDirectory: true).appendingPathComponent("project.sqlite")
            let bookmark = try? legacyAssetsURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            let initialProject = ProjectRecord(
                id: initialID,
                name: hasLegacyLibrary ? "旧资料库" : "资产库",
                rootPath: legacyAssetsURL.path,
                bookmarkData: bookmark,
                databasePath: databaseURL.path,
                isLegacy: hasLegacyLibrary,
                lastOpenedAt: Date()
            )
            data = ProjectRegistryData(projects: [initialProject], currentProjectID: initialID)
            save()
        }
    }

    var projects: [ProjectRecord] {
        data.projects.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    var current: ProjectRecord {
        data.projects.first(where: { $0.id == data.currentProjectID }) ?? data.projects[0]
    }

    func addProject(folderURL: URL) -> ProjectRecord {
        if let existing = data.projects.first(where: { URL(fileURLWithPath: $0.rootPath).standardizedFileURL == folderURL.standardizedFileURL }) {
            select(existing.id)
            return current
        }
        if let removedIndex = data.removedProjects?.firstIndex(where: {
            URL(fileURLWithPath: $0.rootPath).standardizedFileURL == folderURL.standardizedFileURL
        }) {
            let restored = data.removedProjects!.remove(at: removedIndex)
            data.projects.append(restored)
            data.currentProjectID = restored.id
            if data.removedProjects?.isEmpty == true { data.removedProjects = nil }
            save()
            return restored
        }
        let id = UUID().uuidString.lowercased()
        let databaseURL = projectsURL.appendingPathComponent(id, isDirectory: true).appendingPathComponent("project.sqlite")
        let bookmark = try? folderURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let project = ProjectRecord(
            id: id,
            name: folderURL.lastPathComponent,
            rootPath: folderURL.path,
            bookmarkData: bookmark,
            databasePath: databaseURL.path,
            isLegacy: false,
            lastOpenedAt: Date()
        )
        data.projects.append(project)
        data.currentProjectID = id
        save()
        return project
    }

    func select(_ id: String) {
        guard let index = data.projects.firstIndex(where: { $0.id == id }) else { return }
        data.currentProjectID = id
        data.projects[index].lastOpenedAt = Date()
        save()
    }

    /// 只修改 AssetFrame 中的项目显示名称，不重命名项目文件夹或改变任何路径。
    func rename(_ id: String, to displayName: String) -> ProjectRecord? {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = data.projects.firstIndex(where: { $0.id == id }) else { return nil }
        data.projects[index].name = name
        save()
        return data.projects[index]
    }

    func relocate(_ id: String, to folderURL: URL) -> ProjectRecord? {
        guard let index = data.projects.firstIndex(where: { $0.id == id }) else { return nil }
        data.projects[index].rootPath = folderURL.path
        data.projects[index].bookmarkData = try? folderURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        data.projects[index].lastOpenedAt = Date()
        save()
        return data.projects[index]
    }

    /// 移除项目登记，不触碰项目文件夹或项目记忆库；由调用方先完成明确的文件处置。
    func remove(_ id: String) -> ProjectRecord? {
        guard data.projects.count > 1,
              let index = data.projects.firstIndex(where: { $0.id == id }) else { return nil }
        let wasCurrent = data.currentProjectID == id
        let removed = data.projects.remove(at: index)
        data.removedProjects = (data.removedProjects ?? []) + [removed]
        if wasCurrent {
            data.currentProjectID = data.projects.max(by: { $0.lastOpenedAt < $1.lastOpenedAt })?.id ?? data.projects[0].id
        }
        save()
        return current
    }

    func resolvedRootURL(for project: ProjectRecord) -> URL {
        if let bookmark = project.bookmarkData {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                if stale { _ = relocate(project.id, to: resolved) }
                return resolved
            }
        }
        return URL(fileURLWithPath: project.rootPath, isDirectory: true)
    }

    private func save() {
        guard let encoded = try? ProjectRegistry.encoder.encode(data) else { return }
        try? encoded.write(to: registryURL, options: .atomic)
    }

    /// Older builds could register the same folder more than once. Collapse
    /// those entries without guessing from recency alone: prefer the database
    /// whose stored source paths actually belong to the registered root.
    @discardableResult
    private func deduplicateProjectsIfNeeded(originalRegistryData: Data) -> Bool {
        let groups = Dictionary(grouping: data.projects, by: { Self.normalizedPath($0.rootPath) })
        guard groups.values.contains(where: { $0.count > 1 }) else { return false }

        let backupURL = rootURL.appendingPathComponent("projects.pre-dedup-backup.json")
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try? originalRegistryData.write(to: backupURL, options: .atomic)
        }

        var winners: [ProjectRecord] = []
        var replacementIDs: [String: String] = [:]
        var seenRoots = Set<String>()
        for project in data.projects {
            let root = Self.normalizedPath(project.rootPath)
            guard seenRoots.insert(root).inserted, let candidates = groups[root] else { continue }
            let winner = candidates.max { lhs, rhs in
                let leftScore = Self.belongingAssetCount(in: lhs.databasePath, rootPath: root)
                let rightScore = Self.belongingAssetCount(in: rhs.databasePath, rootPath: root)
                if leftScore != rightScore { return leftScore < rightScore }
                return lhs.lastOpenedAt < rhs.lastOpenedAt
            } ?? project
            winners.append(winner)
            for candidate in candidates where candidate.id != winner.id {
                replacementIDs[candidate.id] = winner.id
            }
        }
        data.projects = winners
        if let replacement = replacementIDs[data.currentProjectID] { data.currentProjectID = replacement }
        if !data.projects.contains(where: { $0.id == data.currentProjectID }) {
            data.currentProjectID = data.projects[0].id
        }
        let activeRoots = Set(data.projects.map { Self.normalizedPath($0.rootPath) })
        data.removedProjects = data.removedProjects?.filter { !activeRoots.contains(Self.normalizedPath($0.rootPath)) }
        if data.removedProjects?.isEmpty == true { data.removedProjects = nil }
        return true
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private static func belongingAssetCount(in databasePath: String, rootPath: String) -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return 0
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT payload FROM assets", -1, &statement, nil) == SQLITE_OK,
              let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        var count = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let payload = Data(String(cString: raw).utf8)
            guard let asset = try? decoder.decode(AssetItem.self, from: payload) else { continue }
            let paths = [asset.imagePath, asset.sourceOriginalPath].compactMap { $0 }
            if paths.contains(where: {
                let normalized = normalizedPath($0)
                return normalized == rootPath || normalized.hasPrefix(prefix)
            }) { count += 1 }
        }
        return count
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601; return encoder
    }
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}
