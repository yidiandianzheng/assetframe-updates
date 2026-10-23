import Foundation

@main struct GalleryContentIndexSelfTest {
    struct Record: Identifiable, Equatable { let id: Int; var name: String }
    static func main() {
        var records = (0..<5_000).map { Record(id: $0, name: "素材 \($0)") }
        var index = GalleryContentIndex<Record>()
        precondition(index.update(records, revision: 1).count == 5_000)
        var samples: [Double] = []
        for _ in 0..<100 {
            let start = Date.now
            precondition(index.update(records, revision: 1).isEmpty)
            samples.append(Date.now.timeIntervalSince(start) * 1_000)
        }
        precondition(index.rebuildCount == 1, "Selection-only updates must not scan or rebuild")
        records[2].name = "已更新"
        precondition(index.update(records, revision: 2) == [2])
        precondition(index.byID[2]?.name == "已更新")
        records.reverse()
        _ = index.update(records, revision: 3)
        precondition(index.orderedIDs.first == 4_999)
        records[0].name = "兼容调用"
        precondition(index.update(records, revision: nil) == [4_999])
        _ = index.update([], revision: 4)
        precondition(index.byID.isEmpty && index.orderedIDs.isEmpty)
        print(String(format: "GalleryContentIndexSelfTest passed: unchanged revision P95=%.4fms (index only; not frame latency)", samples.sorted()[94]))
    }
}
