import Foundation

@main
struct ThumbnailLoadProgressSelfTest {
    @MainActor
    static func main() async {
        let progress = ThumbnailLoadProgressModel()
        progress.begin(contextID: "gallery-a", keys: ["a", "b", "c", "d"])
        precondition(progress.isVisible)
        precondition(progress.total == 4 && progress.completed == 0)
        precondition(progress.estimatedRemainingSeconds == nil)

        progress.complete(key: "a", succeeded: true)
        progress.complete(key: "b", succeeded: false)
        precondition(progress.completed == 2 && progress.failed == 1)
        precondition(progress.fraction == 0.5)
        progress.complete(key: "unknown", succeeded: true)
        precondition(progress.completed == 2, "重复或无关完成事件不能污染进度")

        let estimate = ThumbnailLoadProgressModel.estimateSeconds(elapsed: 4, completed: 2, remaining: 3)
        precondition(estimate == 6)
        progress.complete(key: "c", succeeded: true)
        progress.complete(key: "d", succeeded: true)
        precondition(progress.fraction == 1)
        precondition(progress.estimatedRemainingSeconds == 0)

        progress.begin(contextID: "gallery-a", keys: ["e", "f"])
        precondition(progress.total == 2 && progress.completed == 0, "新一轮预读应从零开始")
        progress.begin(contextID: "gallery-b", keys: ["e"])
        precondition(progress.total == 1 && progress.completed == 0, "切换画册必须重置旧进度")
        print("ThumbnailLoadProgressSelfTest passed")
    }
}
