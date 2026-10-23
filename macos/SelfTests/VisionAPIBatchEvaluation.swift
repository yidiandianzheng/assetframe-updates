import Foundation

private struct EvaluationItem: Decodable {
    var id: String?
    var imagePath: String
    var expectedType: String?
    var currentType: String?
    var relativePath: String?
    var localVisionLabels: [String]?
    var nameUsable: Bool?
    var tagsUsable: Bool?
    var adopted: Bool?
}

private struct EvaluationResult: Codable {
    var id: String
    var imagePath: String
    var expectedType: String?
    var predictedType: String?
    var proposedName: String?
    var tags: [String]
    var confidence: Double?
    var latencyMilliseconds: Double
    var error: String?
    var nameUsable: Bool?
    var tagsUsable: Bool?
    var adopted: Bool?
}

private struct EvaluationMetrics: Codable {
    var total: Int
    var succeeded: Int
    var failed: Int
    var failureRate: Double
    var averageLatencyMilliseconds: Double
    var typeAccuracy: Double?
    var typeReviewedCount: Int
    var nameUsabilityRate: Double?
    var nameReviewedCount: Int
    var tagUsabilityRate: Double?
    var tagReviewedCount: Int
    var adoptionRate: Double?
    var adoptionReviewedCount: Int
}

private struct EvaluationReport: Codable {
    var generatedAt: Date
    var model: String
    var metrics: EvaluationMetrics
    var results: [EvaluationResult]
}

@main
private enum VisionAPIBatchEvaluation {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifestPath = environment["ASSETFRAME_VISION_EVALUATION_MANIFEST"] else {
            throw NSError(
                domain: "AssetFrame.VisionAPIBatchEvaluation",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "缺少 ASSETFRAME_VISION_EVALUATION_MANIFEST"]
            )
        }
        let manifestURL = URL(fileURLWithPath: manifestPath).standardizedFileURL
        let items = try JSONDecoder().decode([EvaluationItem].self, from: Data(contentsOf: manifestURL))
        guard (1...100).contains(items.count) else {
            throw NSError(
                domain: "AssetFrame.VisionAPIBatchEvaluation",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "评测清单必须包含 1–100 张图片，当前为 \(items.count) 张"]
            )
        }

        if let reviewInputPath = environment["ASSETFRAME_VISION_EVALUATION_REVIEW_INPUT"] {
            try summarizeReviewedResults(
                at: URL(fileURLWithPath: reviewInputPath),
                items: items,
                manifestURL: manifestURL,
                environment: environment
            )
            return
        }

        guard environment["ASSETFRAME_VISION_EVALUATION_ALLOW_COST"] == "1" else {
            throw NSError(
                domain: "AssetFrame.VisionAPIBatchEvaluation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "未授权付费评测。确认费用后设置 ASSETFRAME_VISION_EVALUATION_ALLOW_COST=1"]
            )
        }
        guard let configuration = VisionAPISettings.storedConfiguration() else {
            throw NSError(
                domain: "AssetFrame.VisionAPIBatchEvaluation",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "软件尚未在 Keychain 保存完整视觉 API 配置"]
            )
        }

        let client = OpenAICompatibleVisionClient()
        var results: [EvaluationResult] = []
        results.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            let imageURL = resolvedImageURL(item.imagePath, relativeTo: manifestURL.deletingLastPathComponent())
            let itemID = item.id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "EVAL-\(index + 1)"
            let startedAt = Date()
            do {
                guard FileManager.default.fileExists(atPath: imageURL.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let suggestion = try await client.analyze(
                    input: VisionAnalysisInput(
                        itemID: itemID,
                        imagePath: imageURL.path,
                        filename: imageURL.lastPathComponent,
                        relativePath: item.relativePath ?? imageURL.lastPathComponent,
                        currentType: AssetType(rawValue: item.currentType ?? "") ?? .unclassified,
                        localVisionLabels: item.localVisionLabels ?? []
                    ),
                    configuration: configuration
                )
                results.append(EvaluationResult(
                    id: itemID,
                    imagePath: imageURL.path,
                    expectedType: item.expectedType,
                    predictedType: suggestion.assetType.rawValue,
                    proposedName: suggestion.proposedName,
                    tags: suggestion.normalizedTags,
                    confidence: suggestion.confidence,
                    latencyMilliseconds: Date().timeIntervalSince(startedAt) * 1_000,
                    error: nil,
                    nameUsable: item.nameUsable,
                    tagsUsable: item.tagsUsable,
                    adopted: item.adopted
                ))
            } catch {
                results.append(EvaluationResult(
                    id: itemID,
                    imagePath: imageURL.path,
                    expectedType: item.expectedType,
                    predictedType: nil,
                    proposedName: nil,
                    tags: [],
                    confidence: nil,
                    latencyMilliseconds: Date().timeIntervalSince(startedAt) * 1_000,
                    error: error.localizedDescription,
                    nameUsable: item.nameUsable,
                    tagsUsable: item.tagsUsable,
                    adopted: item.adopted
                ))
            }
            print("[\(index + 1)/\(items.count)] \(imageURL.lastPathComponent)")
        }

        let report = EvaluationReport(
            generatedAt: .now,
            model: configuration.model,
            metrics: metrics(for: results),
            results: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let outputURL = URL(fileURLWithPath: environment["ASSETFRAME_VISION_EVALUATION_OUTPUT"] ?? manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent("vision-api-evaluation-result.json")
            .path)
        try encoder.encode(report).write(to: outputURL, options: .atomic)
        print("视觉 API 评测完成：\(outputURL.path)")
        print("成功 \(report.metrics.succeeded)/\(report.metrics.total)，失败率 \(percentage(report.metrics.failureRate))")
    }

    private static func resolvedImageURL(_ path: String, relativeTo directory: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return directory.appendingPathComponent(path).standardizedFileURL
    }

    private static func summarizeReviewedResults(
        at inputURL: URL,
        items: [EvaluationItem],
        manifestURL: URL,
        environment: [String: String]
    ) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var report = try decoder.decode(EvaluationReport.self, from: Data(contentsOf: inputURL))
        let annotations = Dictionary(uniqueKeysWithValues: items.enumerated().map { index, item in
            let id = item.id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "EVAL-\(index + 1)"
            return (id, item)
        })
        for index in report.results.indices {
            guard let item = annotations[report.results[index].id] else { continue }
            report.results[index].nameUsable = item.nameUsable
            report.results[index].tagsUsable = item.tagsUsable
            report.results[index].adopted = item.adopted
        }
        report.generatedAt = .now
        report.metrics = metrics(for: report.results)
        let outputURL = URL(fileURLWithPath: environment["ASSETFRAME_VISION_EVALUATION_OUTPUT"] ?? manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent("vision-api-evaluation-reviewed.json")
            .path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: outputURL, options: .atomic)
        print("人工复核指标已离线汇总：\(outputURL.path)")
    }

    private static func metrics(for results: [EvaluationResult]) -> EvaluationMetrics {
        let succeeded = results.filter { $0.error == nil }
        let typeReviewed = succeeded.filter { $0.expectedType != nil }
        let nameReviewed = succeeded.compactMap(\.nameUsable)
        let tagReviewed = succeeded.compactMap(\.tagsUsable)
        let adoptionReviewed = succeeded.compactMap(\.adopted)
        return EvaluationMetrics(
            total: results.count,
            succeeded: succeeded.count,
            failed: results.count - succeeded.count,
            failureRate: ratio(results.count - succeeded.count, results.count) ?? 0,
            averageLatencyMilliseconds: results.map(\.latencyMilliseconds).reduce(0, +) / Double(max(1, results.count)),
            typeAccuracy: ratio(typeReviewed.count { $0.expectedType == $0.predictedType }, typeReviewed.count),
            typeReviewedCount: typeReviewed.count,
            nameUsabilityRate: ratio(nameReviewed.count(where: { $0 }), nameReviewed.count),
            nameReviewedCount: nameReviewed.count,
            tagUsabilityRate: ratio(tagReviewed.count(where: { $0 }), tagReviewed.count),
            tagReviewedCount: tagReviewed.count,
            adoptionRate: ratio(adoptionReviewed.count(where: { $0 }), adoptionReviewed.count),
            adoptionReviewedCount: adoptionReviewed.count
        )
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double? {
        denominator == 0 ? nil : Double(numerator) / Double(denominator)
    }

    private static func percentage(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(1)))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
