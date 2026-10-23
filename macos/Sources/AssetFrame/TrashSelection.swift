import CoreGraphics
import SwiftUI

enum TrashSelectionLogic {
    static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    static func intersectingIDs(in selectionRect: CGRect, frames: [String: CGRect]) -> Set<String> {
        Set(frames.compactMap { id, frame in
            selectionRect.intersects(frame) ? id : nil
        })
    }

    static func selectionAfterClick(id: String, current: Set<String>, commandPressed: Bool) -> Set<String> {
        guard commandPressed else { return [id] }
        return current.symmetricDifference([id])
    }

    static func selectionDuringDrag(
        initial: Set<String>,
        intersecting: Set<String>,
        commandPressed: Bool
    ) -> Set<String> {
        commandPressed ? initial.symmetricDifference(intersecting) : intersecting
    }
}

struct TrashCardFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
