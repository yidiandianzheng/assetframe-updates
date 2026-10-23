import Foundation

enum MaterialSearchField: String, Codable, CaseIterable, Identifiable, Sendable {
    case name
    case folder
    case fileExtension
    case tags
    case sourceLink
    case productionMark
    case note
    case classification

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "名称"
        case .folder: "文件夹信息"
        case .fileExtension: "扩展名"
        case .tags: "标签"
        case .sourceLink: "来源链接"
        case .productionMark: "生产标注"
        case .note: "备注"
        case .classification: "分类"
        }
    }

    var systemImage: String {
        switch self {
        case .name: "textformat"
        case .folder: "folder"
        case .fileExtension: "doc.badge.gearshape"
        case .tags: "tag"
        case .sourceLink: "link"
        case .productionMark: "bookmark"
        case .note: "text.bubble"
        case .classification: "square.grid.2x2"
        }
    }
}
