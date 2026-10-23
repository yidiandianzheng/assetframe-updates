import SwiftUI

struct GlobalFiveStarCardGrid: View {
    let records: [GlobalFiveStarRecord]
    let project: ProjectRecord
    @Binding var selectedIDs: Set<String>
    let onPreview: (String) -> Void
    let onReveal: (String) -> Void
    let onCopyOriginalImage: (String) -> Void
    let onCopyPath: (String) -> Void
    let projectActionTitle: (String) -> String?
    let onProjectAction: (String) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 238, maximum: 310), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(records) { record in
                    GlobalFiveStarCard(
                        record: record,
                        project: project,
                        isSelected: selectedIDs.contains(record.id),
                        onToggleSelection: { toggleSelection(record.id) },
                        onPreview: { onPreview(record.id) },
                        onReveal: { onReveal(record.id) },
                        onCopyOriginalImage: { onCopyOriginalImage(record.id) },
                        onCopyPath: { onCopyPath(record.id) },
                        projectActionTitle: projectActionTitle(record.id),
                        onProjectAction: { onProjectAction(record.id) }
                    )
                }
            }
            .padding(12)
        }
        .background(GraphiteTheme.canvas)
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}
