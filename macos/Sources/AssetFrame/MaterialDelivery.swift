import Foundation

/// Copies complete, explicitly selected versions; time ranges are metadata, never destructive edits.
enum MaterialDelivery {
    static func folder(for material: MaterialRecord) -> String {
        switch material.kind {
        case .image: "图片"
        case .video: "视频"
        case .audio:
            switch material.production?.purpose {
            case "配音": "配音"
            case "BGM": "音乐"
            case "音效", "环境声": "音效"
            default: "音频"
            }
        default: "其他"
        }
    }
    static func safe(_ text: String) -> String {
        let cleaned = text.components(separatedBy: CharacterSet(charactersIn: "/\\:<>\"|?*\n\r\t")).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "未命名" : String(cleaned.prefix(100))
    }
    static func export(materials: [MaterialRecord], links: [ProjectMaterialLink], projectID: String, destination: URL) throws -> URL {
        let selected = links.filter { $0.projectID == projectID && $0.selection == "选用" }
        guard !selected.isEmpty else { throw MaterialDatabase.error("当前项目没有明确选用的版本") }
        let lookup = Dictionary(uniqueKeysWithValues: materials.map { ($0.id, $0) })
        for link in selected {
            guard let m = lookup[link.materialID], m.deletedAt == nil, let path = m.sourcePath,
                  FileManager.default.isReadableFile(atPath: path), !m.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MaterialDatabase.error("选用素材缺失、未命名或无读取权限，未开始导出")
            }
            if let issue = m.mediaMetadata?.issue { throw MaterialDatabase.error("\(m.name)：\(issue)") }
            let start = link.inPoint ?? 0
            guard start.isFinite, start >= 0 else { throw MaterialDatabase.error("使用区间无效") }
            if let end = link.outPoint {
                guard let duration = m.mediaMetadata?.durationSeconds, end.isFinite, end > start, end <= duration else { throw MaterialDatabase.error("使用区间超过素材时长") }
            }
        }
        let fm = FileManager.default
        let output = destination.appendingPathComponent("生产素材交付-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let staging = destination.appendingPathComponent(".assetframe-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var rows: [[String]] = [["素材ID", "名称", "媒体类型", "用途", "集数", "场次", "镜头", "选用版本", "入点秒", "出点秒", "原文件", "输出文件", "SHA256", "来源", "授权备注", "平台", "模型", "批次", "提示词", "输入素材ID", "主体ID", "造型ID", "镜头ID", "分镜原文", "分镜指纹", "复用模板"]]
        var copied: [String: (String, String)] = [:]
        for link in selected {
            guard let m = lookup[link.materialID], let path = m.sourcePath else { continue }
            if copied[m.id] == nil {
                let subfolder = folder(for: m)
                let dir = staging.appendingPathComponent(subfolder, isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let filename = safe(m.name) + "_" + safe(m.production?.versionName ?? "v01") + "_" + safe(m.id) + "." + (m.originalFilename as NSString).pathExtension
                let target = dir.appendingPathComponent(filename)
                guard let expectedHash = GlobalMaterialStore.verifiedContentFingerprint(m) else { throw MaterialDatabase.error("原文件已变化或不可读取") }
                try fm.copyItem(at: URL(fileURLWithPath: path), to: target)
                guard let hash = GlobalMaterialStore.streamFingerprint(target), hash == expectedHash,
                      GlobalMaterialStore.streamFingerprint(URL(fileURLWithPath: path)) == hash else { throw MaterialDatabase.error("\(m.name) 内容已变化，导出已停止，请作为新版本导入") }
                copied[m.id] = (subfolder + "/" + filename, hash)
            }
            let copy = copied[m.id]!
            if let expected = link.boundFingerprint, expected != copy.1 { throw MaterialDatabase.error("镜头绑定版本的文件指纹已变化，未导出") }
            rows.append([m.id, m.name, m.kind.rawValue, m.production?.purpose ?? "未指定", link.episode ?? "", link.scene ?? "", link.shot ?? "", m.production?.versionName ?? "v01", link.inPoint.map(String.init(describing:)) ?? "", link.outPoint.map(String.init(describing:)) ?? "", path, copy.0, copy.1, m.sourceURL ?? "", m.production?.licenseNote ?? "", m.production?.platform ?? "", m.production?.model ?? "", m.production?.batch ?? "", link.originalPrompt ?? m.production?.prompt ?? "", m.production?.inputMaterialIDs.joined(separator: ";") ?? "", link.subjectID ?? "", link.variantID ?? "", link.shotID ?? "", link.sourceDocument ?? "", link.sourceFingerprint ?? "", link.reuseTemplate ?? ""])
        }
        let csv = rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n")
        try ("\u{FEFF}" + csv).write(to: staging.appendingPathComponent("生产素材清单.csv"), atomically: true, encoding: .utf8)
        try fm.moveItem(at: staging, to: output)
        return output
    }
    private static func csvField(_ raw: String) -> String {
        // Text cells stay text when opened in a spreadsheet.
        let value = ["=", "+", "-", "@"].contains(raw.first.map(String.init) ?? "") ? "'" + raw : raw
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
