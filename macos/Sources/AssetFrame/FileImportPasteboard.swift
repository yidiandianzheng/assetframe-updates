import AppKit
import SwiftUI

private struct FileImportDropHandlerKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable ([URL]) -> Void)? = nil
}

extension EnvironmentValues {
    var fileImportDropHandler: (@MainActor @Sendable ([URL]) -> Void)? {
        get { self[FileImportDropHandlerKey.self] }
        set { self[FileImportDropHandlerKey.self] = newValue }
    }
}

enum FileImportPasteboard {
    @MainActor static func urls(_ pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        var seen = Set<String>()
        return objects.compactMap { $0 as? URL }.filter {
            $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted
        }
    }
}
