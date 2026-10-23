import Foundation

/// Owned by one mounted library browser; immutable snapshots cross executors.
/// Search terms and browse scope are deliberately absent from the cache key.
actor MaterialTextSearchCache {
    struct Key: Equatable, Sendable {
        var libraryGeneration: String
        var queryRevision: UInt64
        var fields: Set<MaterialSearchField>
        var localeIdentifier: String = Locale.current.identifier
        var catalogKey: String = "builtin"
    }
    struct Diagnostics: Codable, Sendable {
        var active = false
        var cacheHit = false
        var buildCount = 0
        var cachedRecordCount = 0
        var estimatedBytes = 0
        var buildMilliseconds = 0.0
        var incremental = false
        var reusedRecordCount = 0
        var normalizedRecordCount = 0
        var fallbackReason: String?
    }
    struct Prepared: Sendable {
        var index: MaterialTextSearchIndex?
        var diagnostics: Diagnostics
    }

    private let byteBudget: Int
    private let recordLimit: Int
    private var key: Key?
    private var index: MaterialTextSearchIndex?
    private var diagnostics = Diagnostics()
    private var inputs: [String: [String]] = [:]

    init(byteBudget: Int = 64 * 1024 * 1024, recordLimit: Int = 100_000) {
        self.byteBudget = max(0, byteBudget); self.recordLimit = max(0, recordLimit)
    }

    func prepare(key requested: Key, enabled: Bool, materials: [MaterialRecord],
                 links: [ProjectMaterialLink], folders: [LocalFolderSource], tagging: MaterialTaggingState = .init()) -> Prepared {
        guard enabled, !requested.fields.isEmpty, !Task.isCancelled else {
            var value = diagnostics; value.active = false; value.cacheHit = false
            return Prepared(index: nil, diagnostics: value)
        }
        if key == requested {
            var value = diagnostics; value.active = index != nil; value.cacheHit = index != nil
            return Prepared(index: index, diagnostics: value)
        }
        // Query revisions may change one record. Reuse text only when every raw
        // search component still matches; no hash collision or stale link/folder text.
        let canReuse = key?.libraryGeneration == requested.libraryGeneration &&
            key?.fields == requested.fields && key?.localeIdentifier == requested.localeIdentifier && index != nil
        var value = Diagnostics(); value.buildCount = diagnostics.buildCount + 1
        value.incremental = canReuse
        let start = DispatchTime.now().uptimeNanoseconds
        let context = MaterialSearchText.Context(fields: requested.fields, links: links, folders: folders, tagging: tagging)
        var texts: [String: String] = [:], nextInputs: [String: [String]] = [:], bytes = 0
        if materials.count > recordLimit { value.fallbackReason = "record_limit" }
        else {
            texts.reserveCapacity(materials.count); nextInputs.reserveCapacity(materials.count)
            for (position, material) in materials.enumerated() {
                if position % 128 == 0, Task.isCancelled { return Prepared(index: nil, diagnostics: diagnostics) }
                if texts[material.id] != nil { value.fallbackReason = "duplicate_id"; break }
                let components = MaterialSearchText.components(material, fields: requested.fields, context: context)
                let text: String
                if canReuse, inputs[material.id] == components, let previous = index?.texts[material.id] {
                    text = previous; value.reusedRecordCount += 1
                } else {
                    text = components.joined(separator: " ").localizedLowercase; value.normalizedRecordCount += 1
                }
                // Include retained raw inputs as well as normalized text. This is
                // a conservative index estimate, not peak process memory.
                bytes += text.utf8.count + components.reduce(0) { $0 + $1.utf8.count + 32 } + material.id.utf8.count * 2 + 256
                if bytes > byteBudget { value.fallbackReason = "byte_budget"; break }
                texts[material.id] = text; nextInputs[material.id] = components
            }
        }
        guard !Task.isCancelled else { return Prepared(index: nil, diagnostics: diagnostics) }
        inputs = [:]; index = nil
        if value.fallbackReason == nil {
            inputs = nextInputs
            index = MaterialTextSearchIndex(fields: requested.fields, localeIdentifier: requested.localeIdentifier,
                                            texts: texts, estimatedBytes: bytes)
            value.active = true; value.cachedRecordCount = texts.count; value.estimatedBytes = bytes
        }
        value.buildMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        // Remember refused keys too, so oversize libraries do not rebuild on each keystroke.
        key = requested; diagnostics = value
        return Prepared(index: index, diagnostics: value)
    }
}
