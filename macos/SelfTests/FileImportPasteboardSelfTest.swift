import AppKit

@main
struct FileImportPasteboardSelfTest {
    @MainActor static func main() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let folder = URL(fileURLWithPath: "/tmp/中文 folder", isDirectory: true)
        let file = URL(fileURLWithPath: "/tmp/video file.mp4")
        pasteboard.writeObjects([folder as NSURL, file as NSURL])
        precondition(FileImportPasteboard.urls(pasteboard) == [folder, file])
        pasteboard.clearContents()
        pasteboard.writeObjects([NSURL(string: "https://example.com/video.mp4")!])
        precondition(FileImportPasteboard.urls(pasteboard).isEmpty)
        pasteboard.clearContents()
        precondition(FileImportPasteboard.urls(pasteboard).isEmpty)
        print("FileImportPasteboardSelfTest passed: Finder file URLs, folder URLs, spaces, Unicode, non-file rejection")
    }
}
