import Foundation

enum GalleryContextSelection {
    static func actionIDs(clickedID: String, selectedIDs: Set<String>) -> Set<String> {
        selectedIDs.contains(clickedID) ? selectedIDs : [clickedID]
    }
}
