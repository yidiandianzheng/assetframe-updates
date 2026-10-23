import Foundation

/// Shared by the confirmation form and isolated integration tests. Partial writes
/// are recoverable and reported with their exact paths, never called a success.
@MainActor enum CharacterModuleWorkflow {
    static func confirm(receipt: CharacterProjectModules.Receipt, root: URL,
                        loaded: CharacterLibraryStore.Loaded, library: CharacterLibraryStore,
                        index: CharacterProjectModules.Index, indexHash: String?) async throws -> URL {
        guard library.canEdit, var profile = loaded.profile, let materialID = receipt.materialID,
              profile.projectID == receipt.projectID, profile.characterID == receipt.characterID,
              CharacterProjectModules.resolve(receipt.profilePath, root: root).resolvingSymlinksInPath().path == URL(fileURLWithPath: loaded.entry.sourcePath).resolvingSymlinksInPath().path else {
            throw CharacterLibraryError.invalid("人物、项目或素材关联不匹配")
        }
        try await Task.detached { try CharacterProjectModules.verify(receipt, root: root, projectID: receipt.projectID) }.value
        guard try CharacterMarkdown.read(URL(fileURLWithPath: loaded.entry.sourcePath)).1 == loaded.fingerprint,
              try CharacterProjectModules.readIndex(root: root, projectID: receipt.projectID).1 == indexHash else { throw CharacterLibraryError.conflict }
        if let position = profile.assets.firstIndex(where: { $0.materialID == materialID && $0.role == receipt.role && $0.variant == receipt.variant }) {
            profile.assets[position].status = receipt.status; profile.assets[position].stage = receipt.stage
        } else { profile.assets.append(.init(materialID: materialID, variant: receipt.variant, role: receipt.role, stage: receipt.stage, status: receipt.status)) }
        try profile.validate()
        var saved: URL?
        do {
            let url = try CharacterProjectModules.saveReceipt(receipt, root: root); saved = url
            if !profile.sources.contains(url.path) { profile.sources.append(url.path) }
            guard await library.save(profile: profile, loaded: loaded) else { throw CharacterLibraryError.invalid(library.error ?? "档案保存失败") }
            let references: [CharacterProjectModules.Reference] = [
                .init(characterID: receipt.characterID, kind: "确认记录", path: CharacterProjectModules.relative(url, root: root), fingerprint: try CharacterMarkdown.read(url).1),
                .init(characterID: receipt.characterID, kind: "人物档案", path: receipt.profilePath, fingerprint: try CharacterMarkdown.read(URL(fileURLWithPath: loaded.entry.sourcePath)).1)
            ]
            try CharacterProjectModules.writeIndex(CharacterProjectModules.upsert(references, into: index), root: root, expected: indexHash)
            return url
        } catch {
            throw CharacterLibraryError.invalid(error.localizedDescription + (saved.map { "\n确认记录已保留：\($0.path)。若后续关联失败，可在项目扫描中恢复；不必重复新建。" } ?? ""))
        }
    }
}
