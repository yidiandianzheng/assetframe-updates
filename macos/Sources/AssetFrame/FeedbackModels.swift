import CryptoKit
import Foundation

enum FeedbackCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case bug = "故障"
    case experience = "体验优化"
    case feature = "功能建议"
    case other = "其他"

    var id: Self { self }
}

enum FeedbackSyncState: String, Codable, CaseIterable, Sendable {
    case localOnly
    case queued
    case submitting
    case submitted
    case failed

    var displayName: String {
        switch self {
        case .localOnly: "仅保存在本机"
        case .queued: "等待发送"
        case .submitting: "正在发送"
        case .submitted: "已提交"
        case .failed: "发送失败"
        }
    }

    var systemImage: String {
        switch self {
        case .localOnly: "externaldrive"
        case .queued: "clock"
        case .submitting: "arrow.triangle.2.circlepath"
        case .submitted: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

struct FeedbackSubmissionV1: Codable, Sendable {
    static let schemaVersion = 1
    static let maximumMessageLength = 5_000
    static let maximumContactLength = 200
    static let maximumScreenshotBytes = 5 * 1_024 * 1_024

    let schemaVersion: Int
    let submissionID: String
    let type: FeedbackCategory
    let message: String
    let appShortVersion: String
    let buildVersion: String
    let macOSVersion: String?
    let architecture: String?
    let screenID: String
    let region: NormalizedRect
    let anonymousInstallIDHash: String
    let contact: String?
    let diagnosticsIncluded: Bool
    let submittedAt: Date

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case submissionID = "submissionId"
        case type
        case message
        case appShortVersion
        case buildVersion
        case macOSVersion
        case architecture
        case screenID = "screenId"
        case region
        case anonymousInstallIDHash = "anonymousInstallIdHash"
        case contact
        case diagnosticsIncluded
        case submittedAt
    }

    init(note: OptimizationNote) {
        schemaVersion = Self.schemaVersion
        submissionID = (note.submissionID ?? note.id).uuidString
        type = note.feedbackType ?? .experience
        message = note.note
        appShortVersion = note.appShortVersion ?? AppVersion.shortVersion
        buildVersion = note.buildVersion ?? note.version.replacingOccurrences(of: "V", with: "")
        macOSVersion = note.includeDiagnostics == true ? note.macOSVersion : nil
        architecture = note.includeDiagnostics == true ? note.architecture : nil
        screenID = note.viewName
        region = note.region
        anonymousInstallIDHash = note.anonymousInstallIDHash ?? FeedbackIdentity.anonymousInstallIDHash()
        contact = note.contact?.nilIfBlank
        diagnosticsIncluded = note.includeDiagnostics == true
        submittedAt = note.createdAt
    }

    func validate(screenshotBytes: Int?) throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FeedbackValidationError.emptyMessage }
        guard trimmed.count <= Self.maximumMessageLength else { throw FeedbackValidationError.messageTooLong }
        if let contact, contact.count > Self.maximumContactLength { throw FeedbackValidationError.contactTooLong }
        if let screenshotBytes, screenshotBytes > Self.maximumScreenshotBytes {
            throw FeedbackValidationError.screenshotTooLarge
        }
    }
}

struct FeedbackServerResponse: Codable, Sendable {
    let submissionID: String
    let receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case submissionID = "submissionId"
        case receivedAt
    }
}

enum FeedbackValidationError: LocalizedError {
    case emptyMessage
    case messageTooLong
    case contactTooLong
    case screenshotTooLarge

    var errorDescription: String? {
        switch self {
        case .emptyMessage: "请填写反馈内容。"
        case .messageTooLong: "反馈内容不能超过 5000 字。"
        case .contactTooLong: "联系方式不能超过 200 字。"
        case .screenshotTooLarge: "反馈截图不能超过 5MB。"
        }
    }
}

enum FeedbackIdentity {
    private static let defaultsKey = "feedbackAnonymousInstallID"

    static func anonymousInstallIDHash(defaults: UserDefaults = .standard) -> String {
        let identifier: String
        if let stored = defaults.string(forKey: defaultsKey), UUID(uuidString: stored) != nil {
            identifier = stored
        } else {
            identifier = UUID().uuidString
            defaults.set(identifier, forKey: defaultsKey)
        }
        return SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum FeedbackDiagnostics {
    static var macOSVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    static var architecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
