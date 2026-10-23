import Foundation

@main struct MaterialSourceAvailabilitySelfTest {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("assetframe-source-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("image.jpg")
        try Data("fixture".utf8).write(to: file)
        precondition(MaterialSourceAvailability.inspect(path: file.path) == .available)
        try fm.removeItem(at: file)
        precondition(MaterialSourceAvailability.inspect(path: file.path) == .missing, "Deleted source must be observed on refresh")
        try Data("restored".utf8).write(to: file)
        precondition(MaterialSourceAvailability.inspect(path: file.path) == .available, "Restoring the source must not require reimport")
        let oldPrimary = root.appendingPathComponent("moved-from.jpg")
        precondition(
            MaterialSourceAvailability.inspect(paths: [oldPrimary.path, file.path]) == .available,
            "A valid legacy fallback path must keep the material visible"
        )
        try fm.removeItem(at: file)
        let placeholder = root.appendingPathComponent(".image.jpg.icloud")
        try Data().write(to: placeholder)
        precondition(MaterialSourceAvailability.inspect(path: file.path) == .cloudOnly, "Cloud placeholders must not be treated as deleted")
        precondition(MaterialSourceAvailability.inspect(path: "/Volumes/assetframe-absent-" + UUID().uuidString + "/image.jpg") == .offline)
        precondition(MaterialSourceAvailability.inspect(path: nil) == .missing)
        print("MaterialSourceAvailabilitySelfTest passed: existing, deleted, restored, fallback, cloud placeholder, offline volume")
    }
}
