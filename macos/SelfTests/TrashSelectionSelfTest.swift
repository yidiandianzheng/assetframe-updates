import CoreGraphics
import Foundation

@main
struct TrashSelectionSelfTest {
    static func main() {
        let frames = [
            "A": CGRect(x: 0, y: 0, width: 100, height: 100),
            "B": CGRect(x: 120, y: 0, width: 100, height: 100),
            "C": CGRect(x: 240, y: 0, width: 100, height: 100)
        ]

        let leftToRight = TrashSelectionLogic.rectangle(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 210, y: 90))
        precondition(leftToRight == CGRect(x: 10, y: 10, width: 200, height: 80))
        precondition(TrashSelectionLogic.intersectingIDs(in: leftToRight, frames: frames) == ["A", "B"])

        let rightToLeft = TrashSelectionLogic.rectangle(from: CGPoint(x: 330, y: 90), to: CGPoint(x: 130, y: 10))
        precondition(rightToLeft == CGRect(x: 130, y: 10, width: 200, height: 80))
        precondition(TrashSelectionLogic.intersectingIDs(in: rightToLeft, frames: frames) == ["B", "C"])

        precondition(TrashSelectionLogic.selectionAfterClick(id: "B", current: ["A"], commandPressed: false) == ["B"])
        precondition(TrashSelectionLogic.selectionAfterClick(id: "B", current: ["A"], commandPressed: true) == ["A", "B"])
        precondition(TrashSelectionLogic.selectionAfterClick(id: "A", current: ["A", "B"], commandPressed: true) == ["B"])

        precondition(TrashSelectionLogic.selectionDuringDrag(initial: ["C"], intersecting: ["A", "B"], commandPressed: false) == ["A", "B"])
        precondition(TrashSelectionLogic.selectionDuringDrag(initial: ["A", "C"], intersecting: ["A", "B"], commandPressed: true) == ["B", "C"])

        print("Trash marquee selection self-test passed")
    }
}
