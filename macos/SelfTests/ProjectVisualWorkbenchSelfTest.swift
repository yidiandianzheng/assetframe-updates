import Foundation
import AVFoundation

@main struct ProjectVisualWorkbenchSelfTest {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CharacterLibraryError.invalid("FAIL: " + message) }
    }
    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data(("TEST FAILURE: " + String(describing: error) + "\n").utf8))
            exit(1)
        }
    }
    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visual-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func doc(_ path: String, _ text: String, _ kind: String) -> CharacterProjectDocument {
            .init(path: path, text: text, fingerprint: CharacterMarkdown.fingerprint(Data(text.utf8)), kind: kind, name: "", evidence: "", warning: "")
        }
        let card = doc("人物/甲.md", "---\ncharacter_id: CH-001\ndocument_type: 人物角色卡\n---\n| 姓名 | ✅ | 阿甲 |\n| 穿越后原身身高 | ✅ | 178cm |\n", "人物档案")
        let outfit = doc("服装/形态.md", "---\nasset_id: CH-001-MODERN\ncharacter_source: ../人物/甲.md\nasset_name: 现代服装\n---\n![主图](a.png)", "资产说明")
        let other = doc("服装/同名.md", "# 阿甲\n![别人的图](wrong.png)", "资产说明")
        let episode = doc("短剧生产/分集/EP-002/生产卡.md", "状态：候选。\n[小说第2章](../../../正文/第002章.md)\nCH-001", "剧集索引")
        let chapter = doc("正文/第002章.md", "# 第二章\nCH-001", "剧情正文")
        let result = ProjectWorkbenchIndex.build(projectID: "test", root: root, documents: [card,outfit,other,episode,chapter], people: [], graph: .init(projectID: "test"), resources: [], materials: [], links: [], jobs: [])
        let person = try result.subjects.first.unwrap("subject exists")
        try check(person.facts.first { $0.label == "身高" }?.value == "178cm", "height from original table")
        try check(person.facts.first { $0.label == "体重" } == nil, "missing weight stays unknown")
        try check(person.media.count == 1 && person.media[0].variant == "现代服装", "explicit character link groups variant, name match does not")
        try check(!person.media[0].exists && !person.media[0].status.contains("已确认"), "missing image never confirmed")
        try check(result.episodes.count == 1 && result.episodes[0].id == "EP-002", "novel chapter not duplicated as episode")
        try check(result.episodes[0].paths.contains(chapter.path) && result.episodes[0].subjectIDs.contains("CH-001"), "episode follows explicit original links")
        var existingGraph = ProjectAssetGraph(projectID: "test")
        existingGraph.subjects = [.init(id: "CH-001", kind: "人物", name: "阿甲", sourcePath: "版本/人物.md")]
        let merged = ProjectWorkbenchIndex.build(projectID: "test", root: root, documents: [card,outfit], people: [], graph: existingGraph, resources: [], materials: [], links: [], jobs: [])
        let mergedPerson = try merged.subjects.first.unwrap("existing graph subject")
        try check(mergedPerson.sources.contains(card.path) && mergedPerson.sources.contains("版本/人物.md"), "graph preserves original Markdown sources")
        try check(mergedPerson.media.count == 1 && mergedPerson.facts.contains { $0.label == "身高" }, "graph preserves outfit image and character facts")
        let promptDocument = doc("服装/提示词.md", "# 复用提示词\n通用模板，不是生成原文\n![目标图片](a.png)", "生成提示词")
        let similarlyNamed = doc("服装/wrong提示词.md", "# 提示词\n![别图](wrong.png)", "生成提示词")
        let withPrompts = ProjectWorkbenchIndex.build(projectID: "test", root: root, documents: [card, outfit, promptDocument, similarlyNamed], people: [], graph: .init(projectID: "test"), resources: [], materials: [], links: [], jobs: [])
        let linkedPerson = try withPrompts.subjects.first.unwrap("linked person")
        let linkedImage = try linkedPerson.media.first.unwrap("linked image")
        try check(linkedPerson.introductionPaths == [card.path], "original role MD linked as introduction")
        try check(linkedImage.promptSources == [promptDocument.path] && linkedImage.prompt.isEmpty, "exact image prompt document linked without fabricating original prompt")
        try check(withPrompts.imageContexts[root.appendingPathComponent("服装/a.png").path]?.introductionPaths == [card.path], "physical image browser shares original introduction link")
        try check(ProjectImageResolution.read(path: root.appendingPathComponent("missing.png").path) == nil, "missing image resolution stays unknown")
        let oldNavigation = Data("{\"projectID\":\"p\",\"section\":\"人物\",\"search\":\"\",\"selectedID\":\"\"}".utf8)
        try check(try JSONDecoder().decode(ProjectAutomationState.Navigation.self, from: oldNavigation).episodeID == nil, "navigation migration")
        let oldProject = try JSONDecoder().decode(CharacterLibraryRegistry.Project.self, from: Data("{\"id\":\"old\",\"name\":\"旧项目\",\"rootPath\":\"/old/root\"}".utf8))
        try check(oldProject.sources.count == 1 && oldProject.sources[0].path == "/old/root", "old single-root projects migrate without rebuilding identity")
        let multiLibrary = root.appendingPathComponent("multi-library")
        let multiStore = GlobalMaterialStore(rootURL: multiLibrary); await multiStore.waitUntilReady()
        var multiCredentialCalls = 0
        let multiService = ProjectAutomationService(root: multiLibrary, materials: multiStore, eventMonitoring: false, configuration: { multiCredentialCalls += 1; throw CharacterLibraryError.invalid("unexpected multi-source API read") })
        try multiService.register(name: "多目录项目", roots: [], id: nil, automatic: false)
        await multiService.waitUntilIdle()
        let multiID = multiService.state.navigation.projectID
        let a = root.appendingPathComponent("剧本资料"), b = root.appendingPathComponent("视觉资产")
        for base in [a,b] { try FileManager.default.createDirectory(at: base.appendingPathComponent("人物"), withIntermediateDirectories: true) }
        try Data("---\ncharacter_id: CH-901\ndocument_type: 人物角色卡\n---\n| 姓名 | 甲 |\n![图片](a.png)\n[补充](补充.md)".utf8).write(to: a.appendingPathComponent("人物/同名.md"))
        try Data("# 人物补充资料\n性格：沉稳".utf8).write(to: a.appendingPathComponent("人物/补充.md"))
        try Data("---\ncharacter_id: CH-902\ndocument_type: 人物角色卡\n---\n| 姓名 | 乙 |\n![图片](b.png)".utf8).write(to: b.appendingPathComponent("人物/同名.md"))
        try Data("synthetic image placeholder".utf8).write(to: b.appendingPathComponent("人物/b.png"))
        try FileManager.default.createDirectory(at: b.appendingPathComponent(".media/声音"), withIntermediateDirectories: true)
        try Data("unclassified file".utf8).write(to: b.appendingPathComponent(".media/声音/raw.wav"))
        try multiService.linkSources([a,b,a], projectID: multiID); await multiService.waitUntilIdle()
        let multiProject = try multiService.library.registry.projects.first.unwrap("multi project")
        try check(multiProject.sources.count == 2, "duplicate linked roots are reused")
        let multiIndex = try multiService.workbenches[multiID].unwrap("multi workbench")
        try check(multiIndex.documents.filter { $0.path.hasSuffix("同名.md") }.count == 2, "same filename in different roots never collides")
        try check(multiIndex.subjects.contains { $0.id == "CH-901" } && multiIndex.subjects.contains { $0.id == "CH-902" }, "both roots identify their characters")
        try check(multiIndex.subjects.first { $0.id == "CH-902" }?.media.first?.material.sourcePath == b.appendingPathComponent("人物/b.png").path, "secondary-root image resolves beside its own Markdown")
        let secondaryDoc = try multiIndex.documents.first(where: { $0.path == a.appendingPathComponent("人物/同名.md").path }).unwrap("absolute source doc")
        try check(CharacterProjectScanner.markdownLinks(secondaryDoc, root: URL(fileURLWithPath: multiProject.rootPath)).contains(a.appendingPathComponent("人物/补充.md").path), "secondary-root Markdown links keep their original directory")
        try check(multiIndex.fileIndex.roots.count == 2 && multiIndex.fileIndex.files.contains { $0.path.hasSuffix(".media/声音/raw.wav") }, "folder tree and unclassified raw media stay visible")
        multiService.selectSourceFolder(b.path)
        let restarted = ProjectAutomationService(root: multiLibrary, materials: multiStore, eventMonitoring: false)
        try check(restarted.library.registry.projects.first?.sources == multiProject.sources && restarted.state.navigation.sourceFolder == b.path, "linked roots and selected folder survive restart")
        let manualMD = root.appendingPathComponent("手动关联.md")
        let manualText = "# 合成查阅资料\n仅用于链接测试"
        try Data(manualText.utf8).write(to: manualMD)
        let targetImage = b.appendingPathComponent("人物/b.png").path
        multiService.linkAssetDocument(manualMD, projectID: multiID, target: targetImage, kind: "生成提示词"); await multiService.waitUntilIdle()
        multiService.linkAssetDocument(manualMD, projectID: multiID, target: b.appendingPathComponent("人物/../人物/b.png").path, kind: "生成提示词"); await multiService.waitUntilIdle()
        multiService.linkAssetDocument(manualMD, projectID: multiID, target: "CH-902", kind: "人物介绍"); await multiService.waitUntilIdle()
        let linkRestart = ProjectAutomationService(root: multiLibrary, materials: multiStore, eventMonitoring: false)
        try check(linkRestart.assetDocumentPaths(projectID: multiID, target: targetImage, kind: "生成提示词") == [manualMD.path], "manual prompt links persist and canonical targets deduplicate")
        try check(linkRestart.assetDocumentPaths(projectID: "another", target: targetImage, kind: "生成提示词").isEmpty && linkRestart.assetDocumentPaths(projectID: multiID, target: "other-image", kind: "生成提示词").isEmpty, "manual links isolated by project and exact image")
        try check(multiService.workbenches[multiID]?.subjects.first { $0.id == "CH-902" }?.introductionPaths.contains(manualMD.path) == true, "manual introduction merged into subject")
        try check(multiService.workbenches[multiID]?.imageContexts[targetImage]?.media.promptSources.contains(manualMD.path) == true, "manual prompt visible in physical-file context")
        try check(try String(contentsOf: manualMD, encoding: .utf8) == manualText, "association never rewrites Markdown")
        linkRestart.stop()
        let offline = root.appendingPathComponent("暂时离线")
        try FileManager.default.moveItem(at: b, to: offline)
        let partial = try CharacterProjectScanner.scan(project: multiProject, previous: multiIndex.documents)
        let partialFiles = try ProjectSourceFileIndex.build(sources: multiProject.sources, previous: multiIndex.fileIndex)
        if partialFiles.files.count != multiIndex.fileIndex.files.count {
            let diagnostic = "SOURCES: " + multiProject.sources.map(\.path).joined(separator: "\n") + "\nFILES: " + multiIndex.fileIndex.files.map(\.path).joined(separator: "\n") + "\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
        }
        let retainedDocumentCount = partial.documents.count
        let retainedFileCount = partialFiles.files.count
        try check(!partial.warnings.isEmpty, "offline root reports an incomplete read")
        try check(retainedDocumentCount == multiIndex.documents.count && retainedFileCount == multiIndex.fileIndex.files.count, "offline root retains prior documents and file list with warning: docs \(retainedDocumentCount)/\(multiIndex.documents.count), files \(retainedFileCount)/\(multiIndex.fileIndex.files.count)")
        try FileManager.default.moveItem(at: offline, to: b)
        try multiService.unlinkSource(multiProject.sources[1].id, projectID: multiID); await multiService.waitUntilIdle()
        try check(FileManager.default.fileExists(atPath: b.appendingPathComponent("人物/同名.md").path), "unlink never deletes original files")
        try check(multiService.library.registry.projects.first?.sources.count == 1 && multiService.workbenches[multiID]?.documents.contains(where: { $0.path.hasPrefix(b.path + "/") }) == false, "unlinked root stops scanning")
        try check(multiCredentialCalls == 0, "multi-source local reading never requests credentials")
        multiService.stop(); restarted.stop()
        print("MULTISOURCE PASS: migration, empty project, duplicate roots, same filenames, image/MD paths, folder/raw-media tree, offline retention, unlink and restart; no credentials.")
        let source = root.appendingPathComponent("edit.md")
        try Data("original".utf8).write(to: source)
        let hash = try CharacterMarkdown.read(source).1
        let backup = try CharacterMarkdown.save("updated", to: source, expected: hash)
        try check(try String(contentsOf: backup, encoding: .utf8) == "original", "exact original backup")
        do { _ = try CharacterMarkdown.save("stale", to: source, expected: hash); throw CharacterLibraryError.invalid("FAIL: stale overwrite") }
        catch CharacterLibraryError.conflict {}
        try check(try String(contentsOf: source, encoding: .utf8) == "updated", "conflict leaves source intact")
        var graph = ProjectAssetGraph(projectID: "test")
        graph.variants = [.init(id:"look", subjectID:"CH-001", name:"古代")]
        graph.assets = ["old","new"].map { .init(id:$0, subjectID:"CH-001", variantID:"look", materialID:$0, path:$0 + ".png", sha256:String(repeating:"a",count:64), role:"主图", stage:"开篇", status:"已确认", evidence:"synthetic explicit confirmation") }
        let bound = ProjectMaterialLink(id:"shot1", projectID:"test", materialID:"old", use:.reference, episode:"EP-002", createdAt:.now, subjectID:"CH-001")
        try graph.setDefault("new")
        try check(bound.materialID == "old", "default update preserves exact old shot material")
        let fixture = URL(fileURLWithPath: "/tmp/assetframe-35-visual-project-test")
        let prepareQA = ProcessInfo.processInfo.environment["ASSETFRAME_PREPARE_VISUAL_QA"] == "1"
        let library = prepareQA ? URL(fileURLWithPath: "/tmp/assetframe-qa.visual-2610174/35岁图文测试.assetframelibrary") : root.appendingPathComponent("library")
        let store = GlobalMaterialStore(rootURL: library); await store.waitUntilReady()
        var credentialCalls = 0
        let service = ProjectAutomationService(root: library, materials: store, configuration: { credentialCalls += 1; throw CharacterLibraryError.invalid("unexpected API access") })
        _ = try service.library.addProject(name:"35岁图文", root:fixture, existingID:"real35")
        service.refresh(); await service.waitUntilIdle()
        let indexed = try service.workbenches["real35"].unwrap("real project indexed")
        let chen = try indexed.subjects.first(where: { $0.id == "CH-001" }).unwrap("Chen identity")
        try check(chen.images.contains { $0.exists }, "real character images visible")
        try check(chen.introductionPaths.contains("设定/人物/CH-001.md"), "real character introduction MD found")
        try check(chen.images.contains { ($0.material.mediaMetadata?.pixelWidth ?? 0) > 0 && ($0.material.mediaMetadata?.pixelHeight ?? 0) > 0 }, "real image dimensions decoded")
        let actualImage = try chen.images.first(where: { $0.exists }).unwrap("actual image")
        let actualResolution = try ProjectImageResolution.read(path: actualImage.material.sourcePath!).unwrap("real resolution")
        try check(actualResolution.width == actualImage.material.mediaMetadata?.pixelWidth && actualResolution.height == actualImage.material.mediaMetadata?.pixelHeight, "lazy file header resolution matches asset metadata")
        print("ASSET LINKS PASS: original introduction MD, exact prompt references, no fabricated prompt, durable manual links, canonical deduplication, project isolation, unchanged Markdown, actual image dimensions.")
        try check(chen.media.contains { $0.variant.contains("现代") }, "modern form linked via explicit source")
        try check(chen.audio.contains { $0.exists }, "real voice reference linked")
        try check(indexed.episodes.contains { $0.id == "EP-003" }, "third episode indexed")
        try check(indexed.documents.contains { $0.kind == "项目大纲" }, "outline visible")
        let before = indexed.subjects.map(\.id)
        service.refresh(); await service.waitUntilIdle()
        try check(service.workbenches["real35"]?.subjects.map(\.id) == before && credentialCalls == 0, "repeat refresh stable and entirely local")
        service.selectEpisode("EP-002"); service.selectDocument("x.md"); service.selectCategory("人物")
        let draft = ProjectAutomationState.WritebackDraft(id:"real35|x",path:"x",expected:"old",text:"unsaved")
        try check(service.preserveDocument(draft,key:draft.id), "draft persisted")
        service.stop()
        let restored = ProjectAutomationService(root: library, materials: store)
        try check(restored.state.navigation.episodeID == "EP-002" && restored.state.documentDrafts?[draft.id]?.text == "unsaved", "restart restores episode and draft")
        let voice = try chen.audio.first(where: { $0.exists }).unwrap("voice file")
        let duration = try await AVURLAsset(url: URL(fileURLWithPath: voice.material.sourcePath!)).load(.duration)
        try check(duration.seconds > 0, "real voice decodes")
        if prepareQA {
            restored.selectEpisode(nil); restored.selectDocument(""); restored.selectCategory("人物")
            restored.navigate(project: "real35", section: "资产", selection: "CH-001")
            _ = restored.preserveDocument(nil, key: draft.id)
            try await store.pauseSession().get()
        }
        print("PASS: standard fields, explicit image/form association, no name guesses, missing-image state, episode/chapter separation, original links, migration, safe writeback/backup/conflict, fixed version binding, real images/voices, local repeat refresh, restored draft/navigation.")
        print("REAL35: documents=\(indexed.documents.count), subjects=\(indexed.subjects.count), episodes=\(indexed.episodes.count), CH001 images=\(chen.images.count), audio=\(chen.audio.count), voice duration=\(duration.seconds)")
    }
}
private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped { guard let value = self else { throw CharacterLibraryError.invalid(message) }; return value }
}
