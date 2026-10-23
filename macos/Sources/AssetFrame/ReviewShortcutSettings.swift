import SwiftUI

enum ReviewShortcutSettings {
    static let previousKeyDefaultsKey = "shortcuts.pendingReview.previous.key"
    static let previousModifiersDefaultsKey = "shortcuts.pendingReview.previous.modifiers"
    static let keepKeyDefaultsKey = "shortcuts.pendingReview.keep.key"
    static let keepModifiersDefaultsKey = "shortcuts.pendingReview.keep.modifiers"
    static let discardKeyDefaultsKey = "shortcuts.pendingReview.discard.key"
    static let discardModifiersDefaultsKey = "shortcuts.pendingReview.discard.modifiers"
    private static let keepKeyMigrationDefaultsKey = "shortcuts.pendingReview.keep.migrated-r-to-w.v1"

    static let defaultPreviousKey = ReviewShortcutKey.q
    static let defaultPreviousModifiers: EventModifiers = []
    static let defaultKeepKey = ReviewShortcutKey.w
    static let defaultKeepModifiers: EventModifiers = []
    static let defaultDiscardKey = ReviewShortcutKey.e
    static let defaultDiscardModifiers: EventModifiers = []

    /// 将旧版默认的 R 保留键升级为 W；用户自行设置过的组合保持不变。
    static func migrateLegacyDefaultKeepKey(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: keepKeyMigrationDefaultsKey) else { return }
        defer { defaults.set(true, forKey: keepKeyMigrationDefaultsKey) }

        let storedKey = defaults.string(forKey: keepKeyDefaultsKey)
        let storedModifiers = defaults.object(forKey: keepModifiersDefaultsKey) as? UInt ?? 0
        if storedKey == ReviewShortcutKey.r.rawValue && storedModifiers == defaultKeepModifiers.rawValue {
            defaults.set(defaultKeepKey.rawValue, forKey: keepKeyDefaultsKey)
        }
    }

    static func displayName(key: ReviewShortcutKey, modifiers: EventModifiers) -> String {
        let symbols = [
            modifiers.contains(.control) ? "⌃" : "",
            modifiers.contains(.option) ? "⌥" : "",
            modifiers.contains(.shift) ? "⇧" : "",
            modifiers.contains(.command) ? "⌘" : ""
        ].joined()
        return symbols + key.displayName
    }
}

enum ReviewShortcutKey: String, CaseIterable, Identifiable {
    case delete
    case returnKey
    case space
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    case zero, one, two, three, four, five, six, seven, eight, nine

    var id: String { rawValue }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .delete: .delete
        case .returnKey: .return
        case .space: .space
        case .zero: "0"
        case .one: "1"
        case .two: "2"
        case .three: "3"
        case .four: "4"
        case .five: "5"
        case .six: "6"
        case .seven: "7"
        case .eight: "8"
        case .nine: "9"
        default: KeyEquivalent(Character(rawValue))
        }
    }

    var displayName: String {
        switch self {
        case .delete: "⌫"
        case .returnKey: "↩"
        case .space: "空格"
        case .zero: "0"
        case .one: "1"
        case .two: "2"
        case .three: "3"
        case .four: "4"
        case .five: "5"
        case .six: "6"
        case .seven: "7"
        case .eight: "8"
        case .nine: "9"
        default: rawValue.uppercased()
        }
    }

    static var groupedChoices: [(String, [ReviewShortcutKey])] {
        [
            ("常用按键", [.delete, .returnKey, .space]),
            ("字母", allCases.filter { $0.rawValue.count == 1 }),
            ("数字", [.zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine])
        ]
    }
}
