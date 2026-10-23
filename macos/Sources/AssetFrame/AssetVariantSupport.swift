import Foundation

extension AssetStore {
    func cancelFeishuImport() { feishuImportPreview = nil }
    func applyFeishuImport() { feishuImportPreview = nil; showToast("飞书差异已取消；当前迁移版本尚未恢复回导写入") }
    func stack(withID id: String) -> AssetVariantRecord? { assetStacks.first { $0.id == id } }
    func entity(withID id: String) -> AssetEntityRecord? { assetEntities.first { $0.id == id } }
    func entity(for variant: AssetVariantRecord) -> AssetEntityRecord? { entity(withID: variant.entityID) }

    func createAssetVariant(assetIDs: Set<String>, entityID: String?, entityName: String, type: AssetType, variantName: String, suggestedCoverID: String) {
        let entity: AssetEntityRecord
        if let entityID, let existing = self.entity(withID: entityID) { entity = existing }
        else {
            entity = AssetEntityRecord(id: UUID().uuidString, code: "R\(String(format: "%03d", assetEntities.count + 1))", name: entityName, type: type)
            assetEntities.append(entity)
        }
        let ids = assetIDs.filter { asset(withID: $0)?.deletedAt == nil }
        guard ids.count >= 2 else { return }
        assetStacks.append(AssetVariantRecord(id: UUID().uuidString, entityID: entity.id, variantName: variantName, callCode: "\(entity.code)-F\(String(format: "%02d", assetStacks.filter { $0.entityID == entity.id }.count + 1))_\(entityName)_\(variantName)", memberAssetIDs: Array(ids), coverAssetID: suggestedCoverID, candidateDecisions: Dictionary(uniqueKeysWithValues: ids.map { ($0, .pending) }), keyDifference: nil, doNotMix: nil, lockedAt: nil, version: 1))
    }
    func setVariantDecision(_ id: String, assetID: String, decision: VariantCandidateDecision) {
        guard let index = assetStacks.firstIndex(where: { $0.id == id }) else { return }
        if decision == .main { for key in assetStacks[index].memberAssetIDs where assetStacks[index].candidateDecisions[key] == .main { assetStacks[index].candidateDecisions[key] = .unused } }
        assetStacks[index].candidateDecisions[assetID] = decision
    }
    func variantLockIssues(_ id: String) -> [String] { guard let value = stack(withID: id) else { return ["形态不存在"] }; return value.memberAssetIDs.contains { value.candidateDecisions[$0] == .main } ? [] : ["必须选择 1 张主图"] }
    func lockVariant(_ id: String) { guard variantLockIssues(id).isEmpty, let index = assetStacks.firstIndex(where: { $0.id == id }) else { return }; assetStacks[index].lockedAt = .now; for key in assetStacks[index].memberAssetIDs where assetStacks[index].candidateDecisions[key] == .pending { assetStacks[index].candidateDecisions[key] = .unused } }
    func unlockVariant(_ id: String) { guard let index = assetStacks.firstIndex(where: { $0.id == id }) else { return }; assetStacks[index].lockedAt = nil }
    func updateVariantMetadata(_ id: String, entityName: String, variantName: String, keyDifference: String, doNotMix: String) { guard let index = assetStacks.firstIndex(where: { $0.id == id }) else { return }; assetStacks[index].variantName = variantName; assetStacks[index].keyDifference = keyDifference; assetStacks[index].doNotMix = doNotMix; if let entityIndex = assetEntities.firstIndex(where: { $0.id == assetStacks[index].entityID }) { assetEntities[entityIndex].name = entityName } }
    func removeAssetFromStack(_ assetID: String) { guard let index = assetStacks.firstIndex(where: { $0.memberAssetIDs.contains(assetID) }) else { return }; assetStacks[index].memberAssetIDs.removeAll { $0 == assetID }; assetStacks[index].candidateDecisions.removeValue(forKey: assetID); if assetStacks[index].memberAssetIDs.count < 2 { assetStacks.remove(at: index) } }
    func unstack(_ id: String) { assetStacks.removeAll { $0.id == id } }
    func addVariantToExportLibrary(_ id: String) { guard let value = stack(withID: id), value.isLocked, let main = value.memberAssetIDs.first(where: { value.candidateDecisions[$0] == .main }) else { return }; addToExportLibrary([main]) }
}
