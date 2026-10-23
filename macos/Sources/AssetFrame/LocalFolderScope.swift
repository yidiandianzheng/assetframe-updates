import Foundation

enum LocalFolderScope: String, CaseIterable, Identifiable, Sendable {
    case currentOnly = "仅当前文件夹"
    case oneLevel = "包含一级子文件夹"
    case recursive = "包含全部层级"

    var id: Self { self }

    func includes(directory: String, selectedDirectory: String) -> Bool {
        let selected = selectedDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidate = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let remainder: String
        if selected.isEmpty {
            remainder = candidate
        } else if candidate == selected {
            remainder = ""
        } else {
            let prefix = selected + "/"
            guard candidate.hasPrefix(prefix) else { return false }
            remainder = String(candidate.dropFirst(prefix.count))
        }

        switch self {
        case .currentOnly:
            return remainder.isEmpty
        case .oneLevel:
            return remainder.isEmpty || !remainder.contains("/")
        case .recursive:
            return true
        }
    }
}
