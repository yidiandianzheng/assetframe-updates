import AppKit
import Combine
import Foundation

@MainActor
final class GlobalFiveStarStore: ObservableObject {
    @Published private(set) var records: [GlobalFiveStarRecord] = []
    @Published private(set) var links: [GlobalFiveStarLink] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var contentRevision: UInt64 = 0
    @Published var toast: String?

    private struct Snapshot: Codable { var links: [GlobalFiveStarLink] }

    private let fileManager = FileManager.default
    private let storageURL: URL

    init(rootURL: URL? = nil) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storageURL = (rootURL ?? support.appendingPathComponent("AssetFrame", isDirectory: true))
            .appendingPathComponent("global-five-star-links.json")
        load()
    }

    func refresh(
        projects: [ProjectRecord],
        currentProjectID: String,
        currentAssets: [AssetItem]
    ) async {
        isRefreshing = true
        defer { isRefreshing = false }

        var grouped: [String: [GlobalFiveStarSource]] = [:]
        for project in projects {
            let projectAssets: [AssetItem]
            if project.id == currentProjectID {
                projectAssets = currentAssets
            } else {
                projectAssets = (try? await ProjectDatabase(url: URL(fileURLWithPath: project.databasePath)).load())?
                    .library.assets ?? []
            }
            for asset in projectAssets where asset.deletedAt == nil && (asset.starRating == 5 || asset.isMaster) {
                let key = Self.identity(for: asset)
                grouped[key, default: []].append(GlobalFiveStarSource(
                    projectID: project.id,
                    projectName: project.name,
                    assetID: asset.id,
                    asset: asset
                ))
            }
        }

        let linkedByRecord = Dictionary(grouping: links, by: \.recordID)
        records = grouped.map { key, sources in
            let representative = Self.preferredAsset(in: sources.map(\.asset), fileManager: fileManager)
            let linkedProjects = Set((linkedByRecord[key] ?? []).map(\.projectID))
            return GlobalFiveStarRecord(
                id: key,
                asset: representative,
                sources: sources.sorted { $0.projectName.localizedStandardCompare($1.projectName) == .orderedAscending },
                linkedProjectIDs: linkedProjects
            )
        }.sorted {
            if $0.asset.createdAt != $1.asset.createdAt { return $0.asset.createdAt > $1.asset.createdAt }
            return $0.asset.name.localizedStandardCompare($1.asset.name) == .orderedAscending
        }
        contentRevision &+= 1
    }

    func records(
        scope: FiveStarScope,
        projectID: String,
        search: String,
        type: AssetType?,
        category: FiveStarAssetCategory? = nil
    ) -> [GlobalFiveStarRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return records.filter { record in
            if scope == .allProjects {
                guard record.isReusableTemplate else { return false }
            } else {
                guard record.isFiveStarAvailable(to: projectID) else { return false }
            }
            guard category == nil || category?.includes(record.asset.type) == true else { return false }
            guard type == nil || record.asset.type == type else { return false }
            guard !query.isEmpty else { return true }
            return [
                record.asset.name,
                record.asset.originalFilename,
                record.asset.normalizedTags.joined(separator: " "),
                record.sourceProjectNames.joined(separator: " ")
            ].joined(separator: " ").localizedLowercase.contains(query)
        }
    }

    func count(scope: FiveStarScope, projectID: String) -> Int {
        if scope == .allProjects {
            records.lazy.filter(\.isReusableTemplate).count
        } else {
            records.lazy.filter { $0.isFiveStarAvailable(to: projectID) }.count
        }
    }

    func count(scope: FiveStarScope, projectID: String, category: FiveStarAssetCategory) -> Int {
        records.lazy.filter {
            let belongsToScope = scope == .allProjects ? $0.isReusableTemplate : $0.isFiveStarAvailable(to: projectID)
            return belongsToScope && category.includes($0.asset.type)
        }.count
    }

    func isLinked(_ recordID: String, to projectID: String) -> Bool {
        links.contains { $0.recordID == recordID && $0.projectID == projectID }
    }

    func addLink(recordID: String, projectID: String) {
        guard !isLinked(recordID, to: projectID) else {
            toast = "已经引用到当前项目"
            return
        }
        links.append(GlobalFiveStarLink(
            id: UUID().uuidString,
            recordID: recordID,
            projectID: projectID,
            createdAt: .now
        ))
        applyLinksToRecords()
        save()
        toast = "已引用到当前项目；没有复制或移动图片"
    }

    func addLinks(recordIDs: Set<String>, projectID: String) {
        let existing = Set(links.lazy.filter { $0.projectID == projectID }.map(\.recordID))
        let additions = recordIDs.subtracting(existing)
        guard !additions.isEmpty else {
            toast = "所选五星已经引用到当前项目"
            return
        }
        links.append(contentsOf: additions.map {
            GlobalFiveStarLink(id: UUID().uuidString, recordID: $0, projectID: projectID, createdAt: .now)
        })
        applyLinksToRecords()
        save()
        toast = "已引用 \(additions.count) 项到当前项目；没有复制或移动图片"
    }

    func removeLink(recordID: String, projectID: String) {
        links.removeAll { $0.recordID == recordID && $0.projectID == projectID }
        applyLinksToRecords()
        save()
        toast = "已取消当前项目引用；来源资产和原文件保持不变"
    }

    func removeLinks(recordIDs: Set<String>, projectID: String) {
        let before = links.count
        links.removeAll { $0.projectID == projectID && recordIDs.contains($0.recordID) }
        let removed = before - links.count
        guard removed > 0 else { return }
        applyLinksToRecords()
        save()
        toast = "已取消 \(removed) 项当前项目引用；来源资产保持不变"
    }

    func reveal(_ record: GlobalFiveStarRecord) {
        let path = displayPath(for: record.asset)
        guard fileManager.fileExists(atPath: path) else {
            toast = "原文件和SSD副本当前都不可用"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copyPath(_ record: GlobalFiveStarRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayPath(for: record.asset), forType: .string)
        toast = "已复制当前可用路径"
    }

    func copyOriginalImage(_ record: GlobalFiveStarRecord) {
        let url = URL(fileURLWithPath: displayPath(for: record.asset))
        do {
            try OriginalImageClipboard.copyImage(at: url)
            toast = "已复制原图，可直接到 Codex 粘贴"
        } catch {
            toast = error.localizedDescription
        }
    }

    private func displayPath(for asset: AssetItem) -> String {
        if fileManager.fileExists(atPath: asset.imagePath) { return asset.imagePath }
        if let original = asset.sourceOriginalPath, fileManager.fileExists(atPath: original) { return original }
        return asset.imagePath
    }

    private func applyLinksToRecords() {
        let linkedByRecord = Dictionary(grouping: links, by: \.recordID)
        records = records.map { record in
            var copy = record
            copy.linkedProjectIDs = Set((linkedByRecord[record.id] ?? []).map(\.projectID))
            return copy
        }
        contentRevision &+= 1
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let snapshot = try? Self.decoder.decode(Snapshot.self, from: data) else { return }
        links = snapshot.links
    }

    private func save() {
        guard let data = try? Self.encoder.encode(Snapshot(links: links)) else { return }
        try? fileManager.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: .atomic)
    }

    nonisolated private static func identity(for asset: AssetItem) -> String {
        let fingerprint = asset.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        if !fingerprint.isEmpty { return "fingerprint:\(fingerprint)" }
        let path = (asset.sourceOriginalPath?.isEmpty == false ? asset.sourceOriginalPath : asset.imagePath) ?? asset.imagePath
        return "path:\(URL(fileURLWithPath: path).standardizedFileURL.path.localizedLowercase)"
    }

    nonisolated private static func preferredAsset(in candidates: [AssetItem], fileManager: FileManager) -> AssetItem {
        var chosen = candidates.first!
        if let available = candidates.first(where: {
            fileManager.fileExists(atPath: $0.imagePath) ||
            ($0.sourceOriginalPath.map(fileManager.fileExists(atPath:)) ?? false)
        }) {
            chosen = available
        }
        if !fileManager.fileExists(atPath: chosen.imagePath),
           let original = chosen.sourceOriginalPath,
           fileManager.fileExists(atPath: original) {
            chosen.imagePath = original
            chosen.isSourceMissing = false
        }
        return chosen
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
