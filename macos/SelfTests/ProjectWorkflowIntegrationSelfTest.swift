import Foundation

@main struct ProjectWorkflowIntegrationSelfTest {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CharacterLibraryError.invalid("FAIL: " + message) }
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("assetframe-workflow-test-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let libraryRoot = root.appendingPathComponent("library")
        let materials = GlobalMaterialStore(rootURL: libraryRoot)
        await materials.waitUntilReady()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let oldURL = root.appendingPathComponent("旧图.png"), newURL = root.appendingPathComponent("新图.png")
        try png.write(to: oldURL); try (png + Data("new-version".utf8)).write(to: newURL)
        materials.importFiles([oldURL, newURL]); await materials.waitForImportCompletion(); await materials.waitForBackgroundMetadata()
        try await materials.saveNow().get()
        let old = materials.materials.first { $0.sourcePath == oldURL.path }!, new = materials.materials.first { $0.sourcePath == newURL.path }!
        let characters = CharacterLibraryStore(root: libraryRoot)
        let id = try characters.addProject(name: "隔离作品", root: root, existingID: "demo")
        var profile = CharacterProfile(projectID: id, characterID: "P-01")
        profile.fields["姓名"] = .init(text: "当前姓名", review: .confirmed)
        let profilePath = "人物/旧名/档案.md"
        try write(profilePath, CharacterMarkdown.render(profile, replacing: "# 原始正文保留\n"))
        try write("00_先读我.md", "# 入口\n[历史依据](历史/旧稿.md)\n[人物](人物/旧名/档案.md)")
        try write("历史/旧稿.md", "# 历史\n人物旧名，仅追溯。")
        let receipt = CharacterProjectModules.Receipt(projectID: id, characterID: "P-01", assetPath: oldURL.lastPathComponent, sha256: try CharacterProjectModules.fileHash(oldURL), materialID: old.id, variant: "猎户装", role: "主图", stage: "开局", confirmationEvidence: "用户明确确认具体旧图", platform: "", model: "", originalPrompt: "原始提示词 --ar 16:9", normalizedPrompt: ["固定特征": "身份保持"], profilePath: profilePath, sourcePaths: [])
        _ = try CharacterProjectModules.saveReceipt(receipt, root: root)
        let originalMD = try Data(contentsOf: root.appendingPathComponent(profilePath))
        characters.materialPaths = [oldURL.path: old.id, newURL.path: new.id]
        await characters.refreshSources()
        try check(characters.registry.entries.count == 1 && characters.loaded[0].profile?.assets.count == 1 && characters.loaded[0].receipts.count == 1, "standard source and receipt directly inherited")
        try check(try Data(contentsOf: root.appendingPathComponent(profilePath)) == originalMD, "refresh never changes project prose")
        try check(characters.reports[id]!.documents.contains { $0.path == "历史/旧稿.md" }, "explicit historical link followed")
        await characters.refreshSources()
        try check(characters.registry.entries.count == 1 && characters.loaded[0].profile?.assets.count == 1 && characters.reports[id]?.added == 0, "repeat refresh idempotent")
        let duplicate = root.appendingPathComponent("人物库索引/重复记录.md")
        try write("人物库索引/重复记录.md", CharacterProjectModules.encode(receipt, marker: "assetframe-confirmation", title: "重复副本"))
        await characters.refreshSources()
        try check(characters.loaded[0].receipts.count == 1, "identical receipt ID is displayed only once")
        var conflicting = receipt; conflicting.originalPrompt = "同 ID 不同记录"
        try write("人物库索引/重复记录.md", CharacterProjectModules.encode(conflicting, marker: "assetframe-confirmation", title: "冲突副本"))
        await characters.refreshSources()
        try check(characters.loaded[0].receipts.isEmpty && characters.loaded[0].unavailableAssetIDs.contains(old.id), "conflicting receipt ID blocks adoption")
        try fm.removeItem(at: duplicate)
        await characters.refreshSources()
        var intake = characters.intake
        let doc = characters.reports[id]!.documents.first { $0.path == "历史/旧稿.md" }!
        let nav = ProjectIntake.navigation(characters.reports[id]!.documents)
        let item = CharacterProjectScanner.Classification(path: doc.path, name: "当前姓名", kind: "人物档案", evidence: "人物旧名", conflict: "", suggestions: [])
        intake.record([item], documents: [doc], projectID: id, characterID: "P-01", name: "当前姓名", navigation: nav)
        try check(intake.cached(doc, projectID: id, characterID: "P-01", name: "当前姓名", navigation: nav) != nil, "unchanged AI cache reusable")
        try check(intake.cached(doc, projectID: id, characterID: "P-02", name: "当前姓名", navigation: nav) == nil, "AI cache isolated by identity")
        try characters.saveIntake(intake)
        try write("00_先读我.md", "# 入口变更\n[历史依据](历史/旧稿.md)\n[人物](人物/旧名/档案.md)")
        await characters.refreshSources()
        let newNav = ProjectIntake.navigation(characters.reports[id]!.documents)
        try check(characters.reports[id]!.navigationChanged && intake.cached(doc, projectID: id, characterID: "P-01", name: "当前姓名", navigation: newNav) == nil, "entry change invalidates context without changing source")
        profile.fields["姓名"]?.text = "改名后"
        try write(profilePath, CharacterMarkdown.render(profile, replacing: "# 原始正文保留\n"))
        await characters.refreshSources()
        try check(characters.registry.entries.count == 1 && characters.loaded[0].profile?.name == "改名后", "rename keeps identity and old path")
        // Explicit current retirement wins over historical confirmation.
        profile.assets = [.init(materialID: old.id, variant: "猎户装", role: "主图", stage: "开局", status: "历史停用")]
        try write(profilePath, CharacterMarkdown.render(profile, replacing: ""))
        await characters.refreshSources()
        try check(characters.loaded[0].profile?.assets.first?.status == "历史停用", "receipt cannot reactivate retired asset")
        var defaultProfile = profile
        try defaultProfile.selectDefault(materialID: old.id, variant: "旧造型", role: "主图", stage: "开局")
        try defaultProfile.selectDefault(materialID: new.id, variant: "新造型", role: "主图", stage: "开局")
        try check(defaultProfile.assets.filter { !$0.defaultUse.isEmpty }.count == 1 && defaultProfile.assets.first { !$0.defaultUse.isEmpty }?.materialID == new.id, "character default has one MD owner and one current slot")
        var graph = ProjectAssetGraph(projectID: id)
        graph.subjects = [.init(id: "C-01", kind: "服装", name: "猎户装"), .init(id: "D-01", kind: "道具", name: "木矛"), .init(id: "S-01", kind: "场景", name: "林地")]
        let variant = ProjectAssetGraph.Variant(id: "V-01", subjectID: "P-01", name: "开局", stage: "开局", costumeIDs: ["C-01"], propIDs: ["D-01"])
        graph.variants = [variant]
        let a = ProjectAssetGraph.Asset(id: "A-old", subjectID: "P-01", variantID: variant.id, materialID: old.id, path: oldURL.lastPathComponent, sha256: receipt.sha256, role: "主图", stage: "开局", status: "已确认", evidence: "测试明确确认", originalPrompt: receipt.originalPrompt)
        var b = a; b.id = "A-new"; b.materialID = new.id; b.path = newURL.lastPathComponent; b.sha256 = try CharacterProjectModules.fileHash(newURL)
        graph.assets = [a,b]
        try graph.setDefault(a.id)
        try ProjectAssetGraph.save(graph, root: root, expected: nil, characterIDs: ["P-01"])
        var read = try ProjectAssetGraph.read(root: root, projectID: id)
        var invalid = graph; invalid.assets[1].isDefault = true
        do { try invalid.validate(characterIDs: ["P-01"]); throw CharacterLibraryError.invalid("FAIL: duplicate default allowed") } catch CharacterLibraryError.invalid(let message) { try check(!message.hasPrefix("FAIL:"), "duplicate default rejected") }
        let first = ProjectMaterialLink(id: "use1", projectID: id, materialID: old.id, use: .working, episode: "01", shot: "镜头1", selection: "选用", createdAt: .now, subjectID: "P-01", variantID: variant.id, shotID: "shot1", boundFingerprint: a.sha256, originalPrompt: a.originalPrompt)
        var second = first; second.id = "use2"; second.shot = "镜头2"; second.shotID = "shot2"
        try await materials.commitUsage(first); try await materials.commitUsage(second)
        try graph.setDefault(b.id)
        try ProjectAssetGraph.save(graph, root: root, expected: read.1, characterIDs: ["P-01"])
        try check(materials.links.filter { $0.materialID == old.id }.count == 2, "new default leaves both old shots unchanged")
        var replacement = first; replacement.materialID = new.id; replacement.boundFingerprint = b.sha256
        try await materials.commitUsage(replacement)
        try check(materials.links.first { $0.id == second.id }?.materialID == old.id && materials.links.first { $0.id == first.id }?.previousVersions?.first?.materialID == old.id, "selected shot changes with history; other stays old")
        let exported = try MaterialDelivery.export(materials: materials.materials, links: materials.links, projectID: id, destination: root)
        let manifest = try String(contentsOf: exported.appendingPathComponent("生产素材清单.csv"), encoding: .utf8)
        try check(manifest.contains(a.sha256) && manifest.contains(b.sha256) && manifest.contains(receipt.originalPrompt) && manifest.contains("主体ID"), "exact bound versions and prompts exported")
        let snapshot = try await MaterialDatabase(root: libraryRoot).load()
        try check(snapshot.links.first { $0.id == first.id }?.previousVersions?.count == 1, "history survives SQLite reopen")
        // Source conflicts preserve both old bytes and caller draft; owned block preserves outside content.
        read = try ProjectAssetGraph.read(root: root, projectID: id)
        let graphURL = ProjectAssetGraph.url(root: root)
        let graphText = try CharacterMarkdown.read(graphURL).0
        try Data(("外部前文\n" + graphText + "\n外部后文").utf8).write(to: graphURL)
        do { try ProjectAssetGraph.save(graph, root: root, expected: read.1, characterIDs: ["P-01"]); throw CharacterLibraryError.invalid("FAIL: overwrote external edit") } catch CharacterLibraryError.conflict { }
        read = try ProjectAssetGraph.read(root: root, projectID: id)
        try ProjectAssetGraph.save(graph, root: root, expected: read.1, characterIDs: ["P-01"])
        let preserved = try CharacterMarkdown.read(graphURL).0
        try check(preserved.hasPrefix("外部前文") && preserved.hasSuffix("外部后文"), "unknown sections preserved")
        let backupDir = graphURL.deletingLastPathComponent().appendingPathComponent(".assetframe-character-backups")
        try check(!(try fm.contentsOfDirectory(atPath: backupDir.path)).isEmpty, "recoverable backup exists")
        try Data("changed".utf8).write(to: oldURL)
        var reconfirm = graph; reconfirm.assets[0].evidence = "保存时必须重新校验文件"
        let beforeFailedSave = try Data(contentsOf: graphURL)
        do {
            try ProjectAssetGraph.save(reconfirm, root: root, expected: CharacterMarkdown.fingerprint(beforeFailedSave), characterIDs: ["P-01"])
            throw CharacterLibraryError.invalid("FAIL: saved confirmation for changed file")
        } catch { try check(!error.localizedDescription.contains("FAIL:"), "confirmation rechecked at save") }
        try check(try Data(contentsOf: graphURL) == beforeFailedSave, "failed confirmation leaves graph untouched")
        await characters.refreshSources()
        try check(characters.loaded[0].unavailableAssetIDs.contains(old.id), "overwritten confirmation blocked")
        do { _ = try MaterialDelivery.export(materials: materials.materials, links: materials.links, projectID: id, destination: root); throw CharacterLibraryError.invalid("FAIL: exported changed file") } catch { try check(!error.localizedDescription.contains("FAIL:"), "changed bound file blocked") }
        let reopened = CharacterLibraryStore(root: libraryRoot)
        reopened.materialPaths = characters.materialPaths; await reopened.refreshSources()
        try check(reopened.registry.entries.count == 1 && reopened.intake.analyses.count == 1, "restart preserves source registration and candidate cache")
        print("ProjectWorkflowIntegrationSelfTest passed: direct standard intake, receipt inheritance, idempotence, historical links, identity-safe rename, cache/context invalidation, retirement precedence, variants/default uniqueness, pinned shots, selected replacement history, exact export, SQLite reopen, conflicts/backups, changed-file blocking")
    }
}
