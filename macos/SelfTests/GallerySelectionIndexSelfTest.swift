import Foundation

@main
struct GallerySelectionIndexSelfTest {
    static func main() {
        let ids = (0..<5_000).map { "asset-\($0)" }
        let index = GallerySelectionIndex(orderedIDs: ids)

        precondition(index.indexes(for: ["asset-2", "asset-4999"]) == IndexSet([2, 4_999]))
        precondition(index.indexes(for: ["missing"]).isEmpty)

        let start = DispatchTime.now().uptimeNanoseconds
        var checksum = 0
        for offset in 0..<2_000 {
            checksum += index.indexes(for: ["asset-\(offset % ids.count)"]).first ?? 0
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        precondition(checksum > 0)
        precondition(milliseconds < 100, "2,000 次单选索引转换超过 100ms")
        print(String(format: "Gallery selection index benchmark passed: %.2f ms", milliseconds))
    }
}
