import Foundation
import CoreGraphics

enum AssetType: String, Codable, CaseIterable, Identifiable, Sendable {
    case unclassified = "待分类", person = "人物", creature = "生物", venue = "场地", scene = "场景"
    case prop = "道具", product = "产品", cover = "封面", publishCover = "发布封面", fixedSymbol = "固定视觉符号", boundStructure = "绑定结构"
    var id: String { rawValue }
    var symbol: String {
        return switch self {
        case .unclassified: "问"; case .person: "人"; case .creature: "生"; case .venue: "地"; case .scene: "景"
        case .prop: "物"; case .product: "品"; case .cover: "封"; case .publishCover: "发"; case .fixedSymbol: "符"; case .boundStructure: "构"
        }
    }
}

enum UserDecision: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending = "待确认", confirmed = "✅确定使用", rejected = "❌不用"
    var id: String { rawValue }
    var displayName: String {
        switch self { case .pending: "备用"; case .confirmed: "使用"; case .rejected: "废片" }
    }
}

enum ReuseGrade: String, Codable, CaseIterable, Identifiable, Sendable { case s = "S", a = "A", b = "B", c = "C"; var id: String { rawValue } }
enum CandidatePlan: String, Codable, CaseIterable, Identifiable, Sendable { case a = "A方案", b = "B方案", c = "C方案", d = "D方案", e = "E方案", none = "无方案"; var id: String { rawValue } }
enum AssetPurpose: String, Codable, CaseIterable, Identifiable, Sendable {
    case dualView = "双视图", multiAngle = "多角度", expression = "表情动作", sceneReference = "场景参考"
    case propSingle = "道具单体", productSingle = "产品单体", effects = "特效参考", structure = "结构参考", pending = "待判断"
    var id: String { rawValue }
}
enum AssetCategory: String, Codable, CaseIterable, Identifiable, Sendable { case project = "项目专用", common = "通用资产", temporary = "临时资产", pending = "待分类"; var id: String { rawValue } }
enum QAResult: String, Codable, CaseIterable, Identifiable, Sendable { case pending = "待验收", passed = "通过", repair = "需返修", failed = "不合格"; var id: String { rawValue } }
enum ProductionStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pendingGenerate = "待生成", generating = "生成中", pendingAcceptance = "待验收", pendingConfirm = "待确认"
    case repairing = "返修中", adopted = "已采用", eliminated = "淘汰"
    var id: String { rawValue }
}

enum PreferredOutputResolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case source = "按原图"
    case fourK = "4K"
    var id: String { rawValue }
}

struct CanvasPoint: Codable, Hashable, Sendable {
    var x: CGFloat; var y: CGFloat
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    init(x: CGFloat, y: CGFloat) { self.x = x; self.y = y }
    init(_ point: CGPoint) { x = point.x; y = point.y }
}

struct AssetSourceVersion: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(fileID ?? path)|\(modifiedAt?.timeIntervalSince1970 ?? 0)" }
    var path: String
    var filename: String
    var fileID: String?
    var fileSize: Int64?
    var modifiedAt: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var addedAt: Date

    var pixelCount: Int64 { Int64(pixelWidth ?? 0) * Int64(pixelHeight ?? 0) }
    var resolutionLabel: String { ResolutionLabel.label(width: pixelWidth, height: pixelHeight) }
    var dimensionText: String {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return "尺寸待识别" }
        return "\(pixelWidth) × \(pixelHeight)"
    }
}

enum ResolutionLabel {
    static func label(width: Int?, height: Int?) -> String {
        let longest = max(width ?? 0, height ?? 0)
        if longest >= 3_840 { return "4K" }
        if longest >= 2_048 { return "2K" }
        if longest >= 1_024 { return "1K" }
        return longest > 0 ? "<1K" : "待识别"
    }
}

struct AssetItem: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var type: AssetType
    var imagePath: String
    var originalFilename: String
    var decision: UserDecision
    var note: String
    var reuse: ReuseGrade
    var project: String
    var episodes: [String]
    var candidatePlan: CandidatePlan
    var version: String
    var purpose: AssetPurpose
    var category: AssetCategory
    var qaResult: QAResult
    var productionStatus: ProductionStatus
    var assetDescription: String
    var repairReason: String
    var fingerprint: String
    var shapeState: String
    var promptSource: String
    var generationPlatform: String
    var position: CanvasPoint
    var createdAt: Date
    /// 最近被预览、定位、复制路径或加入导出库的时间。
    /// 可选字段保证旧项目数据无需迁移即可打开。
    var lastUsedAt: Date? = nil
    var deletedAt: Date? = nil
    var projectID: String? = nil
    /// 建立索引时所属的本地文件夹根。当前版本原位引用图片，不复制到项目资产库。
    var sourceFolderID: String? = nil
    /// 当前原文件的绝对路径，用于 Finder 定位和文件夹镜像。
    var sourceOriginalPath: String? = nil
    var sourceRelativePath: String? = nil
    var sourceFileID: String? = nil
    var sourceFileSize: Int64? = nil
    /// 原文件在文件系统中的创建日期；nil 兼容旧项目数据和不提供该元数据的文件系统。
    var sourceCreatedAt: Date? = nil
    var sourceModifiedAt: Date? = nil
    var isSourceMissing: Bool? = nil
    var thumbnailKey: String? = nil
    var exportName: String? = nil
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    var sourceVersions: [AssetSourceVersion]? = nil
    var sourceReplacedAt: Date? = nil
    /// 旧版双路径兼容字段。加载时会归一化为 nil；当前文件位置只使用 `imagePath`。
    var importSourcePath: String? = nil
    var importSourceFileID: String? = nil
    var importSourceFileSize: Int64? = nil
    var importSourceModifiedAt: Date? = nil
    // Eagle 式检索元数据。保持为可选字段，旧数据库无需迁移即可继续解码。
    var tags: [String]? = nil
    var rating: Int? = nil
    var isMasterAsset: Bool? = nil
    var sourceURL: String? = nil
    /// 全局素材库中的来源记录；nil 兼容现有项目内资产。
    var materialID: String? = nil
    /// 生成候选的可追溯来源。可选字段确保旧项目数据库无需迁移即可继续打开。
    var generationProvenance: GenerationProvenance? = nil
    var preferredOutputResolution: PreferredOutputResolution? = nil
    var prefers4KOutput: Bool { preferredOutputResolution == .fourK }

    var sourceMissing: Bool { isSourceMissing ?? false }
    var normalizedTags: [String] {
        Array(Set((tags ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
    var starRating: Int { min(5, max(0, rating ?? 0)) }
    var isFavorite: Bool { starRating == 5 }
    var isMaster: Bool { isMasterAsset ?? false }
    var effectiveExportName: String {
        let value = (exportName ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? name : value
    }
    var resolutionLabel: String { ResolutionLabel.label(width: pixelWidth, height: pixelHeight) }
    var dimensionText: String {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return "尺寸待识别" }
        return "\(pixelWidth) × \(pixelHeight)"
    }
    var currentSourceVersion: AssetSourceVersion {
        AssetSourceVersion(
            path: imagePath, filename: originalFilename, fileID: sourceFileID, fileSize: sourceFileSize,
            modifiedAt: sourceModifiedAt, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            addedAt: sourceReplacedAt ?? createdAt
        )
    }
    var allSourceVersions: [AssetSourceVersion] {
        var versions = sourceVersions ?? []
        let current = currentSourceVersion
        if !versions.contains(where: { $0.path == current.path }) { versions.append(current) }
        return versions
    }
}

enum MaterialKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case image = "图片", video = "视频", audio = "音频", font = "字体"
    case document = "文档", projectFile = "工程文件", link = "链接", other = "其他"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .image: "photo"; case .video: "film"; case .audio: "waveform"; case .font: "textformat"
        case .document: "doc.richtext"; case .projectFile: "shippingbox"; case .link: "link"; case .other: "doc"
        }
    }
}

enum ProjectMaterialUse: String, Codable, CaseIterable, Identifiable, Sendable {
    case reference = "参考", candidate = "候选", working = "工作素材"
    var id: String { rawValue }
}

struct MaterialMediaMetadata: Codable, Hashable, Sendable {
    var contentTypeIdentifier: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var durationSeconds: Double?
    var frameCount: Int?
    var frameRate: Double?
    var sampleRate: Double?
    var channelCount: Int?
    var hasAudio: Bool? = nil
    var isPlayable: Bool? = nil
    var issue: String? = nil
}

enum MaterialPresentationKind: String, Sendable {
    case stillImage, animatedImage, video, audio, document, generic
}

/// 全局素材仅记录来源和元数据；不复制、不移动、更不会删除用户原文件。
struct MaterialRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var kind: MaterialKind
    var name: String
    var sourcePath: String?
    var sourceURL: String?
    var originalFilename: String
    var fingerprint: String
    var contentFingerprint: String? = nil
    var duplicateContentOf: String? = nil
    /// 旧版多来源兼容字段。加载后只保留与 `sourcePath` 相同的一项。
    var sourceLocations: [String]
    var fileSize: Int64?
    var sourceCreatedAt: Date? = nil
    var sourceModifiedAt: Date? = nil
    var mediaMetadata: MaterialMediaMetadata? = nil
    var production: MaterialProductionMetadata? = nil
    var createdAt: Date
    var tags: [String]
    var rating: Int
    var note: String
    /// 受控分类（维度 → 标准词）。与自由备注分离；旧记录没有该字段即未分类。
    var classification: MaterialClassification? = nil
    var lastUsedAt: Date? = nil
    var assetType: AssetType? = nil
    var legacyAsset: AssetItem? = nil
    var migrationConflict: String? = nil
    var colorLabel: String? = nil
    var deletedAt: Date? = nil
    var sourceMissing: Bool { kind != .link && fileLocation?.exists != true }
    var presentationKind: MaterialPresentationKind {
        if kind == .video { return .video }
        if kind == .audio { return .audio }
        if kind == .document { return .document }
        if kind == .image {
            return (mediaMetadata?.frameCount ?? 1) > 1 ? .animatedImage : .stillImage
        }
        return .generic
    }
}

/// 删除项目引用不会影响全局素材或任何源文件。
struct ProjectMaterialLink: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var projectID: String
    var materialID: String
    var use: ProjectMaterialUse
    var episode: String? = nil
    var scene: String? = nil
    var shot: String? = nil
    var selection: String? = nil
    var inPoint: Double? = nil
    var outPoint: Double? = nil
    var createdAt: Date
    var note: String = ""
    var subjectID: String? = nil
    var variantID: String? = nil
    var shotID: String? = nil
    var boundFingerprint: String? = nil
    var sourceDocument: String? = nil
    var sourceFingerprint: String? = nil
    var originalPrompt: String? = nil
    var reuseTemplate: String? = nil
    var previousVersions: [Revision]? = nil
    struct Revision: Codable, Hashable, Sendable {
        var materialID: String
        var fingerprint: String?
        var variantID: String?
        var replacedAt: Date
    }
}

enum VariantCandidateDecision: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending = "待定", main = "主图", reference = "补图", unused = "不用"
    var id: String { rawValue }
}

struct AssetEntityRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String; var code: String; var name: String; var type: AssetType
    var createdAt: Date = .now; var updatedAt: Date = .now
}

struct AssetVariantRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String; var entityID: String; var variantName: String; var callCode: String
    var memberAssetIDs: [String]; var coverAssetID: String; var candidateDecisions: [String: VariantCandidateDecision]
    var keyDifference: String?; var doNotMix: String?; var lockedAt: Date?; var version: Int
    var createdAt: Date = .now; var updatedAt: Date = .now

    private enum CodingKeys: String, CodingKey {
        case id, entityID, variantName, callCode, memberAssetIDs, coverAssetID
        case candidateDecisions, keyDifference, doNotMix, lockedAt, version
        case createdAt, updatedAt
        // Schema before entities used this label and may still be present in
        // legacy JSON backups.
        case name, assetVersion
    }

    init(
        id: String, entityID: String, variantName: String, callCode: String,
        memberAssetIDs: [String], coverAssetID: String, candidateDecisions: [String: VariantCandidateDecision],
        keyDifference: String? = nil, doNotMix: String? = nil, lockedAt: Date? = nil, version: Int = 1,
        createdAt: Date = .now, updatedAt: Date = .now
    ) {
        self.id = id; self.entityID = entityID; self.variantName = variantName; self.callCode = callCode
        self.memberAssetIDs = memberAssetIDs; self.coverAssetID = coverAssetID; self.candidateDecisions = candidateDecisions
        self.keyDifference = keyDifference; self.doNotMix = doNotMix; self.lockedAt = lockedAt; self.version = version
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let legacyName = try container.decodeIfPresent(String.self, forKey: .name)
        entityID = try container.decodeIfPresent(String.self, forKey: .entityID) ?? "legacy-\(id)"
        variantName = try container.decodeIfPresent(String.self, forKey: .variantName) ?? legacyName ?? id
        callCode = try container.decodeIfPresent(String.self, forKey: .callCode) ?? id
        memberAssetIDs = try container.decodeIfPresent([String].self, forKey: .memberAssetIDs) ?? []
        coverAssetID = try container.decodeIfPresent(String.self, forKey: .coverAssetID) ?? memberAssetIDs.first ?? ""
        candidateDecisions = try container.decodeIfPresent([String: VariantCandidateDecision].self, forKey: .candidateDecisions)
            ?? Dictionary(uniqueKeysWithValues: memberAssetIDs.map { ($0, .pending) })
        keyDifference = try container.decodeIfPresent(String.self, forKey: .keyDifference)
        doNotMix = try container.decodeIfPresent(String.self, forKey: .doNotMix)
        lockedAt = try container.decodeIfPresent(Date.self, forKey: .lockedAt)
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .version)
        let legacyVersion = try container.decodeIfPresent(Int.self, forKey: .assetVersion)
        version = schemaVersion ?? legacyVersion ?? 1
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(entityID, forKey: .entityID)
        try container.encode(variantName, forKey: .variantName)
        try container.encode(callCode, forKey: .callCode)
        try container.encode(memberAssetIDs, forKey: .memberAssetIDs)
        try container.encode(coverAssetID, forKey: .coverAssetID)
        try container.encode(candidateDecisions, forKey: .candidateDecisions)
        try container.encodeIfPresent(keyDifference, forKey: .keyDifference)
        try container.encodeIfPresent(doNotMix, forKey: .doNotMix)
        try container.encodeIfPresent(lockedAt, forKey: .lockedAt)
        try container.encode(version, forKey: .version)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    init(
        id: String, name: String, coverAssetID: String, memberAssetIDs: [String], createdAt: Date, updatedAt: Date,
        entityID: String, callCode: String, variantName: String, candidateDecisions: [String: VariantCandidateDecision],
        keyDifference: String? = nil, doNotMix: String? = nil, lockedAt: Date? = nil, assetVersion: Int = 1
    ) {
        self.init(id: id, entityID: entityID, variantName: variantName, callCode: callCode, memberAssetIDs: memberAssetIDs,
                  coverAssetID: coverAssetID, candidateDecisions: candidateDecisions, keyDifference: keyDifference,
                  doNotMix: doNotMix, lockedAt: lockedAt, version: assetVersion, createdAt: createdAt, updatedAt: updatedAt)
    }

    /// Backward-compatible initializer used by pre-entity variant records.
    /// The legacy display name is retained as `variantName`; newer identity
    /// fields receive stable, non-empty defaults without affecting Codable data.
    init(
        id: String, name: String, coverAssetID: String, memberAssetIDs: [String],
        createdAt: Date, updatedAt: Date, keyDifference: String? = nil
    ) {
        self.init(
            id: id,
            entityID: "legacy-\(id)",
            variantName: name,
            callCode: id,
            memberAssetIDs: memberAssetIDs,
            coverAssetID: coverAssetID,
            candidateDecisions: Dictionary(uniqueKeysWithValues: memberAssetIDs.map { ($0, .pending) }),
            keyDifference: keyDifference,
            doNotMix: nil,
            lockedAt: nil,
            version: 1,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Compatibility initializer for the intermediate schema that exposed
    /// candidate decisions without the newer entity metadata labels.
    init(
        id: String, name: String, coverAssetID: String, memberAssetIDs: [String],
        createdAt: Date, updatedAt: Date,
        candidateDecisions: [String: VariantCandidateDecision],
        keyDifference: String? = nil
    ) {
        self.init(
            id: id,
            entityID: "legacy-\(id)",
            variantName: name,
            callCode: id,
            memberAssetIDs: memberAssetIDs,
            coverAssetID: coverAssetID,
            candidateDecisions: candidateDecisions,
            keyDifference: keyDifference,
            doNotMix: nil,
            lockedAt: nil,
            version: 1,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
    var isLocked: Bool { lockedAt != nil }
    var decisions: [String: VariantCandidateDecision] { candidateDecisions }
    var count: Int { memberAssetIDs.count }
    var effectiveCallCode: String { callCode }
    var effectiveVariantName: String { variantName }
    var versionText: String { "v\(version)" }
    var requiresExport: Bool { true }
    var name: String { "\(entityID) · \(variantName)" }
    var mainAssetID: String? { memberAssetIDs.first(where: { candidateDecisions[$0] == .main }) }
}
typealias AssetStack = AssetVariantRecord

enum ScriptAssetCandidateStatus: String, Codable, CaseIterable, Sendable {
    case pending = "待确认", confirmed = "已确认", ignored = "已忽略"
}

enum ScriptAssetLinkState: String, Codable, CaseIterable, Sendable {
    case pending = "待匹配", linked = "已绑定", missing = "待补图"
}

struct ScriptAssetCandidate: Identifiable, Codable, Hashable, Sendable {
    var id: String; var name: String; var type: AssetType; var reuse: ReuseGrade
    var appearances: [String]; var evidence: String; var note: String; var status: ScriptAssetCandidateStatus
    var formName: String? = nil; var isRequired: Bool? = nil; var linkedVariantID: String? = nil
    var linkState: ScriptAssetLinkState? = nil; var reviewedAt: Date? = nil; var draftVariantID: String? = nil

    var effectiveFormName: String {
        let value = (formName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "基础" : value
    }
    var isRequiredForProduction: Bool { isRequired ?? true }
    var effectiveLinkState: ScriptAssetLinkState { linkState ?? .pending }
    var formQualifiedName: String { effectiveFormName == "基础" ? name : "\(name)（\(effectiveFormName)）" }
}

struct ScriptExtractionRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String; var sourceName: String; var sourcePath: String; var createdAt: Date
    var textFingerprint: String; var candidates: [ScriptAssetCandidate]
}

struct PendingImportItem: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var stagedPath: String
    var originalSourcePath: String
    var originalFilename: String
    var sourceFileID: String
    var sourceFileSize: Int64
    /// 原文件在文件系统中的创建日期；nil 兼容旧版待确认清单。
    var sourceCreatedAt: Date? = nil
    var sourceModifiedAt: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var contentFingerprint: String? = nil
    var technicalMetadataChecked: Bool? = nil
    var suggestedType: AssetType
    var category: AssetCategory
    var createdAt: Date
    /// 可选字段确保旧版待导入清单可以直接解码。
    var sourceFolderID: String? = nil
    var sourceRelativePath: String? = nil
    var preferredName: String? = nil
    var manualTags: [String]? = nil
    var reviewStatus: PendingReviewStatus? = nil
    var suggestedPurpose: AssetPurpose? = nil
    var generationProvenance: GenerationProvenance? = nil
    var wasPreferredNameManuallyEdited: Bool = false
    /// 本机 Vision 只提供可复核的预填建议，不覆盖人工分类。
    var localVisionType: AssetType? = nil
    var localVisionLabels: [String]? = nil
    var localVisionConfidence: Double? = nil
    var localVisionAnalyzedAt: Date? = nil
    /// 文件名或原路径命中的分类关键词，仅用于解释预填建议。
    var filenameClassificationEvidence: [String]? = nil
    /// 外部视觉模型的可复核建议。建议只随待导入清单保存，不直接改动原文件或正式资产。
    var aiVisionSuggestion: PendingAIAnalysisSuggestion? = nil

    var name: String { let value = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; return value.isEmpty ? URL(fileURLWithPath: originalFilename).deletingPathExtension().lastPathComponent : value }
    var effectiveReviewStatus: PendingReviewStatus { reviewStatus ?? .unreviewed }
    var normalizedManualTags: [String] { Array(Set((manualTags ?? []).filter { !$0.isEmpty })).sorted() }
    var resolutionLabel: String { ResolutionLabel.label(width: pixelWidth, height: pixelHeight) }
    var dimensionText: String {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return "尺寸待识别" }
        return "\(pixelWidth) × \(pixelHeight)"
    }
    var sourceIdentity: String {
        let modifiedSecond = sourceModifiedAt.map { Int64($0.timeIntervalSince1970) } ?? 0
        if !sourceFileID.isEmpty { return "id:\(sourceFileID)|\(sourceFileSize)|\(modifiedSecond)" }
        return "path:\(URL(fileURLWithPath: originalSourcePath).standardizedFileURL.path)|\(sourceFileSize)|\(modifiedSecond)"
    }
    var previewAsset: AssetItem { makePreviewAsset(checkSourceAvailability: true) }

    /// 对比界面在后台加载缩略图；刷新视图时不探测 iCloud 或外置盘。
    func makePreviewAsset(checkSourceAvailability: Bool) -> AssetItem {
        AssetItem(
            id: "PENDING-\(id)", name: name, type: suggestedType, imagePath: stagedPath,
            originalFilename: originalFilename, decision: .pending, note: "", reuse: .b,
            project: "", episodes: [], candidatePlan: .none, version: "v01", purpose: .pending,
            category: category, qaResult: .pending, productionStatus: .pendingAcceptance,
            assetDescription: "", repairReason: "", fingerprint: "", shapeState: "",
            promptSource: "", generationPlatform: "", position: CanvasPoint(x: 0, y: 0),
            createdAt: createdAt, sourceFileSize: sourceFileSize, sourceCreatedAt: sourceCreatedAt,
            sourceModifiedAt: sourceModifiedAt,
            isSourceMissing: checkSourceAvailability ? !FileManager.default.fileExists(atPath: stagedPath) : nil,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight
        )
    }
}

struct PendingAIAnalysisSuggestion: Identifiable, Codable, Hashable, Sendable {
    var id: String { itemID }
    var itemID: String
    var proposedName: String
    var assetType: AssetType
    var styleTags: [String]
    var summary: String
    var confidence: Double
    var analyzedAt: Date
    var modelName: String? = nil
    var decision: PendingAISuggestionDecision? = nil
    /// nil 兼容旧记录；true 表示用户修改建议字段后再采纳。
    var wasEditedByUser: Bool? = nil

    var effectiveDecision: PendingAISuggestionDecision { decision ?? .pending }
    var normalizedConfidence: Double { min(1, max(0, confidence)) }
    var normalizedTags: [String] {
        Array(Set(styleTags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .prefix(8)
            .map(\.self)
    }
}

struct AISuggestionAdoptionSummary: Equatable, Sendable {
    var pending: Int
    var acceptedWithoutChanges: Int
    var acceptedAfterEditing: Int
    var ignored: Int

    var reviewed: Int { acceptedWithoutChanges + acceptedAfterEditing + ignored }
    var adopted: Int { acceptedWithoutChanges + acceptedAfterEditing }
    var adoptionRate: Double { reviewed == 0 ? 0 : Double(adopted) / Double(reviewed) }
}

enum PendingAISuggestionDecision: String, Codable, Hashable, Sendable {
    case pending
    case applied
    case ignored
}

struct AssetGroup: Identifiable, Codable, Hashable, Sendable { var id: String; var episode: String; var name: String; var position: CanvasPoint }
struct AssetRelation: Identifiable, Codable, Hashable, Sendable { var id: String { "\(groupId)::\(assetId)" }; var groupId: String; var assetId: String }
/// Project-scoped data stored either in the legacy JSON document or in the
/// project SQLite database.  The two newer collections intentionally remain
/// optional: an absent key/table means the project predates that feature, not
/// that its contents have been corrupted.
struct LibraryData: Codable, Sendable {
    var assets: [AssetItem]
    var groups: [AssetGroup]
    var relations: [AssetRelation]
    var assetStacks: [AssetStack]?
    var scriptExtractions: [ScriptExtractionRecord]?
    var generationBatches: [GenerationBatchRecord]?

    init(
        assets: [AssetItem],
        groups: [AssetGroup],
        relations: [AssetRelation],
        assetStacks: [AssetStack]? = nil,
        scriptExtractions: [ScriptExtractionRecord]? = nil,
        generationBatches: [GenerationBatchRecord]? = nil
    ) {
        self.assets = assets
        self.groups = groups
        self.relations = relations
        self.assetStacks = assetStacks
        self.scriptExtractions = scriptExtractions
        self.generationBatches = generationBatches
    }

    private enum CodingKeys: String, CodingKey {
        case assets, groups, relations, assetStacks, scriptExtractions, generationBatches
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The original JSON schema did not contain the two optional feature
        // collections.  Empty base collections are also safer than rejecting
        // an older partial export during migration.
        assets = try container.decodeIfPresent([AssetItem].self, forKey: .assets) ?? []
        groups = try container.decodeIfPresent([AssetGroup].self, forKey: .groups) ?? []
        relations = try container.decodeIfPresent([AssetRelation].self, forKey: .relations) ?? []
        assetStacks = try container.decodeIfPresent([AssetStack].self, forKey: .assetStacks)
        scriptExtractions = try container.decodeIfPresent([ScriptExtractionRecord].self, forKey: .scriptExtractions)
        generationBatches = try container.decodeIfPresent([GenerationBatchRecord].self, forKey: .generationBatches)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(assets, forKey: .assets)
        try container.encode(groups, forKey: .groups)
        try container.encode(relations, forKey: .relations)
        try container.encodeIfPresent(assetStacks, forKey: .assetStacks)
        try container.encodeIfPresent(scriptExtractions, forKey: .scriptExtractions)
        try container.encodeIfPresent(generationBatches, forKey: .generationBatches)
    }
}

struct ProjectRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var rootPath: String
    var bookmarkData: Data?
    var databasePath: String
    var isLegacy: Bool
    var lastOpenedAt: Date

    /// 全新安装的中性空库只是启动占位，不代表用户已经链接了内部 Assets 目录。
    var isInitialLibraryPlaceholder: Bool { id == "default-library" && !isLegacy }
}

/// 一个由用户授权并导入的本地目录根。目录树只是镜像，不移动或删除原文件。
struct LocalFolderSource: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var rootPath: String
    var bookmarkData: Data?
    /// 相对于 rootPath 的目录路径；空字符串表示根目录。
    var directoryPaths: [String]
    var createdAt: Date
    var lastScannedAt: Date?

    var sidebarDisplayName: String {
        let path = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        return path.hasPrefix("/Volumes/") ? "\(name) · SSD" : name
    }
}

struct ProjectRegistryData: Codable, Sendable {
    var projects: [ProjectRecord]
    var currentProjectID: String
    /// 已从侧栏移除但尚保留其数据库和工程文件的项目登记。
    var removedProjects: [ProjectRecord]? = nil
}

enum ViewPresentation: Equatable { case table, gallery, attention, trash, exportLibrary, materialLibrary, fiveStarLibrary }
enum SavedView: String, CaseIterable, Identifiable {
    case allGallery = "图片画册", allTable = "资产表格"
    case attention = "待处理"
    case quickReview = "快速筛图", exportLibrary = "导出库"
    case people = "人物资产", venues = "场地资产", props = "道具资产", episode1 = "第1集资产"
    case common = "通用资产", unclassified = "待分类资产", untagged = "未添加标签", pending = "待确认画册"
    case master = "精选母版", favorites = "当前项目五星", globalFavorites = "全部项目五星", recent = "最近添加", recentlyUsed = "最近使用", random = "随机模式", sourceMissing = "源文件缺失"
    case today = "今日新增"
    case confirmed = "已确定使用", rejected = "不用／淘汰历史"
    case trash = "回收站"
    case materialLibrary = "素材总库"
    var id: String { rawValue }
    var presentation: ViewPresentation {
        switch self { case .allTable: .table; case .attention: .attention; case .trash: .trash; case .exportLibrary: .exportLibrary; case .quickReview: .gallery; case .materialLibrary: .materialLibrary; case .favorites, .globalFavorites: .fiveStarLibrary; default: .gallery }
    }
    func includes(_ asset: AssetItem) -> Bool {
        if self == .trash { return asset.deletedAt != nil }
        guard asset.deletedAt == nil else { return false }
        return switch self {
        case .allGallery, .allTable: true
        case .people: asset.type == .person || asset.type == .creature
        case .venues: asset.type == .venue || asset.type == .scene
        case .props: [.prop, .product, .cover, .publishCover, .fixedSymbol, .boundStructure].contains(asset.type)
        case .episode1: asset.episodes.contains("第1集")
        case .common: asset.category == .common
        case .unclassified: asset.type == .unclassified || asset.category == .pending
        case .untagged: asset.normalizedTags.isEmpty
        case .pending: asset.decision == .pending
        case .master: asset.isMaster
        case .favorites: asset.isFavorite
        case .globalFavorites: false
        case .recent: asset.createdAt >= Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
        case .recentlyUsed: asset.lastUsedAt != nil
        case .random: true
        case .today: Calendar.current.isDateInToday(asset.createdAt)
        case .sourceMissing: asset.sourceMissing
        case .confirmed: asset.decision == .confirmed
        case .rejected: asset.decision == .rejected || asset.productionStatus == .eliminated
        case .attention, .trash, .exportLibrary, .quickReview, .materialLibrary: false
        }
    }
}

// Optional production envelope keeps pre-media libraries decodable.
struct MaterialProductionMetadata: Codable, Hashable, Sendable {
    var purpose: String = "未指定"
    var review: String = "待审核"
    var versionGroupID: String? = nil
    var versionName: String = "v01"
    var prompt: String = ""
    var platform: String = ""
    var model: String = ""
    var batch: String = ""
    var inputMaterialIDs: [String] = []
    var licenseNote: String = ""
    var provenance: GenerationProvenance? = nil
    var coverSeconds: Double? = nil
    var isCommon: Bool = false
    var managedCopies: [String] = []
}

struct MaterialSearchFilter: Codable, Hashable, Sendable {
    var search = ""
    /// `nil` means every field, preserving old saved filters.
    var searchFields: Set<MaterialSearchField>? = nil
    var kinds: Set<MaterialKind> = []
    var formats: Set<String> = []
    var purpose = "全部"
    var minimumRating = 0
    var minimumDuration: Double? = nil
    var maximumDuration: Double? = nil
    var orientation = "全部"
    var minimumPixels = 0
    var projectOnly = false
    var commonOnly = false
    var requiredTags: Set<String>? = nil
    var folderPaths: Set<String>? = nil
    var colorLabels: Set<String>? = nil
    var exactRating: Int? = nil
    /// 维度 → 要命中的受控分类词；维度之间是「且」，同维度多选是「或」。
    var classificationFilters: [String: Set<String>]? = nil

    /// Count dimensions, not selected values. Search text and its field scope
    /// belong to the search control, not to the facet reset action.
    var activeFacetCount: Int {
        [!kinds.isEmpty, !formats.isEmpty, purpose != "全部",
         minimumRating > 0 || exactRating != nil,
         minimumDuration != nil || maximumDuration != nil,
         orientation != "全部", minimumPixels > 0, projectOnly, commonOnly,
         !(requiredTags ?? []).isEmpty, !(folderPaths ?? []).isEmpty,
         !(colorLabels ?? []).isEmpty,
         !(classificationFilters ?? [:]).values.allSatisfy { $0.isEmpty }].filter { $0 }.count
    }

    mutating func resetFacets() {
        let query = search
        let fields = searchFields
        self = MaterialSearchFilter()
        search = query
        searchFields = fields
    }

    mutating func selectOnly(kind: MaterialKind?) {
        kinds = kind.map { [$0] } ?? []
        // A previous extension such as JPG must not make “only video” empty.
        formats.removeAll()
    }
}

struct MaterialFilterPreset: Identifiable, Codable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var filter: MaterialSearchFilter
}

// A library owns organization; projects are scopes, not additional material stores.
struct LibraryOrganization: Identifiable, Codable, Hashable, Sendable {
    var id: String = "organization"
    var projects: [ProjectRecord] = []
    var folders: [LocalFolderSource] = []
    var folderProjects: [String: [String]] = [:]
    var legacyMapping: [String: String] = [:]
    var legacyPayloads: [String: Data] = [:]
    var exportNames: [String: String] = [:]
}


enum MaterialSortField: String, Codable, CaseIterable, Identifiable, Sendable {
    case imported = "添加日期", modified = "修改日期", created = "创建日期", name = "标题"
    case format = "扩展名", size = "文件大小", resolution = "尺寸", rating = "评分"
    case duration = "时长", recentlyUsed = "最近使用", random = "随机模式"
    var id: Self { self }
}
struct MaterialSortOrder: Codable, Hashable, Sendable {
    var field: MaterialSortField = .imported
    var ascending = false
    /// 随机排序需要稳定种子，保证一次浏览期间不会因界面重绘而不断跳位。
    var randomSeed: UInt64? = nil
}
