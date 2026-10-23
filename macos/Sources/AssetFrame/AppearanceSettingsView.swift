import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var appearanceRawValue = AppAppearance.defaultValue.rawValue

    private var appearance: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceRawValue) ?? .defaultValue },
            set: { appearanceRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Picker("外观", selection: appearance) {
                ForEach(AppAppearance.allCases) { option in
                    Label(option.displayName, systemImage: option.systemImage)
                        .tag(option)
                }
            }
            .pickerStyle(.radioGroup)

            Text(appearance.wrappedValue.detail)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420, height: 230)
        .navigationTitle("外观")
    }
}
