import AppKit
import Foundation

extension GlobalMaterialStore {
    func commitUsage(_ requested: ProjectMaterialLink) async throws {
        var link = requested
        let before = try await committedLibrary()
        guard before.materials.contains(where: { $0.id == link.materialID && $0.deletedAt == nil }),
              !link.projectID.isEmpty, validRange(link) else {
            throw MaterialDatabase.error("素材已不可用或引用区间无效，未保存")
        }
        guard let material = before.materials.first(where: { $0.id == link.materialID }),
              let hash = await Task.detached(operation: { GlobalMaterialStore.verifiedContentFingerprint(material) }).value else {
            throw MaterialDatabase.error("素材内容变化或不可读，请作为新版本导入")
        }
        if let expected = link.boundFingerprint, expected != hash { throw MaterialDatabase.error("素材与确认时文件指纹不同，未选用") }
        link.boundFingerprint = hash
        if let old = before.links.first(where: { $0.id == link.id }), old.materialID != link.materialID {
            link.previousVersions = (old.previousVersions ?? []) + [.init(materialID: old.materialID, fingerprint: old.boundFingerprint, variantID: old.variantID, replacedAt: .now)]
        }
        var after = before
        if let index = after.links.firstIndex(where: { $0.id == link.id }) { after.links[index] = link }
        else { after.links.append(link) }
        try await replaceLibrary(after, expected: before)
    }

    func confirmMaterial(_ id: String) async throws {
        let before = try await committedLibrary()
        guard let index = before.materials.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else {
            throw MaterialDatabase.error("素材已不可用")
        }
        var after = before
        var production = after.materials[index].production ?? MaterialProductionMetadata()
        production.review = "保留"
        after.materials[index].production = production
        try await replaceLibrary(after, expected: before)
    }

    func libraryDeliverySnapshot(projectID: String) async throws -> MaterialSnapshot {
        var snapshot = try await committedLibrary()
        snapshot.links = snapshot.links.filter { $0.selection == "选用" }.map {
            var link = $0; link.projectID = projectID; return link
        }
        let selected = Set(snapshot.links.map(\.materialID))
        for (id, name) in snapshot.organization?.exportNames ?? [:] {
            guard let index = snapshot.materials.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { continue }
            snapshot.materials[index].name = name
            if !selected.contains(id) {
                snapshot.links.append(ProjectMaterialLink(id: "legacy-export-" + id, projectID: projectID,
                    materialID: id, use: .working, selection: "选用", createdAt: .now))
            }
        }
        return snapshot
    }

    func chooseDelivery(project: ProjectRecord, includeLibraryQueue: Bool = false) {
        let panel = NSOpenPanel(); panel.title = "选择生产素材交付位置"; panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            guard case .success = await saveNow() else { return }
            let snapshot: MaterialSnapshot
            do { snapshot = try await (includeLibraryQueue ? libraryDeliverySnapshot(projectID: project.id) : committedLibrary()) }
            catch { toast = error.localizedDescription; return }
            let records = snapshot.materials, usages = snapshot.links
            let result = await Task.detached(priority: .userInitiated) {
                Result { try MaterialDelivery.export(materials: records, links: usages, projectID: project.id, destination: destination) }
            }.value
            switch result {
            case .success(let url): toast = "交付完成：\(url.lastPathComponent)"; NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure(let error): toast = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    func rate(_ ids: Set<String>, rating: Int, project: ProjectRecord, ssdRoot: URL? = nil) {
        toast = "正在设置为 \(rating) 星…"
        batchUpdate(ids) { $0.rating = min(5, max(0, rating)) }
        if rating == 5 {
            copyManaged(ids, common: false, project: project, ssdRoot: ssdRoot ?? managedSSDURL)
        } else {
            Task {
                if case .success = await saveNow() { toast = "已设置为 \(rating) 星" }
            }
        }
    }
    func makeCommon(_ ids: Set<String>, project: ProjectRecord, ssdRoot: URL? = nil) {
        toast = "正在加入通用资产…"
        batchUpdate(ids) { var p = $0.production ?? MaterialProductionMetadata(); p.isCommon = true; $0.production = p }
        copyManaged(ids, common: true, project: project, ssdRoot: ssdRoot ?? managedSSDURL)
    }
    func retryManagedCopies(project: ProjectRecord) {
        copyManaged(Set(materials.filter { $0.deletedAt == nil && $0.rating == 5 }.map(\.id)), common: false, project: project, ssdRoot: managedSSDURL)
        copyManaged(Set(materials.filter { $0.deletedAt == nil && $0.production?.isCommon == true }.map(\.id)), common: true, project: project, ssdRoot: managedSSDURL)
    }
    private func copyManaged(_ ids: Set<String>, common: Bool, project: ProjectRecord, ssdRoot: URL) {
        guard !ids.isEmpty, canWrite else { return }
        let previous = managedCopyTask
        managedCopyJobs += 1
        managedCopyTask = Task {
            defer { managedCopyJobs -= 1 }
            await previous?.value
            guard case .success = await saveNow() else { return }
            let candidates = materials.filter { ids.contains($0.id) && $0.kind != .link && $0.deletedAt == nil }
            let result = await Task.detached(priority: .utility) { () -> [(String, String?, String?)] in
                candidates.map { material in
                    do { return (material.id, try MaterialManagedCopy.copy(material, common: common, project: project, ssdRoot: ssdRoot).path, nil) }
                    catch { return (material.id, nil, error.localizedDescription) }
                }
            }.value
            for (id, path, issue) in result {
                if let path { completeManagedCopy(id, path: path) }
                if let issue { toast = issue }
            }
            guard case .success = await saveNow() else { toast = "副本已处理，但记录保存失败，请重新读取后重试"; return }
            if !result.isEmpty && result.allSatisfy({ $0.2 == nil }) {
                toast = common ? "已加入通用资产并保存 SSD 副本" : "已设为 5 星并保存 SSD 副本"
            }
        }
    }
}

/// Serial copy worker plus deterministic destinations prevents duplicate managed copies.
enum MaterialManagedCopy {
    private static let lock = NSLock()
    static func copy(_ material: MaterialRecord, common: Bool, project: ProjectRecord, ssdRoot: URL) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: ssdRoot.path) else { throw MaterialDatabase.error("SSD 未连接；素材保持原位，可连接后补齐受管副本") }
        guard let path = material.sourcePath, fm.isReadableFile(atPath: path) else { throw MaterialDatabase.error("原文件不可读，副本尚未生成") }
        guard let expectedHash = GlobalMaterialStore.verifiedContentFingerprint(material) else { throw MaterialDatabase.error("原文件已变化或不可读取") }
        let projectRoot = URL(fileURLWithPath: project.rootPath).standardizedFileURL
        let root: URL
        if projectRoot.path == ssdRoot.path || projectRoot.path.hasPrefix(ssdRoot.path + "/") {
            root = projectRoot.appendingPathComponent("01_向量时刻资产库")
        } else {
            root = ssdRoot.appendingPathComponent("向量时刻资产库").appendingPathComponent(MaterialDelivery.safe(project.name) + "_" + project.id.prefix(8)).appendingPathComponent("01_向量时刻资产库")
        }
        let folder = root.appendingPathComponent(common ? "06_通用资产" : "05_五星精选").appendingPathComponent(MaterialDelivery.folder(for: material))
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(MaterialDelivery.safe(material.id) + "_" + MaterialDelivery.safe(material.originalFilename))
        if fm.fileExists(atPath: target.path) {
            guard GlobalMaterialStore.streamFingerprint(target) == expectedHash else { throw MaterialDatabase.error("已有受管副本内容不同，未覆盖") }
            return target
        }
        let temp = folder.appendingPathComponent(".copy-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        try fm.copyItem(at: URL(fileURLWithPath: path), to: temp)
        guard GlobalMaterialStore.streamFingerprint(temp) == expectedHash else { throw MaterialDatabase.error("原文件已改变，请作为新版本导入") }
        try fm.moveItem(at: temp, to: target)
        return target
    }
}
