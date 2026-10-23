import Foundation

enum SidebarSearchMatcher {
    static func matches(_ query: String, candidates: [String]) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return candidates.contains { $0.localizedStandardContains(normalized) }
    }
}

