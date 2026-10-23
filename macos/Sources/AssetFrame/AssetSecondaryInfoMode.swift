import Foundation

enum AssetSecondaryInfoMode: String, CaseIterable, Identifiable, Sendable {
    case dimensionsAndSize = "尺寸 + 文件大小"
    case dimensions = "仅尺寸"
    case fileSize = "仅文件大小"

    var id: Self { self }
}
