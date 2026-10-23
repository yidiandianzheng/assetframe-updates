import Foundation

enum LibraryAuditIssueKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case sourceMissing = "源文件缺失"
    case unclassified = "资产未分类"
    case emptyName = "资产名称为空"
    case pendingReview = "资产待审核"
    case fourKNotReady = "4K目标未满足"
    case unlockedVariant = "形态未锁定"
    case missingMainImage = "形态缺少主图"
    case missingKeyDifference = "缺少形态关键区别"
    case duplicateName = "资产名称重复"

    var id: Self { self }
}
