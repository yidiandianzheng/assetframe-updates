import Foundation

@main
struct ImportProgressEstimatorSelfTest {
    static func main() {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        var estimator = ImportProgressEstimator()

        precondition(estimator.estimate(jobID: id, isActive: true, isCompleted: false, processed: 0, total: 100, at: start) == nil)
        precondition(estimator.estimate(jobID: id, isActive: true, isCompleted: false, processed: 1, total: 100, at: start.addingTimeInterval(0.5)) == nil)
        let first = estimator.estimate(jobID: id, isActive: true, isCompleted: false, processed: 10, total: 100, at: start.addingTimeInterval(1))
        precondition(first != nil && first! > 8 && first! < 10)

        let smoothed = estimator.estimate(jobID: id, isActive: true, isCompleted: false, processed: 11, total: 100, at: start.addingTimeInterval(2))
        precondition(smoothed != nil && smoothed! < 20, "单个慢样本不应让 ETA 突然失真")
        precondition(estimator.estimate(jobID: id, isActive: false, isCompleted: true, processed: 100, total: 100, at: start.addingTimeInterval(10)) == 0)

        let nextID = UUID()
        precondition(estimator.estimate(jobID: nextID, isActive: true, isCompleted: false, processed: 1, total: 5, at: start.addingTimeInterval(20)) == nil, "新任务必须重新估算")
        print("ImportProgressEstimatorSelfTest passed")
    }
}
