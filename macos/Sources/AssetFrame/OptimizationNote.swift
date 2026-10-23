import CoreGraphics
import Foundation

enum OptimizationNoteStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending = "待评估"
    case planned = "准备解决"
    case completed = "已完成"
    case skipped = "暂不处理"

    var id: Self { self }
}

struct NormalizedRect: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    func rect(in size: CGSize) -> CGRect {
        CGRect(
            x: x * size.width,
            y: y * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }
}

struct OptimizationNoteDraft: Identifiable, Sendable {
    let id = UUID()
    let projectID: String
    let projectName: String
    let viewName: String
    let region: NormalizedRect
}

struct OptimizationNote: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let version: String
    let projectID: String
    let projectName: String
    let viewName: String
    let region: NormalizedRect
    let note: String
    let createdAt: Date
    var status: OptimizationNoteStatus? = nil
    var submissionID: UUID? = nil
    var feedbackType: FeedbackCategory? = nil
    var screenshotFilename: String? = nil
    var syncState: FeedbackSyncState? = nil
    var retryCount: Int = 0
    var appShortVersion: String? = nil
    var buildVersion: String? = nil
    var includeDiagnostics: Bool? = nil
    var macOSVersion: String? = nil
    var architecture: String? = nil
    var anonymousInstallIDHash: String? = nil
    var contact: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, version, projectID, projectName, viewName, region, note, createdAt
        case status, submissionID, feedbackType, screenshotFilename, syncState, retryCount
        case appShortVersion, buildVersion, includeDiagnostics, macOSVersion, architecture
        case anonymousInstallIDHash, contact
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        version = try values.decode(String.self, forKey: .version)
        projectID = try values.decode(String.self, forKey: .projectID)
        projectName = try values.decode(String.self, forKey: .projectName)
        viewName = try values.decode(String.self, forKey: .viewName)
        region = try values.decode(NormalizedRect.self, forKey: .region)
        note = try values.decode(String.self, forKey: .note)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        status = try values.decodeIfPresent(OptimizationNoteStatus.self, forKey: .status)
        submissionID = try values.decodeIfPresent(UUID.self, forKey: .submissionID)
        feedbackType = try values.decodeIfPresent(FeedbackCategory.self, forKey: .feedbackType)
        screenshotFilename = try values.decodeIfPresent(String.self, forKey: .screenshotFilename)
        syncState = try values.decodeIfPresent(FeedbackSyncState.self, forKey: .syncState)
        retryCount = try values.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        appShortVersion = try values.decodeIfPresent(String.self, forKey: .appShortVersion)
        buildVersion = try values.decodeIfPresent(String.self, forKey: .buildVersion)
        includeDiagnostics = try values.decodeIfPresent(Bool.self, forKey: .includeDiagnostics)
        macOSVersion = try values.decodeIfPresent(String.self, forKey: .macOSVersion)
        architecture = try values.decodeIfPresent(String.self, forKey: .architecture)
        anonymousInstallIDHash = try values.decodeIfPresent(String.self, forKey: .anonymousInstallIDHash)
        contact = try values.decodeIfPresent(String.self, forKey: .contact)
    }

    /// Compatibility initializer for the feedback queue schema. Newer queue
    /// metadata remains optional so older persisted notes decode unchanged.
    init(
        id: UUID, version: String, projectID: String, projectName: String,
        viewName: String, region: NormalizedRect, note: String, createdAt: Date,
        status: OptimizationNoteStatus? = nil,
        feedbackType: FeedbackCategory? = nil,
        contact: String? = nil,
        includeDiagnostics: Bool? = nil,
        screenshotFilename: String? = nil,
        submissionID: UUID? = nil,
        syncState: FeedbackSyncState? = nil,
        retryCount: Int = 0,
        appShortVersion: String? = nil,
        buildVersion: String? = nil,
        macOSVersion: String? = nil,
        architecture: String? = nil,
        anonymousInstallIDHash: String? = nil
    ) {
        self.id = id
        self.version = version
        self.projectID = projectID
        self.projectName = projectName
        self.viewName = viewName
        self.region = region
        self.note = note
        self.createdAt = createdAt
        self.status = status
        self.submissionID = submissionID
        self.feedbackType = feedbackType
        self.screenshotFilename = screenshotFilename
        self.syncState = syncState
        self.retryCount = retryCount
        self.appShortVersion = appShortVersion
        self.buildVersion = buildVersion
        self.includeDiagnostics = includeDiagnostics
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.anonymousInstallIDHash = anonymousInstallIDHash
        self.contact = contact
    }

    var effectiveStatus: OptimizationNoteStatus { status ?? .pending }
    var effectiveSyncState: FeedbackSyncState { syncState ?? .localOnly }
}

@MainActor
final class OptimizationNoteStore: ObservableObject {
    @Published private(set) var notes: [OptimizationNote] = []

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let feedbackSender: (any FeedbackSending)?

    convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = support.appendingPathComponent("AssetFrame", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.init(fileURL: directory.appendingPathComponent("optimization-notes.json"), feedbackSender: nil)
    }

    init(fileURL: URL, feedbackSender: (any FeedbackSending)? = nil) {
        self.fileURL = fileURL
        self.feedbackSender = feedbackSender

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        load()
    }

    func addFeedback(
        draft: OptimizationNoteDraft,
        type: FeedbackCategory,
        text: String,
        contact: String?,
        screenshotData: Data?,
        includeDiagnostics: Bool
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let id = UUID()
        let screenshotFilename = storeScreenshot(screenshotData, id: id)
        let note = OptimizationNote(
            id: id,
            version: AppVersion.display,
            projectID: draft.projectID,
            projectName: draft.projectName,
            viewName: draft.viewName,
            region: draft.region,
            note: trimmed,
            createdAt: Date(),
            status: .pending,
            feedbackType: type,
            contact: contact,
            includeDiagnostics: includeDiagnostics,
            screenshotFilename: screenshotFilename,
            submissionID: UUID(),
            syncState: feedbackSender == nil ? .localOnly : .queued,
            appShortVersion: AppVersion.shortVersion,
            buildVersion: AppVersion.build,
            macOSVersion: FeedbackDiagnostics.macOSVersion,
            architecture: FeedbackDiagnostics.architecture,
            anonymousInstallIDHash: FeedbackIdentity.anonymousInstallIDHash()
        )
        notes.insert(note, at: 0)
        save()
        if feedbackSender != nil { queueForSubmission(note) }
    }

    func queueForSubmission(_ note: OptimizationNote) {
        guard feedbackSender != nil, note.effectiveSyncState != .submitting, note.effectiveSyncState != .submitted else { return }
        Task { [weak self] in
            await self?.submitFeedback(note.id)
        }
    }

    func add(draft: OptimizationNoteDraft, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notes.insert(
            OptimizationNote(
                id: UUID(),
                version: AppVersion.display,
                projectID: draft.projectID,
                projectName: draft.projectName,
                viewName: draft.viewName,
                region: draft.region,
                note: trimmed,
                createdAt: Date(),
                status: .pending
            ),
            at: 0
        )
        save()
    }

    func remove(_ note: OptimizationNote) {
        notes.removeAll { $0.id == note.id }
        save()
    }

    func updateStatus(_ note: OptimizationNote, status: OptimizationNoteStatus) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index].status = status
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([OptimizationNote].self, from: data) else { return }
        notes = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func save() {
        guard let data = try? encoder.encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func submitFeedback(_ noteID: UUID) async {
        guard let sender = feedbackSender,
              let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        notes[index].syncState = .submitting
        save()

        let note = notes[index]
        let screenshot = note.screenshotFilename.flatMap(loadScreenshot)
        do {
            _ = try await sender.submit(FeedbackSubmissionV1(note: note), screenshot: screenshot)
            guard let currentIndex = notes.firstIndex(where: { $0.id == noteID }) else { return }
            removeScreenshot(notes[currentIndex].screenshotFilename)
            notes[currentIndex].screenshotFilename = nil
            notes[currentIndex].syncState = .submitted
            save()
        } catch {
            guard let currentIndex = notes.firstIndex(where: { $0.id == noteID }) else { return }
            notes[currentIndex].retryCount += 1
            notes[currentIndex].syncState = .failed
            save()
        }
    }

    private var screenshotsDirectory: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("feedback-screenshots", isDirectory: true)
    }

    private func storeScreenshot(_ data: Data?, id: UUID) -> String? {
        guard let data else { return nil }
        try? FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)
        let filename = "\(id.uuidString).jpg"
        let url = screenshotsDirectory.appendingPathComponent(filename)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return filename
    }

    private func loadScreenshot(_ filename: String) -> Data? {
        try? Data(contentsOf: screenshotsDirectory.appendingPathComponent(filename))
    }

    private func removeScreenshot(_ filename: String?) {
        guard let filename else { return }
        try? FileManager.default.removeItem(at: screenshotsDirectory.appendingPathComponent(filename))
    }
}
