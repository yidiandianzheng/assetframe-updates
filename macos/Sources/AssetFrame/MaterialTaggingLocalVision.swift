import Foundation
import Vision

/// Asset tagging can retain useful document/classifier results when OCR is unavailable.
/// The older story-workbench analysis path keeps its existing all-or-nothing behavior.
enum MaterialTaggingLocalVision {
    struct Result: Sendable {
        var tags: [String] = []
        var evidence: [MaterialTaggingState.Evidence] = []
        var warnings: [String] = []
    }
    static func analyze(_ record: MaterialRecord) throws -> Result {
        try Task.checkCancellation()
        let source = try MaterialAnalysisSource.capture(record)
        guard record.kind == .image else { throw VisionAPIClientError.unreadableImage }
        // Unsupported file formats remain explicit failures instead of successful empty labels.
        let prepared = try VisionImagePreprocessor.prepare(atPath: source.path)
        var output = Result()
        do {
            let request = VNClassifyImageRequest()
            try MaterialVisionExecution.perform([request], data: prepared.data)
            let labels = (request.results ?? []).filter { $0.confidence >= 0.35 }.prefix(8)
            output.tags += labels.map(\.identifier)
            output.evidence.append(.init(kind: "本机图像分类", excerpt: labels.map { "\($0.identifier)（\(String(format: "%.2f", $0.confidence))）" }.joined(separator: "、")))
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            let ns = error as NSError
            output.warnings.append("图像分类未完成：\(ns.domain)（\(ns.code)）· \(ns.localizedDescription)")
        }
        try Task.checkCancellation()
        do {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            try MaterialVisionExecution.perform([request], data: prepared.data)
            let words = (request.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.5 }.prefix(6).map { String($0.string.prefix(40)) }
            output.tags += words
            output.evidence.append(.init(kind: "本机文字识别", excerpt: words.isEmpty ? "本次未识别到达到阈值的文字" : words.joined(separator: "、")))
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            let ns = error as NSError
            output.warnings.append("文字识别未完成：\(ns.domain)（\(ns.code)）· \(ns.localizedDescription)")
        }
        try Task.checkCancellation()
        guard try MaterialAnalysisSource.capture(record) == source else { throw CocoaError(.fileReadUnknown) }
        output.tags = Array(Set(output.tags)).sorted()
        return output
    }
}
