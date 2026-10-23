import Foundation

/// 顶层工作区只描述用户当前正在完成的任务，不混入文件夹、星级等资产范围。
enum WorkspaceDestination: String, CaseIterable, Identifiable, Sendable {
    case assetLibrary
    case materialLibrary
    case exportLibrary
    case trash

    var id: Self { self }

    var displayName: String {
        switch self {
        case .assetLibrary: "资产库"
        case .materialLibrary: "素材总库"
        case .exportLibrary: "导出库"
        case .trash: "回收站"
        }
    }

    var systemImage: String {
        switch self {
        case .assetLibrary: "rectangle.grid.2x2"
        case .materialLibrary: "square.stack.3d.up"
        case .exportLibrary: "shippingbox"
        case .trash: "trash"
        }
    }

    var savedView: SavedView {
        switch self {
        case .assetLibrary: .allGallery
        case .materialLibrary: .materialLibrary
        case .exportLibrary: .exportLibrary
        case .trash: .trash
        }
    }
}

