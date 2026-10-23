import Foundation

private enum MockFeedbackError: Error { case offline }

private actor FlakyFeedbackSender: FeedbackSending {
    private var attempts = 0

    func submit(_ submission: FeedbackSubmissionV1, screenshot: Data?) async throws -> FeedbackServerResponse {
        attempts += 1
        if attempts == 1 { throw MockFeedbackError.offline }
        return FeedbackServerResponse(submissionID: submission.submissionID, receivedAt: Date())
    }

    func attemptCount() -> Int { attempts }
}

@main
@MainActor
struct FeedbackQueueSelfTest {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeedbackQueueSelfTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("optimization-notes.json")
        let draft = OptimizationNoteDraft(
            projectID: "local-project",
            projectName: "本机项目",
            viewName: "全部图片",
            region: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        )

        let localStore = OptimizationNoteStore(fileURL: fileURL)
        localStore.addFeedback(
            draft: draft,
            type: .feature,
            text: "仅本机反馈",
            contact: nil,
            screenshotData: nil,
            includeDiagnostics: false
        )
        precondition(localStore.notes.first?.effectiveSyncState == .localOnly)

        let sender = FlakyFeedbackSender()
        let onlineFileURL = directory.appendingPathComponent("online-notes.json")
        let onlineStore = OptimizationNoteStore(fileURL: onlineFileURL, feedbackSender: sender)
        onlineStore.addFeedback(
            draft: draft,
            type: .bug,
            text: "先失败再重试",
            contact: "tester@example.com",
            screenshotData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            includeDiagnostics: true
        )

        try await waitUntil { onlineStore.notes.first?.effectiveSyncState == .failed }
        guard let failed = onlineStore.notes.first else { preconditionFailure("反馈没有写入本地队列") }
        precondition(failed.retryCount == 1)
        precondition(failed.screenshotFilename != nil, "失败时应保留待重试截图")

        onlineStore.queueForSubmission(failed)
        try await waitUntil { onlineStore.notes.first?.effectiveSyncState == .submitted }
        precondition(onlineStore.notes.first?.screenshotFilename == nil, "提交成功后应删除本机临时截图")
        let attemptCount = await sender.attemptCount()
        precondition(attemptCount == 2, "幂等队列应只执行一次失败和一次人工重试")

        let reloaded = OptimizationNoteStore(fileURL: onlineFileURL)
        precondition(reloaded.notes.first?.effectiveSyncState == .submitted, "同步状态应跨启动持久化")

        print("FeedbackQueueSelfTest passed")
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("等待反馈队列状态超时")
    }
}
