import Foundation

/// File navigation is independent of AI classification and keeps every linked root visible.
struct ProjectSourceFileIndex: Sendable {
    struct Folder: Identifiable, Sendable {
        var id: String
        var name: String
        var path: String
        var children: [Folder]?
        var issue = ""
    }
    struct File: Identifiable, Sendable {
        var path: String
        var name: String
        var material: MaterialRecord?
        var id: String { path }
    }
    var roots: [Folder] = []
    var files: [File] = []
    var warnings: [String] = []
    static func contains(_ path: String, in folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
    static func build(sources: [CharacterLibraryRegistry.Project.Source], previous: Self = .init()) throws -> Self {
        var result = Self(), files: [String: File] = [:], visited = 0
        let fm = FileManager.default
        for source in sources {
            try Task.checkCancellation()
            let root = URL(fileURLWithPath: source.path)
            guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                var node = previous.roots.first { $0.path == source.path } ?? Folder(id: source.id, name: source.name, path: source.path)
                node.issue = "目录离线或不可读"
                result.roots.append(node)
                for file in previous.files where contains(file.path, in: source.path) { files[file.path] = file }
                result.warnings.append(source.name + "：目录离线或不可读；保留上次文件列表")
                continue
            }
            var directories: [String: [String]] = [source.path: []], names: [String: String] = [source.path: source.name]
            var issues: [String] = []
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            if let walker = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { url, error in
                issues.append(url.lastPathComponent + "：" + error.localizedDescription); return true
            }) {
                for case let discovered as URL in walker {
                    try Task.checkCancellation(); visited += 1
                    if visited > 30_000 { issues.append("项目文件树达到 30,000 项上限，显示不完整"); break }
                    let values: URLResourceValues
                    do { values = try discovered.resourceValues(forKeys: keys) }
                    catch { issues.append(discovered.lastPathComponent + "：读取失败"); continue }
                    if values.isSymbolicLink == true { walker.skipDescendants(); continue }
                    let url = discovered.resolvingSymlinksInPath().standardizedFileURL
                    let name = url.lastPathComponent
                    if name.hasPrefix(".") && name != ".media" { if values.isDirectory == true { walker.skipDescendants() }; continue }
                    if values.isDirectory == true {
                        if ["node_modules", "人物库索引", "ProjectData"].contains(name) { walker.skipDescendants(); continue }
                        directories[url.path] = []; directories[url.deletingLastPathComponent().path, default: []].append(url.path)
                        names[url.path] = name
                    } else {
                        var material: MaterialRecord?
                        let ext = url.pathExtension.lowercased(), kind: MaterialKind?
                        if ["png", "jpg", "jpeg", "webp", "heic", "tif", "tiff", "gif"].contains(ext) { kind = .image }
                        else if ["mp3", "wav", "m4a", "aac", "aiff", "flac"].contains(ext) { kind = .audio }
                        else if ["mp4", "mov", "m4v"].contains(ext) { kind = .video }
                        else { kind = nil }
                        if let kind {
                            let key = CharacterMarkdown.fingerprint(Data(url.path.utf8))
                            var record = MaterialRecord(id: "project-preview-" + key, kind: kind, name: name,
                                sourcePath: url.path, originalFilename: name, fingerprint: key,
                                sourceLocations: [url.path], fileSize: values.fileSize.map(Int64.init), createdAt: .distantPast,
                                tags: [], rating: 0, note: "链接目录中的原文件；尚未声明资产身份或采用状态")
                            record.sourceModifiedAt = values.contentModificationDate
                            material = record
                        }
                        files[url.path] = File(path: url.path, name: name, material: material)
                    }
                }
            } else { issues.append("目录无法枚举，读取不完整") }
            func folder(_ path: String) -> Folder {
                let children = (directories[path] ?? []).sorted().map { folder($0) }
                return Folder(id: source.id + "|" + path, name: names[path] ?? URL(fileURLWithPath: path).lastPathComponent,
                    path: path, children: children.isEmpty ? nil : children)
            }
            var node = folder(source.path); node.issue = issues.isEmpty ? "" : "部分文件未读取"
            if !issues.isEmpty {
                for file in previous.files where contains(file.path, in: source.path) && files[file.path] == nil { files[file.path] = file }
                func retainFolders(_ current: Folder, _ old: Folder) -> Folder {
                    var merged = current
                    var children = Dictionary((current.children ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                    for child in old.children ?? [] { children[child.path] = children[child.path].map { retainFolders($0, child) } ?? child }
                    let list = children.values.sorted { $0.path < $1.path }
                    merged.children = list.isEmpty ? nil : list
                    return merged
                }
                if let old = previous.roots.first(where: { $0.path == source.path }) { node = retainFolders(node, old) }
            }
            result.roots.append(node); result.warnings += issues.map { source.name + "：" + $0 }
        }
        result.files = files.values.sorted { $0.path < $1.path }
        return result
    }
}
