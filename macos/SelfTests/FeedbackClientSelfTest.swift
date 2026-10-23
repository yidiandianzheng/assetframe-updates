import Foundation

@main
struct FeedbackClientSelfTest {
    static func main() throws {
        precondition(OnlineServiceConfiguration.isAllowedServiceURL(URL(string: "https://feedback.example.com/v1/feedback")!))
        precondition(OnlineServiceConfiguration.isAllowedServiceURL(URL(string: "http://127.0.0.1:8787/v1/feedback")!))
        precondition(!OnlineServiceConfiguration.isAllowedServiceURL(URL(string: "http://feedback.example.com/v1/feedback")!))

        let defaults = UserDefaults(suiteName: "FeedbackClientSelfTest-\(UUID().uuidString)")!
        let firstHash = FeedbackIdentity.anonymousInstallIDHash(defaults: defaults)
        let secondHash = FeedbackIdentity.anonymousInstallIDHash(defaults: defaults)
        precondition(firstHash == secondHash && firstHash.count == 64, "匿名安装标识应稳定且只提交哈希")

        let note = OptimizationNote(
            id: UUID(),
            version: "V260719.4",
            projectID: "private-project-id",
            projectName: "不得上传的项目名",
            viewName: "全部图片",
            region: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            note: "右侧详情应完整显示",
            createdAt: Date(timeIntervalSince1970: 1_753_000_000),
            status: .pending,
            feedbackType: .bug,
            contact: "tester@example.com",
            includeDiagnostics: true,
            screenshotFilename: "private-file.jpg",
            submissionID: UUID(),
            syncState: .queued,
            retryCount: 0,
            appShortVersion: "26.7.19",
            buildVersion: "260719.4",
            macOSVersion: "Version 15.5",
            architecture: "arm64",
            anonymousInstallIDHash: firstHash
        )
        let submission = FeedbackSubmissionV1(note: note)
        try submission.validate(screenshotBytes: 12)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payloadText = String(decoding: try encoder.encode(submission), as: UTF8.self)
        precondition(payloadText.contains("\"submissionId\""))
        precondition(payloadText.contains("\"screenId\""))
        precondition(!payloadText.contains("不得上传的项目名"))
        precondition(!payloadText.contains("private-file.jpg"))

        let screenshot = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let body = try FeedbackMultipartBody.make(submission: submission, screenshot: screenshot, boundary: "TEST-BOUNDARY")
        let bodyText = String(decoding: body, as: UTF8.self)
        precondition(bodyText.contains("name=\"payload\""))
        precondition(bodyText.contains("name=\"screenshot\""))
        precondition(bodyText.contains("Content-Type: image/jpeg"))

        print("FeedbackClientSelfTest passed")
    }
}
