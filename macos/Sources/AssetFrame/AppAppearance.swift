import Foundation

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case graphite
    case system
    case light

    static let storageKey = "assetFrameAppearance"
    static let defaultValue: AppAppearance = .graphite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .graphite: "石墨黑"
        case .system: "跟随系统"
        case .light: "浅色"
        }
    }

    var detail: String {
        switch self {
        case .graphite: "深色画布与分层侧栏，让图片成为视觉中心"
        case .system: "自动采用 macOS 当前外观"
        case .light: "始终使用浅色外观"
        }
    }

    var systemImage: String {
        switch self {
        case .graphite: "circle.lefthalf.filled"
        case .system: "macwindow"
        case .light: "sun.max"
        }
    }
}
