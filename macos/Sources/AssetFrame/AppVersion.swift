import Foundation

enum AppVersion {
    static var shortVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? display }
    static let fallbackBuild = "DEV"

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? fallbackBuild
    }

    static var display: String { "V\(build)" }

    /// Display-only label; keep build identifiers unchanged in feedback/updates.
    static var annotatedDisplay: String {
        // recordedBuilds 是历史数组，含一处重复（261013.2）且缺 261017–261018 若干构建，
        // 不能再用下标直接当累计版号；近期已发布版号以交付记录为准显式登记。
        if let ordinal = documentedOrdinals[build] { return "\(display) · 累计第\(ordinal)版" }
        guard let index = recordedBuilds.firstIndex(of: build) else { return display }
        return "\(display) · 累计第\(index + 1)版"
    }

    /// 近期已安装/已交付版本的累计版号（真源：CHANGELOG 与安装记录）。
    private static let documentedOrdinals: [String: Int] = [
        "261022.1": 104,
        "261023.1": 105,
        "261023.2": 106,
    ]

    // Distinct documented builds, including candidates, oldest first.
    // Evidence: ProductValidation/20261012_版本累计与用量/versions.json
    // Subsequent builds are documented in CHANGELOG.md.
    private static let recordedBuilds: [String] = [
        "260713",
        "260714",
        "260714.1",
        "260714.2",
        "260714.3",
        "260714.4",
        "260714.5",
        "260714.6",
        "260714.7",
        "260714.8",
        "260806.1",
        "260827.1",
        "260827.2",
        "260827.3",
        "260827.4",
        "260828",
        "260828.1",
        "260828.2",
        "260828.3",
        "260828.4",
        "260828.5",
        "260828.6",
        "260828.7",
        "260828.8",
        "260828.9",
        "260828.10",
        "260828.11",
        "260828.12",
        "260828.13",
        "260828.14",
        "260828.15",
        "260828.16",
        "260828.17",
        "260828.18",
        "260828.19",
        "260828.20",
        "260828.21",
        "260829.1",
        "260829.2",
        "260829.3",
        "260829.4",
        "260829.5",
        "260829.6",
        "260830.1",
        "260830.2",
        "260830.3",
        "260831.1",
        "260905.1",
        "260905.2",
        "260905.3",
        "260906.1",
        "260907.1",
        "260907.2",
        "260907.3",
        "260907.4",
        "260907.5",
        "260907.6",
        "260907.7",
        "260907.8",
        "260907.9",
        "260907.10",
        "260907.11",
        "260908.1",
        "260908.2",
        "260908.3",
        "260908.4",
        "260908.5",
        "260908.6",
        "260908.7",
        "260908.8",
        "260908.9",
        "260908.10",
        "260908.11",
        "260908.12",
        "260908.13",
        "260908.14",
        "260908.15",
        "260909.1",
        "260909.2",
        "260910.1",
        "260910.2",
        "260910.3",
        "260912.1",
        "260922.1",
        "260926.1",
        "261008.3",
        "261011.1",
        "261011.2",
        "261011.3",
        "261011.4",
        "261012.1",
        "261012.2",
        "261012.3",
        "261012.4",
        "261012.5",
        "261012.6",
        "261012.7",
        "261012.8",
        "261013.1",
        "261013.2",
        "261013.2",
        "261013.3",
        "261022.1",
        "261023.1",
    ]
}
