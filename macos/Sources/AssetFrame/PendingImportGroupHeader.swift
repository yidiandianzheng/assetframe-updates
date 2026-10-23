import SwiftUI

struct PendingImportGroupHeader: View {
    let group: PendingImportListGroup

    var body: some View {
        HStack {
            Label(
                group.title,
                systemImage: group.isCodexGeneration ? "sparkles.rectangle.stack" : "tray"
            )
            .font(.headline)
            Text(group.subtitle)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(group.items.count) 项")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
