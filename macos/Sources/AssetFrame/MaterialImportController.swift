import Combine
import Foundation

@MainActor
final class MaterialImportController: ObservableObject {
    var job: ImportJobProgress?
    @Published var importResults: [MaterialImportResult] = []
    @Published var importTotal = 0
    @Published var importPhase = ""
    @Published var importCurrentFile = ""
    @Published var importDiscovered = 0
    @Published var importProcessed = 0
    @Published var importRead = 0
    @Published var importSaveCount = 0
    @Published var importReadSeconds = 0.0
    @Published var importSaveSeconds = 0.0
    @Published var importScanCompleted = false
    @Published var importAdded = 0
    @Published var importDuplicate = 0
    @Published var importFailed = 0
    @Published var importSkipped = 0
    @Published var importCancelled = 0
    @Published var importEstimatedRemainingSeconds: Double?
}
