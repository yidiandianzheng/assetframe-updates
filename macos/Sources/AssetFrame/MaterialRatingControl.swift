import SwiftUI

struct MaterialRatingControl: View {
    @ObservedObject var store: GlobalMaterialStore
    let material: MaterialRecord
    let project: ProjectRecord

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { rating in
                let selected = material.rating == rating
                Button {
                    store.rate([material.id], rating: rating, project: project)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: selected ? "star.fill" : "star")
                        Text("\(rating)")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(selected ? .orange : .gray)
                .accessibilityLabel("评为 \(rating) 星")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}
