import Foundation

@main
struct CharacterMaterialIntegrationSelfTest {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("assetframe-character-integration-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("主图.png")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try bytes.write(to: source)
        let libraryRoot = root.appendingPathComponent("library")
        let materials = GlobalMaterialStore(rootURL: libraryRoot)
        await materials.waitUntilReady()
        materials.importFiles([source]); await materials.waitForImportCompletion(); await materials.waitForBackgroundMetadata()
        try await materials.saveNow().get()
        guard let item = materials.materials.first else { throw CharacterLibraryError.invalid("fixture import failed") }
        let before = materials.materials
        let characters = CharacterLibraryStore(root: libraryRoot)
        let projectID = try characters.addProject(name: "作品A", root: root)
        var profile = CharacterProfile(projectID: projectID, characterID: "P-01")
        profile.fields["姓名"] = .init(text: "测试人物", review: .confirmed)
        profile.assets = [.init(materialID: item.id, role: "主图", status: "已确认", defaultUse: "基础主图")]
        let md = root.appendingPathComponent("人物.md")
        try Data(CharacterMarkdown.render(profile, replacing: "# 既有说明\n历史段落不改。\n").utf8).write(to: md)
        _ = try characters.attach(md, projectID: projectID, characterID: "P-01")
        await characters.refresh()
        guard let loaded = characters.loaded.first, let asset = loaded.profile?.assets.first else { throw CharacterLibraryError.invalid("character relation missing") }
        precondition(asset.materialID == item.id && materials.materials == before)
        let usage = ProjectMaterialLink(id: UUID().uuidString, projectID: projectID, materialID: asset.materialID, use: .working,
            episode: "07", scene: "医馆", shot: "01", selection: "选用", createdAt: .now, note: "人物库引用")
        try await materials.commitUsage(usage)
        let delivery = try await materials.libraryDeliverySnapshot(projectID: projectID)
        precondition(delivery.links.contains { $0.materialID == item.id && $0.episode == "07" && $0.selection == "选用" })
        precondition(materials.materials == before, "Character selection must not change rating, material metadata or source")
        let output = try MaterialDelivery.export(materials: delivery.materials, links: delivery.links, projectID: projectID, destination: root)
        let manifest = try String(contentsOf: output.appendingPathComponent("生产素材清单.csv"), encoding: .utf8)
        precondition(manifest.contains(item.id) && manifest.contains("07"))
        let files = fm.enumerator(at: output, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        let exported = files.first { $0.pathExtension == "png" }!
        let exportedBytes = try Data(contentsOf: exported)
        precondition(exportedBytes == bytes)
        profile.fields["图片提示词"] = .init(text: "保留身份特征", review: .candidate)
        let saved = await characters.save(profile: profile, loaded: loaded)
        precondition(saved && materials.materials == before && materials.links.contains { $0.id == usage.id })
        let database = MaterialDatabase(root: libraryRoot)
        let snapshot = try await database.load()
        precondition(snapshot.materials == before && snapshot.links.contains { $0.id == usage.id })
        await characters.refresh()
        let confirmationBase = characters.loaded.first!
        let index = try CharacterProjectModules.readIndex(root: root, projectID: projectID)
        let receipt = CharacterProjectModules.Receipt(projectID: projectID, characterID: "P-01", assetPath: source.lastPathComponent, sha256: try CharacterProjectModules.fileHash(source), materialID: item.id, variant: "基础", role: "主图", stage: "开局", confirmationEvidence: "隔离测试：已查看并确认", platform: "测试平台", model: "", originalPrompt: "实际提示词 --ar 9:16", normalizedPrompt: ["固定特征": "保留身份特征"], profilePath: md.lastPathComponent, sourcePaths: [])
        let receiptURL = try await CharacterModuleWorkflow.confirm(receipt: receipt, root: root, loaded: confirmationBase, library: characters, index: index.0, indexHash: index.1)
        let confirmed = characters.loaded.first!.profile!
        precondition(confirmed.assets.count == 1 && confirmed.assets[0].status == "已确认" && confirmed.assets[0].stage == "开局")
        precondition(confirmed.sources.contains(receiptURL.path) && confirmed.fields["图片提示词"]?.text == "保留身份特征")
        let resultIndex = try CharacterProjectModules.readIndex(root: root, projectID: projectID)
        precondition(resultIndex.0.references.count == 2 && materials.materials == before)
        // Restart and repeat the same receipt: no duplicate assets or index references.
        let reopenedCharacters = CharacterLibraryStore(root: libraryRoot); await reopenedCharacters.refresh()
        _ = try await CharacterModuleWorkflow.confirm(receipt: receipt, root: root, loaded: reopenedCharacters.loaded.first!, library: reopenedCharacters, index: resultIndex.0, indexHash: resultIndex.1)
        let secondIndex = try CharacterProjectModules.readIndex(root: root, projectID: projectID)
        precondition(secondIndex.0.references.count == 2 && reopenedCharacters.loaded.first!.profile!.assets.count == 1)
        let stale = reopenedCharacters.loaded.first!
        try Data((stale.text + "外部编辑\n").utf8).write(to: md)
        do {
            _ = try await CharacterModuleWorkflow.confirm(receipt: receipt, root: root, loaded: stale, library: reopenedCharacters, index: secondIndex.0, indexHash: secondIndex.1)
            fatalError("must reject external profile changes")
        } catch { }
        precondition(materials.materials == before)
        print("Character confirmation integration passed: exact prompt receipt → profile linkage → index → restart → repeat without duplicate → concurrent edit rejection; material ratings unchanged")
        print("CharacterMaterialIntegrationSelfTest passed: import → character fixed-ID relation → project selection → actual original-file delivery → Markdown save → SQLite reopen; materials and ratings unchanged")
    }
}
