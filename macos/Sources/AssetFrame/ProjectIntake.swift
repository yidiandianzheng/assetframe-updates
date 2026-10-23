import Foundation

/// Rebuildable intake state, never a second source of persona facts.
struct ProjectIntake: Codable, Sendable {
    static let ruleVersion = 1
    struct Snapshot: Codable, Sendable {
        var fingerprints: [String: String] = [:]
        var navigation = ""
    }
    struct Analysis: Codable, Sendable {
        var projectID: String
        var characterID: String
        var targetName: String
        var navigation: String
        var fingerprint: String
        var ruleVersion: Int
        var item: CharacterProjectScanner.Classification
    }
    var automation: ProjectAutomationState?
    var version = 1
    var projects: [String: Snapshot] = [:]
    var analyses: [String: Analysis] = [:]
    static func navigation(_ documents: [CharacterProjectDocument]) -> String {
        let text = documents.filter { CharacterWorkflowBridge.sharedKinds.contains($0.kind) || $0.text.contains("assetframe-project-index:v1") }
            .sorted { $0.path < $1.path }.map { $0.path + ":" + $0.fingerprint }.joined(separator: "\n")
        return CharacterMarkdown.fingerprint(Data(text.utf8))
    }
    static func key(projectID: String, characterID: String, path: String) -> String {
        CharacterMarkdown.fingerprint(Data([projectID, characterID, path].joined(separator: "\u{1F}").utf8))
    }
    func cached(_ doc: CharacterProjectDocument, projectID: String, characterID: String, name: String, navigation: String) -> CharacterProjectScanner.Classification? {
        guard let saved = analyses[Self.key(projectID: projectID, characterID: characterID, path: doc.path)],
              saved.fingerprint == doc.fingerprint, saved.ruleVersion == Self.ruleVersion,
              saved.navigation == navigation, saved.targetName == name else { return nil }
        return saved.item
    }
    mutating func record(_ items: [CharacterProjectScanner.Classification], documents: [CharacterProjectDocument], projectID: String, characterID: String, name: String, navigation: String) {
        for item in items {
            guard let doc = documents.first(where: { $0.path == item.path }) else { continue }
            analyses[Self.key(projectID: projectID, characterID: characterID, path: item.path)] = Analysis(projectID: projectID, characterID: characterID, targetName: name, navigation: navigation, fingerprint: doc.fingerprint, ruleVersion: Self.ruleVersion, item: item)
        }
    }
    func changes(projectID: String, documents: [CharacterProjectDocument]) -> (added: Int, changed: Int, missing: Int, navigationChanged: Bool) {
        let old = projects[projectID] ?? Snapshot()
        let current = Set(documents.map(\.path))
        return (documents.filter { old.fingerprints[$0.path] == nil }.count,
                documents.filter { old.fingerprints[$0.path] != nil && old.fingerprints[$0.path] != $0.fingerprint }.count,
                Set(old.fingerprints.keys).subtracting(current).count,
                !old.navigation.isEmpty && old.navigation != Self.navigation(documents))
    }
    mutating func observe(projectID: String, documents: [CharacterProjectDocument], complete: Bool) {
        var snapshot = complete ? Snapshot() : (projects[projectID] ?? Snapshot())
        for doc in documents { snapshot.fingerprints[doc.path] = doc.fingerprint }
        snapshot.navigation = Self.navigation(documents)
        projects[projectID] = snapshot
    }
}
