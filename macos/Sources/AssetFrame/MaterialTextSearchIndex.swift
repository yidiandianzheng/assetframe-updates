import Foundation

struct MaterialTextSearchIndex: Sendable {
    let fields: Set<MaterialSearchField>
    let localeIdentifier: String
    let texts: [String: String]
    let estimatedBytes: Int

    func matches(_ id: String, words: [String]) -> Bool? {
        guard let text = texts[id] else { return nil }
        return words.allSatisfy { text.contains($0) }
    }
}
