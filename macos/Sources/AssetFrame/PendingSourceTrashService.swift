import Foundation

protocol PendingSourceTrashing: Sendable {
    func moveToTrash(_ url: URL) throws
}

struct SystemPendingSourceTrashService: PendingSourceTrashing {
    func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

enum PendingSourceTrashError: Error, Equatable, LocalizedError, Sendable {
    case sourceMissing
    case sourceChanged
    case sourceIsManagedCopy
    case projectChanged
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            "原下载文件已经不存在；软件没有删除待导入副本。"
        case .sourceChanged:
            "原下载文件在加入待导入后发生了变化。为防止误删，请重新扫描后再处理。"
        case .sourceIsManagedCopy:
            "这条记录没有可验证的外部原图，只能使用普通“移出待导入”。"
        case .projectChanged:
            "项目已经切换，本次原图删除已取消。"
        case .operationFailed(let message):
            "原图未能移到系统废纸篓：\(message)"
        }
    }
}
