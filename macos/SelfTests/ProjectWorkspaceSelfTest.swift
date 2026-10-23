import Foundation

private actor Calls {
    var count = 0
    func extract(_ doc: CharacterProjectDocument, _ target: ProjectAutomationState.Target?) -> ProjectAutomationState.Extraction {
        count += 1
        return .init(name: target?.name ?? "未知", kind: target?.kind ?? "其他", fields: [.init(name: "资料", value: doc.text, evidence: doc.text)], conflict: "")
    }
}
@main struct ProjectWorkspaceSelfTest {
    static func check(_ value: Bool, _ message: String) throws { if !value { throw CharacterLibraryError.invalid("FAIL: " + message) } }
    @MainActor static func main() async throws {
        if ProcessInfo.processInfo.environment["ASSETFRAME_LIVE_WORKSPACE"] == "1" {
            let saved = UserDefaults.standard.persistentDomain(forName: "com.yidiandian.assetframe") ?? [:]
            UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
            guard ProcessInfo.processInfo.environment["ASSETFRAME_TEST_CONFIGURATION_STDIN"] == "1" else {
                throw CharacterLibraryError.invalid("临时测试程序不再访问生产钥匙串；真实连接请在已授权的候选 App 中验证。")
            }
            struct TestConnection: Decodable { var baseURL: String; var model: String; var apiKey: String }
            let input = try JSONDecoder().decode(TestConnection.self, from: FileHandle.standardInput.readDataToEndOfFile())
            let config = DeepSeekConfiguration(baseURL: input.baseURL, model: input.model, apiKey: input.apiKey)
            let text = "合成测试人物阿青，P-TEST。性格谨慎，穿蓝色粗布衣。"
            let doc = CharacterProjectDocument(path: "synthetic.md", text: text, fingerprint: CharacterMarkdown.fingerprint(Data(text.utf8)), kind: "人物档案", name: "阿青", evidence: "", warning: "")
            let result = try await ProjectAutomationClient.analyze(document: doc, target: .init(id: "P-TEST", kind: "人物", name: "阿青"), configuration: config)
            try check(!result.fields.isEmpty, "live extraction returned fields")
            print("LIVE PASS: configured fast model=\(config.model), synthetic evidence-backed fields=\(result.fields.count)")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project"), lib = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("人物"), withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: project.appendingPathComponent(path)) }
        try write("人物/人物接口.md", "| P-01 甲 | [资料](甲.md) |\n| P-02 乙 | [资料](乙.md) |")
        try write("人物/甲.md", "甲的人物性格：谨慎。")
        try write("人物/乙.md", "乙的人物性格：乐观。")
        let material = GlobalMaterialStore(rootURL: lib); await material.waitUntilReady()
        let calls = Calls()
        let config = DeepSeekConfiguration(baseURL: "http://localhost:9999", model: "test-fast", apiKey: "synthetic")
        var credentialReads = 0
        let service = ProjectAutomationService(root: lib, materials: material, configuration: { credentialReads += 1; return config }, analyzer: { doc, target, _ in await calls.extract(doc, target) })
        _ = try service.library.addProject(name: "测试", root: project, existingID: "test")
        service.enable("test", enabled: true); await service.waitUntilIdle()
        let count = await calls.count
        try check(count >= 4, "all people grouped without manual selection")
        try check(service.jobs(project: "test").contains { $0.target?.id == "P-02" && $0.result != nil }, "second person shown")
        try check(service.jobs(project: "test").filter { $0.target?.id == "P-02" }.allSatisfy { $0.status == "待核对" }, "both conflicting sources require review")
        let derived = "original\n<!-- assetframe-organized-evidence:v1 -->generated<!-- /assetframe-organized-evidence -->"
        try check(!ProjectAutomationClient.originalSource(derived).contains("generated"), "derived writeback excluded from AI source")
        let readsBeforeRefresh = credentialReads
        service.refresh(); await service.waitUntilIdle()
        try check(credentialReads == readsBeforeRefresh, "unchanged completed project does not access credentials")
        try check(await calls.count == count, "unchanged sources make no AI call")
        service.navigate(project: "test", section: "人物", selection: "P-02"); service.setSearch("乙")
        service.stop()
        let restored = ProjectAutomationService(root: lib, materials: material, configuration: { config }, analyzer: { doc, target, _ in await calls.extract(doc, target) })
        restored.refresh(); await restored.waitUntilIdle()
        try check(await calls.count == count, "restart reuses completed work")
        try check(restored.state.navigation.selectedID == "P-02" && restored.state.navigation.search == "乙", "navigation restored")
        try write("人物/甲.md", "甲的人物性格：谨慎且务实。")
        restored.refresh(); await restored.waitUntilIdle()
        try check(await calls.count == count + 1, "only changed source reprocessed")
        try write("00_先读我.md", "# 项目入口\n[人物](人物/人物接口.md)")
        restored.refresh(); await restored.waitUntilIdle()
        try check(await calls.count > count + 1, "navigation context invalidates dependent work")
        let afterContext = await calls.count
        restored.enable("test", enabled: false); await restored.waitUntilIdle()
        try write("人物/甲.md", "甲的人物性格：谨慎且务实，已改变。")
        restored.refresh(); await restored.waitUntilIdle()
        try check(await calls.count == afterContext, "pause prevents requests")
        try check(restored.jobs(project: "test").contains { $0.status == "待整理" }, "scan does not mark pending work completed")
        restored.stop()
        let changedDestination = ProjectAutomationService(root: lib, materials: material, configuration: { .init(baseURL: "http://localhost:9998", model: "fast", apiKey: "test") }, analyzer: { doc, target, _ in await calls.extract(doc, target) })
        // Existing destination permission remains paused; explicitly enable only original endpoint in stored state.
        var intake = changedDestination.library.intake
        intake.automation?.permissions["test"] = .init(enabled: true, endpoint: config.baseURL)
        try changedDestination.library.saveIntake(intake)
        let guarded = ProjectAutomationService(root: lib, materials: material, configuration: { .init(baseURL: "http://localhost:9998", model: "fast", apiKey: "test") }, analyzer: { doc, target, _ in await calls.extract(doc, target) })
        guarded.refresh(); await guarded.waitUntilIdle()
        try check(await calls.count == afterContext && guarded.error?.contains("地址已改变") == true, "destination changes pause sending")
        var state = ProjectAutomationState()
        state.jobs["x"] = .init(id: "x", projectID: "test", path: "x", fingerprint: "f", context: "c", status: "整理中")
        state.recoverInterrupted(); try check(state.jobs["x"]?.status == "待重试", "interrupted request explicitly requires retry")
        let legacy = Data("{\"version\":1,\"projects\":{},\"analyses\":{}}".utf8)
        try check(try JSONDecoder().decode(ProjectIntake.self, from: legacy).automation == nil, "legacy intake loads with automation off")
        try check(!DeepSeekTaskKind.characterOrganization.usesDeepModel, "fast model routing")
        let bad = "{\"name\":\"甲\",\"kind\":\"人物\",\"fields\":[{\"name\":\"性格\",\"value\":\"虚构\",\"evidence\":\"不存在\"}],\"conflict\":\"\"}"
        do { _ = try ProjectAutomationClient.decode(bad, source: "真实", target: nil); throw CharacterLibraryError.invalid("FAIL: ungrounded result accepted") } catch DeepSeekClientError.invalidJSON {}
        print("ProjectWorkspaceSelfTest passed: automatic multi-person routing, no repeated requests, restart/navigation, changed source/context, pause/destination guard, legacy migration, interrupted recovery, evidence and fast model")
    }
}
