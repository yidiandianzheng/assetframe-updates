import Foundation

@main
struct BrowsePerformanceTraceSelfTest {
    @MainActor static func main() throws {
        let qa = CommandLine.arguments.contains("qa")
        precondition(BrowsePerformanceTrace.enabled == qa)
        BrowsePerformanceTrace.startSampling()
        BrowsePerformanceTrace.beginSelection()
        BrowsePerformanceTrace.completeSelection()
        BrowsePerformanceTrace.beginPreview("unit-test")
        BrowsePerformanceTrace.completePreview("different-id")
        BrowsePerformanceTrace.completePreview("unit-test")
        if qa { RunLoop.main.run(until: Date.now.addingTimeInterval(0.08)) }
        BrowsePerformanceTrace.finish()
        BrowsePerformanceTrace.record("must-not-record-after-finish")
        if qa {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ASSETFRAME_QA_DATA_ROOT"]!)
            let data = try String(contentsOf: root.appendingPathComponent("browse-metrics.jsonl"), encoding: .utf8)
            precondition(data.contains("session_start") && data.contains("main_loop_tick") && data.contains("process_memory"))
            precondition(data.contains("preview_draw_complete") && data.contains("session_end"))
            precondition(!data.contains("must-not-record-after-finish"))
        }
        print("BrowsePerformanceTraceSelfTest passed: \(qa ? "QA logger and stopped-session isolation" : "production disabled")")
    }
}
