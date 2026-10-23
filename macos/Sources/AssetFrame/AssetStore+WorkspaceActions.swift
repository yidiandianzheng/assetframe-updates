import Foundation

@MainActor
extension AssetStore {
    func performUpdate<Value>(
        _ keyPath: WritableKeyPath<AssetItem, Value>,
        on target: AssetActionTarget,
        to value: Value
    ) {
        guard case .formal(let id) = target else { return }
        updateAsset(id) { $0[keyPath: keyPath] = value }
    }

    /// Resolves actions that require a formal project record. Pending items are registered
    /// in place; their source file is never copied, moved, renamed, or deleted here.
    @discardableResult
    func resolveFormalTargets(_ targets: Set<AssetActionTarget>) -> Set<AssetActionTarget> {
        let formalIDs = Set(targets.compactMap { target -> String? in
            guard case .formal(let id) = target else { return nil }
            return id
        })
        let pendingIDs = Set(targets.compactMap { target -> String? in
            guard case .pending(let id) = target else { return nil }
            return id
        })
        let promoted = promotePendingImports(pendingIDs)
        return Set(formalIDs.map(AssetActionTarget.formal))
            .union(promoted.values.map(AssetActionTarget.formal))
    }

    @discardableResult
    func performSetRating(_ rating: Int, on targets: Set<AssetActionTarget>) -> Set<AssetActionTarget> {
        let eligible = Set(targets.filter { $0.capabilities.canRate })
        let formalTargets = resolveFormalTargets(eligible)
        bulkSetRating(Set(formalTargets.map(\.id)), rating: rating)
        return formalTargets
    }

    func performSetType(_ type: AssetType, on targets: Set<AssetActionTarget>) {
        let eligible = targets.filter { $0.capabilities.canClassify }
        let formalIDs = Set(eligible.compactMap { if case .formal(let id) = $0 { id } else { nil } })
        let pendingIDs = eligible.compactMap { if case .pending(let id) = $0 { id } else { nil } }
        if !formalIDs.isEmpty { bulkSetType(formalIDs, type: type) }
        if !pendingIDs.isEmpty { bulkSetPendingType(pendingIDs, type: type) }
    }

    func performAddTags(_ tags: [String], on targets: Set<AssetActionTarget>) {
        let eligible = targets.filter { $0.capabilities.canTag }
        let formalIDs = Set(eligible.compactMap { if case .formal(let id) = $0 { id } else { nil } })
        if !formalIDs.isEmpty { bulkAddTags(formalIDs, tags: tags) }
        for target in eligible {
            guard case .pending(let id) = target, let item = pendingImport(withID: id) else { continue }
            updatePendingImport(id, manualTags: Array(Set(item.normalizedManualTags + tags)).sorted())
        }
    }

    @discardableResult
    func performSetDecision(_ decision: UserDecision, on targets: Set<AssetActionTarget>) -> Set<AssetActionTarget> {
        let formalTargets = resolveFormalTargets(targets)
        bulkSetDecision(Set(formalTargets.map(\.id)), decision: decision)
        return formalTargets
    }

    @discardableResult
    func performAddToExport(_ targets: Set<AssetActionTarget>) -> Set<AssetActionTarget> {
        let formalTargets = resolveFormalTargets(targets)
        addToExportLibrary(Set(formalTargets.map(\.id)))
        return formalTargets
    }

    @discardableResult
    func performSetCommon(_ isCommon: Bool, on targets: Set<AssetActionTarget>) -> Set<AssetActionTarget> {
        let eligible = Set(targets.filter { $0.capabilities.canAddToCommon || $0.capabilities.ratingPromotesToFormal })
        let formalTargets = resolveFormalTargets(eligible)
        bulkSetMaster(Set(formalTargets.map(\.id)), isMaster: isCommon)
        return formalTargets
    }

    func performReveal(_ target: AssetActionTarget) {
        guard target.capabilities.canReveal else { return }
        switch target {
        case .formal(let id): revealFileLocation(for: id)
        case .pending(let id), .quickReview(let id): revealPendingImportSource(id)
        case .globalFiveStar, .material: break
        }
    }

    func performCopyLocation(_ target: AssetActionTarget) {
        switch target {
        case .formal(let id): copyFileLocation(for: id)
        case .pending(let id), .quickReview(let id): copyPendingImportSourcePath(id)
        case .globalFiveStar, .material: break
        }
    }

    func performCopyOriginal(_ target: AssetActionTarget) {
        switch target {
        case .formal(let id): copyOriginalImage(for: id)
        case .pending(let id), .quickReview(let id):
            guard let item = pendingImport(withID: id) else { return }
            copyOriginalImage(at: URL(fileURLWithPath: item.originalSourcePath))
        case .globalFiveStar, .material: break
        }
    }

    func performRelink(_ target: AssetActionTarget) {
        switch target {
        case .formal(let id): relinkSource(for: id)
        case .pending(let id): relinkPendingImportSource(id)
        case .quickReview, .globalFiveStar, .material: break
        }
    }

    func performRename(_ target: AssetActionTarget) {
        guard target.capabilities.canRename else { return }
        switch target {
        case .formal(let id): requestRenameOriginalFile(for: id)
        case .pending(let id): requestRenamePendingOriginalFile(id)
        case .quickReview, .globalFiveStar, .material: break
        }
    }
}
