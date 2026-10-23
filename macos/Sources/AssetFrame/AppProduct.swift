import Foundation

/// Installed apps have separate identities, preferences, registries and CLI endpoints.
/// Shared source code does not make the two products share writable project indexes.
enum AppProduct: String, Sendable {
    case assets, story
    static var current: Self { resolve(Bundle.main.object(forInfoDictionaryKey: "AFProductKind") as? String) }
    static func resolve(_ value: String?) -> Self { value == "story" ? .story : .assets }
    var title: String { self == .assets ? "向量 · AI资产管家" : "向量 · 漫剧工作台" }
    var supportDirectory: String { self == .assets ? "AssetFrame" : "ManjuWorkbench" }
    var applicationSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(supportDirectory)
    }
}
