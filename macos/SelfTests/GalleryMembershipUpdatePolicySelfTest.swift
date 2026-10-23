import Foundation

@main
struct GalleryMembershipUpdatePolicySelfTest {
    static func main() {
        func accepts(_ old: [String], _ next: [String], first: Bool = false,
                     navigation: Bool = false, geometry: Bool = false, aspects: Bool = false) -> Bool {
            GalleryMembershipUpdatePolicy.canInsertInPlace(previousIDs: old, nextIDs: next,
                firstPopulation: first, navigationChanged: navigation,
                geometryChanged: geometry, aspectRatiosChanged: aspects)
        }
        precondition(accepts(["A", "B"], ["C", "A", "B"]))
        precondition(accepts(["A", "B"], ["A", "C", "B"]))
        precondition(accepts(["A", "B"], ["A", "B", "C"]))
        precondition(accepts([], (0..<2_000).map(String.init), first: true, navigation: true))
        precondition(!accepts([], ["A"], navigation: true))
        precondition(!accepts(["A", "B"], ["B", "A", "C"]))
        precondition(!accepts(["A", "B"], ["A", "C"]))
        precondition(!accepts(["A", "B"], ["A"]))
        precondition(!accepts(["A"], []))
        precondition(!accepts(["A"], ["A", "B"], navigation: true))
        precondition(!accepts(["A"], ["A", "B"], geometry: true))
        precondition(!accepts(["A"], ["A", "B"], aspects: true))
        precondition(!accepts(["A"], ["A", "B", "B"]))
        precondition(!accepts(["A", "A"], ["A", "B", "C"]))
        precondition(!accepts(["A"], ["A"] + (0..<129).map(String.init)))
        precondition(!accepts(["A"], ["A"] + (0..<128).map(String.init)))
        print("GalleryMembershipUpdatePolicySelfTest passed: first population and bounded head/middle/tail inserts; navigation, removals, reorder, geometry and duplicates use replacement")
    }
}
