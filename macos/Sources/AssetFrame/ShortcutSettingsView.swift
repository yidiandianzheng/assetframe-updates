import SwiftUI

struct ShortcutSettingsView: View {
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

    private var discardKey: Binding<ReviewShortcutKey> {
        Binding(
            get: { ReviewShortcutKey(rawValue: discardKeyRawValue) ?? ReviewShortcutSettings.defaultDiscardKey },
            set: { discardKeyRawValue = $0.rawValue }
        )
    }

    private var previousKey: Binding<ReviewShortcutKey> {
        Binding(
            get: { ReviewShortcutKey(rawValue: previousKeyRawValue) ?? ReviewShortcutSettings.defaultPreviousKey },
            set: { previousKeyRawValue = $0.rawValue }
        )
    }

    private var previousModifiers: EventModifiers {
        EventModifiers(rawValue: previousModifiersRawValue)
    }

    private var keepKey: Binding<ReviewShortcutKey> {
        Binding(
            get: { ReviewShortcutKey(rawValue: keepKeyRawValue) ?? ReviewShortcutSettings.defaultKeepKey },
            set: { keepKeyRawValue = $0.rawValue }
        )
    }

    private var keepModifiers: EventModifiers {
        EventModifiers(rawValue: keepModifiersRawValue)
    }

    private var discardModifiers: EventModifiers {
        EventModifiers(rawValue: discardModifiersRawValue)
    }

    var body: some View {
        Section("快速筛图快捷键") {
            LabeledContent("回到上一张") {
                HStack(spacing: 8) {
                    previousModifierToggle("⌃", modifier: .control, help: "Control")
                    previousModifierToggle("⌥", modifier: .option, help: "Option")
                    previousModifierToggle("⇧", modifier: .shift, help: "Shift")
                    previousModifierToggle("⌘", modifier: .command, help: "Command")
                    keyPicker(selection: previousKey)
                }
            }

            HStack {
                Text("当前快捷键：\(ReviewShortcutSettings.displayName(key: previousKey.wrappedValue, modifiers: previousModifiers))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认") {
                    previousKeyRawValue = ReviewShortcutSettings.defaultPreviousKey.rawValue
                    previousModifiersRawValue = ReviewShortcutSettings.defaultPreviousModifiers.rawValue
                }
            }

            LabeledContent("保留并下一张") {
                HStack(spacing: 8) {
                    keepModifierToggle("⌃", modifier: .control, help: "Control")
                    keepModifierToggle("⌥", modifier: .option, help: "Option")
                    keepModifierToggle("⇧", modifier: .shift, help: "Shift")
                    keepModifierToggle("⌘", modifier: .command, help: "Command")
                    keyPicker(selection: keepKey)
                }
            }

            HStack {
                Text("当前快捷键：\(ReviewShortcutSettings.displayName(key: keepKey.wrappedValue, modifiers: keepModifiers))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认") {
                    keepKeyRawValue = ReviewShortcutSettings.defaultKeepKey.rawValue
                    keepModifiersRawValue = ReviewShortcutSettings.defaultKeepModifiers.rawValue
                }
            }

            LabeledContent("删除并下一张") {
                HStack(spacing: 8) {
                    modifierToggle("⌃", modifier: .control, help: "Control")
                    modifierToggle("⌥", modifier: .option, help: "Option")
                    modifierToggle("⇧", modifier: .shift, help: "Shift")
                    modifierToggle("⌘", modifier: .command, help: "Command")

                    keyPicker(selection: discardKey)
                }
            }

            HStack {
                Text("当前快捷键：\(ReviewShortcutSettings.displayName(key: discardKey.wrappedValue, modifiers: discardModifiers))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认") {
                    discardKeyRawValue = ReviewShortcutSettings.defaultDiscardKey.rawValue
                    discardModifiersRawValue = ReviewShortcutSettings.defaultDiscardModifiers.rawValue
                }
            }

            Text("修改后立即生效，仅在“快速筛图”页面触发；删除会将当前原图移到 macOS 系统废纸篓，可在废纸篓恢复。")
                .foregroundStyle(.secondary)
        }
    }

    private func previousModifierToggle(
        _ title: String,
        modifier: EventModifiers,
        help: String
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { previousModifiers.contains(modifier) },
                set: { enabled in
                    var updated = previousModifiers
                    if enabled {
                        updated.insert(modifier)
                    } else {
                        updated.remove(modifier)
                    }
                    previousModifiersRawValue = updated.rawValue
                }
            )
        )
        .toggleStyle(.button)
        .help(help)
    }

    private func keyPicker(selection: Binding<ReviewShortcutKey>) -> some View {
        Picker("按键", selection: selection) {
            ForEach(ReviewShortcutKey.groupedChoices, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { key in
                        Text(key.displayName).tag(key)
                    }
                }
            }
        }
        .labelsHidden()
        .frame(width: 92)
    }

    private func keepModifierToggle(
        _ title: String,
        modifier: EventModifiers,
        help: String
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { keepModifiers.contains(modifier) },
                set: { enabled in
                    var updated = keepModifiers
                    if enabled {
                        updated.insert(modifier)
                    } else {
                        updated.remove(modifier)
                    }
                    keepModifiersRawValue = updated.rawValue
                }
            )
        )
        .toggleStyle(.button)
        .help(help)
    }

    private func modifierToggle(
        _ title: String,
        modifier: EventModifiers,
        help: String
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { discardModifiers.contains(modifier) },
                set: { enabled in
                    var updated = discardModifiers
                    if enabled {
                        updated.insert(modifier)
                    } else {
                        updated.remove(modifier)
                    }
                    discardModifiersRawValue = updated.rawValue
                }
            )
        )
        .toggleStyle(.button)
        .help(help)
    }
}
