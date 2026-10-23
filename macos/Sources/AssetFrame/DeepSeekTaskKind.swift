import Foundation

enum DeepSeekTaskKind: String, CaseIterable, Identifiable, Sendable {
    case pendingImport
    case scriptExtraction
    case characterOrganization
    case libraryAudit

    var id: Self { self }

    var displayName: String {
        switch self {
        case .pendingImport: "待导入整理"
        case .scriptExtraction: "剧本查缺"
        case .characterOrganization: "人物 MD 整理"
        case .libraryAudit: "资产库体检"
        }
    }

    var usesDeepModel: Bool {
        switch self {
        case .pendingImport, .characterOrganization: false
        case .scriptExtraction, .libraryAudit: true
        }
    }
}
