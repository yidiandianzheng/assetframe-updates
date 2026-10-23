import SwiftUI

struct PendingReviewActionBar: View {
    @AppStorage(ReviewShortcutSettings.previousKeyDefaultsKey)
    private var previousKeyRawValue = ReviewShortcutSettings.defaultPreviousKey.rawValue
    @AppStorage(ReviewShortcutSettings.previousModifiersDefaultsKey)
    private var previousModifiersRawValue = ReviewShortcutSettings.defaultPreviousModifiers.rawValue
    @AppStorage(ReviewShortcutSettings.keepKeyDefaultsKey)
    private var keepKeyRawValue = ReviewShortcutSettings.defaultKeepKey.rawValue
    @AppStorage(ReviewShortcutSettings.keepModifiersDefaultsKey)
    private var keepModifiersRawValue = ReviewShortcutSettings.defaultKeepModifiers.rawValue
    @AppStorage(ReviewShortcutSettings.discardKeyDefaultsKey)
    private var discardKeyRawValue = ReviewShortcutSettings.defaultDiscardKey.rawValue
    @AppStorage(ReviewShortcutSettings.discardModifiersDefaultsKey)
    private var discardModifiersRawValue = ReviewShortcutSettings.defaultDiscardModifiers.rawValue

    let canSelectPrevious: Bool
    let canSelectNext: Bool
    let isCurrentKept: Bool
    let isCurrentDiscarded: Bool
    let isBusy: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onKeep: () -> Void
    let onTrash: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("上一张  \(previousShortcutDisplayName)", systemImage: "chevron.left", action: onPrevious)
                .keyboardShortcut(previousKey.keyEquivalent, modifiers: previousModifiers)
                .disabled(!canSelectPrevious || isBusy)
                .background {
                    Button(action: onPrevious) { EmptyView() }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .disabled(!canSelectPrevious || isBusy)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            Button("下一张", systemImage: "chevron.right", action: onNext)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!canSelectNext || isBusy)
            Text("快捷键：\(previousShortcutDisplayName) 上一张 · \(keepShortcutDisplayName) 确认保留 · \(shortcutDisplayName) 删除")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if isCurrentKept {
                Label("当前已保留", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if isCurrentDiscarded {
                Label("当前已标为废片", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            Button("保留并下一张  \(keepShortcutDisplayName)", systemImage: "checkmark.circle.fill", action: onKeep)
                .keyboardShortcut(keepKey.keyEquivalent, modifiers: keepModifiers)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(isBusy)
                .help("快捷键 \(keepShortcutDisplayName)")
            Button(role: .destructive, action: onTrash) {
                Label("删除并下一张  \(shortcutDisplayName)", systemImage: "trash")
            }
            .keyboardShortcut(discardKey.keyEquivalent, modifiers: discardModifiers)
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)
            .help("快捷键 \(shortcutDisplayName)；将当前原图移到 macOS 系统废纸篓，可在废纸篓恢复")
            SettingsLink {
                Label("快捷键设置", systemImage: "keyboard")
            }
            .help("修改快速筛图快捷键")
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var previousKey: ReviewShortcutKey {
        ReviewShortcutKey(rawValue: previousKeyRawValue) ?? ReviewShortcutSettings.defaultPreviousKey
    }

    private var previousModifiers: EventModifiers {
        EventModifiers(rawValue: previousModifiersRawValue)
    }

    private var previousShortcutDisplayName: String {
        ReviewShortcutSettings.displayName(key: previousKey, modifiers: previousModifiers)
    }

    private var keepKey: ReviewShortcutKey {
        ReviewShortcutKey(rawValue: keepKeyRawValue) ?? ReviewShortcutSettings.defaultKeepKey
    }

    private var keepModifiers: EventModifiers {
        EventModifiers(rawValue: keepModifiersRawValue)
    }

    private var keepShortcutDisplayName: String {
        ReviewShortcutSettings.displayName(key: keepKey, modifiers: keepModifiers)
    }

    private var discardKey: ReviewShortcutKey {
        ReviewShortcutKey(rawValue: discardKeyRawValue) ?? ReviewShortcutSettings.defaultDiscardKey
    }

    private var discardModifiers: EventModifiers {
        EventModifiers(rawValue: discardModifiersRawValue)
    }

    private var shortcutDisplayName: String {
        ReviewShortcutSettings.displayName(key: discardKey, modifiers: discardModifiers)
    }
}
