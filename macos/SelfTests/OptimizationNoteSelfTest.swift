import Foundation

@main
struct OptimizationNoteSelfTest {
    static func main() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "version": "V260714",
          "projectID": "legacy-project",
          "projectName": "旧项目",
          "viewName": "图片画册",
          "region": { "x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4 },
          "note": "旧版没有状态字段",
          "createdAt": "2026-07-14T00:00:00Z"
        }
        """

        let legacy = try decoder.decode(OptimizationNote.self, from: Data(legacyJSON.utf8))
        precondition(legacy.effectiveStatus == .pending, "旧建议应兼容为待评估")

        var updated = legacy
        updated.status = .completed
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let roundTripped = try decoder.decode(OptimizationNote.self, from: encoder.encode(updated))
        precondition(roundTripped.effectiveStatus == .completed, "新状态应可持久化")

        print("OptimizationNoteSelfTest passed")
    }
}
