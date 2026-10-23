import Foundation

enum ScriptAssetMatchSortMode: String, CaseIterable, Identifiable, Sendable {
    case nameFirst = "名称优先"
    case balanced = "综合推荐"

    var id: Self { self }
}
