import Foundation

struct GlobalFiveStarRecord: Identifiable, Hashable, Sendable {
    var id: String
    var asset: AssetItem
    var sources: [GlobalFiveStarSource]
    var linkedProjectIDs: Set<String>

    func belongs(to projectID: String) -> Bool {
        sources.contains { $0.projectID == projectID } || linkedProjectIDs.contains(projectID)
    }

    func isOwned(by projectID: String) -> Bool {
        sources.contains { $0.projectID == projectID }
    }

    func isFiveStarAvailable(to projectID: String) -> Bool {
        let hasFiveStarSource = sources.contains { $0.asset.starRating == 5 }
        return sources.contains { $0.projectID == projectID && $0.asset.starRating == 5 }
            || (linkedProjectIDs.contains(projectID) && hasFiveStarSource)
    }

    var isReusableTemplate: Bool {
        sources.contains { $0.asset.isMaster }
    }

    var sourceProjectNames: [String] {
        Array(Set(sources.map(\.projectName))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var galleryAsset: AssetItem {
        var copy = asset
        copy.id = id
        return copy
    }
}
