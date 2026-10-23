import Foundation

@main struct ProjectWorkspaceReal35Test {
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw CharacterLibraryError.invalid(message) } }
    @MainActor static func main() async throws {
        guard ProcessInfo.processInfo.environment["ASSETFRAME_REAL35"] == "1" else { return }
        let source = URL(fileURLWithPath: "/Users/zheng/Library/Mobile Documents/iCloud~md~obsidian/Documents/Codex工作区/01_进行中内容项目/01_短剧IP/种田剧情（古代）/财源广进")
        let fixture = URL(fileURLWithPath: "/tmp/assetframe-35-real-project-test")
        let scan = try CharacterProjectScanner.scan(root: source)
        let inventory = CharacterWorkflowBridge.inventory(documents: scan.documents, root: source, projectID: "real35")
        print("READONLY full source: documents=\(scan.documents.count), identifiedPeople=\(inventory.people.count), warnings=\(scan.warnings.count)")
        try require(inventory.people.first { $0.id == "CH-001" }?.name == "陈守业", "男主身份未正确识别")
        try require(inventory.people.first { $0.id == "CH-005" }?.name == "陈宜荷", "长女身份未正确识别")
        try require(!inventory.people.contains { $0.id == "CH-006" || $0.id == "CH-008" }, "停用人物不应作为当前人物识别")
        try require(inventory.people.first { $0.id == "CH-009" }?.name == "陈宜糯", "双列表格姓名未正确识别")
        let saved = UserDefaults.standard.persistentDomain(forName: "com.yidiandian.assetframe") ?? [:]
        UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
        guard ProcessInfo.processInfo.environment["ASSETFRAME_TEST_CONFIGURATION_STDIN"] == "1" else {
                throw CharacterLibraryError.invalid("临时测试程序不再访问生产钥匙串；真实连接请在已授权的候选 App 中验证。")
            }
            struct TestConnection: Decodable { var baseURL: String; var model: String; var apiKey: String }
            let input = try JSONDecoder().decode(TestConnection.self, from: FileHandle.standardInput.readDataToEndOfFile())
            let config = DeepSeekConfiguration(baseURL: input.baseURL, model: input.model, apiKey: input.apiKey)
        let lib = URL(fileURLWithPath: "/tmp/assetframe-35-real-library")
        let material = GlobalMaterialStore(rootURL: lib); await material.waitUntilReady()
        let service = ProjectAutomationService(root: lib, materials: material, configuration: { config })
        _ = try service.library.addProject(name: "35岁项目真实资料测试", root: fixture, existingID: "real35")
        service.enable("real35", enabled: true); await service.waitUntilIdle()
        if service.state.haltReason != nil || service.jobs(project: "real35").contains(where: { $0.status == "失败" }) { service.retry(); await service.waitUntilIdle() }
        let jobs = service.jobs(project: "real35")
        try require(jobs.contains { $0.target?.id == "CH-001" && $0.result != nil }, "男主真实 AI 整理未完成：" + (service.error ?? ""))
        try require(jobs.contains { $0.target?.id == "CH-005" && $0.result != nil }, "长女真实 AI 整理未完成")
        try require(jobs.filter { $0.path.contains("CH-006.md") || $0.path.contains("CH-008.md") }.allSatisfy { $0.result == nil && $0.status == "待核对" }, "停用卡不得自动送 AI")
        let before = service.state.jobs
        service.refresh(); await service.waitUntilIdle()
        try require(service.state.jobs.count == before.count, "重复刷新产生重复任务")
        try require(!service.jobs(project: "real35").contains { $0.status == "待整理" || $0.status == "整理中" }, "仍有待处理任务")
        let resources = service.resources["real35"] ?? []
        try require(resources.contains { $0.id == "AI-001-IMAGE" && $0.status == "文件失联" }, "待恢复素材未标为失联")
        let childResource = resources.first { $0.id == "CH-009-IMAGE" }
        let childExists = childResource.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        try require(childResource?.expectedHash == nil && childResource?.status == (childExists ? "缺少原始指纹" : "文件失联"), "缺失文件或指纹未准确显示")
        service.navigate(project: "real35", section: "人物", selection: "CH-005"); service.stop()
        let restored = ProjectAutomationService(root: lib, materials: material, configuration: { config })
        restored.refresh(); await restored.waitUntilIdle()
        try require(restored.state.navigation.selectedID == "CH-005", "重启未保留人物选择")
        try require(restored.state.jobs.count == before.count, "重启重建重复任务")
        let result: [String: Any] = ["passed": true, "scope": "11份代表资料的真实整理；完整项目只读扫描", "model": config.model,
            "fullScanDocuments": scan.documents.count, "fullScanPeople": inventory.people.count,
            "jobCount": jobs.count, "results": jobs.filter { $0.result != nil }.count,
            "review": jobs.filter { $0.status == "待核对" }.count,
            "resources": resources.map { ["id": $0.id, "status": $0.status] }]
        let out = fixture.deletingLastPathComponent().appendingPathComponent("assetframe-real35-result.json")
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: out)
        print("REAL35 PASS: fastModel=\(config.model), jobs=\(jobs.count), evidenceResults=\(jobs.filter { $0.result != nil }.count), resources=\(resources.count), restart/idempotence/retired/missing verified")
        restored.stop()
    }
}
