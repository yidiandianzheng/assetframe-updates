import Foundation

/// Bounded insertion reuse requires the coordinator's hosted-surface scrub.
/// Other membership/geometry changes retain container replacement.
enum GalleryMembershipUpdatePolicy {
    static func canInsertInPlace(
        previousIDs: [String], nextIDs: [String],
        firstPopulation: Bool, navigationChanged: Bool,
        geometryChanged: Bool, aspectRatiosChanged: Bool
    ) -> Bool {
        guard !geometryChanged, !aspectRatiosChanged,
              nextIDs.count > previousIDs.count else { return false }
        if firstPopulation && previousIDs.isEmpty {
            return Set(nextIDs).count == nextIDs.count
        }
        guard !navigationChanged, !previousIDs.isEmpty else { return false }
        // Retained IDs must keep their relative order. Larger membership changes
        // continue to use the established container replacement path.
        let old = Set(previousIDs), next = Set(nextIDs)
        return next.count == nextIDs.count && old.count == previousIDs.count
            && old.isSubset(of: next) && next.count - old.count <= 32
            && nextIDs.filter { old.contains($0) } == previousIDs
    }
}
