import Foundation

/// The same field composition serves uncached queries and the text cache.
enum MaterialSearchText {
    struct Context: Sendable {
        var linksByMaterial: [String: [ProjectMaterialLink]]
        var folderRoots: [(name: String, path: String)]
        var aliases: [String: [String]] = [:]
        init(fields: Set<MaterialSearchField>, links: [ProjectMaterialLink], folders: [LocalFolderSource], tagging: MaterialTaggingState = .init()) {
            for term in tagging.effectiveTerms {
                aliases[term.dimension + "\u{1F}" + term.name, default: []].append(contentsOf: term.aliases)
            }
            linksByMaterial = fields.contains(.productionMark) ? Dictionary(grouping: links, by: \.materialID) : [:]
            folderRoots = fields.contains(.folder) ? folders.map {
                (name: $0.name, path: URL(fileURLWithPath: $0.rootPath).standardizedFileURL.path)
            } : []
        }
    }
    static func components(_ m: MaterialRecord, fields: Set<MaterialSearchField>, context: Context) -> [String] {
        var values: [String] = []
        if fields.contains(.name) {
            values.append(m.name)
            values.append((m.originalFilename as NSString).deletingPathExtension)
        }
        if fields.contains(.folder), let source = m.sourcePath {
            let sourceURL = URL(fileURLWithPath: source).standardizedFileURL
            let parent = sourceURL.deletingLastPathComponent()
            values.append(parent.lastPathComponent); values.append(parent.path)
            for folder in context.folderRoots {
                if sourceURL.path.hasPrefix(folder.path == "/" ? "/" : folder.path + "/") {
                    values.append(folder.name); values.append(folder.path)
                }
            }
        }
        if fields.contains(.fileExtension) { values.append((m.originalFilename as NSString).pathExtension) }
        if fields.contains(.tags) {
            values.append(contentsOf: m.tags)
            for tag in m.tags { values.append(contentsOf: context.aliases["\u{1F}" + tag] ?? []) }
        }
        if fields.contains(.sourceLink), let link = m.sourceURL { values.append(link) }
        if fields.contains(.productionMark) {
            if let p = m.production { values.append(contentsOf: [p.purpose, p.versionName, p.platform, p.model, p.batch, p.prompt]) }
            for link in context.linksByMaterial[m.id] ?? [] {
                values.append(contentsOf: [link.episode, link.scene, link.shot, link.selection, link.note].compactMap { $0 })
            }
        }
        if fields.contains(.note) { values.append(m.note) }
        if fields.contains(.classification), let classification = m.classification {
            for group in classification.groups {
                for term in group.terms {
                    values.append(term)
                    values.append(contentsOf: context.aliases[group.dimension + "\u{1F}" + term] ?? [])
                }
            }
        }
        return values
    }
    static func normalized(_ m: MaterialRecord, fields: Set<MaterialSearchField>, context: Context) -> String {
        components(m, fields: fields, context: context).joined(separator: " ").localizedLowercase
    }
}
