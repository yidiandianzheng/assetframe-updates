import Foundation

@main
struct AppAppearanceSelfTest {
    static func main() {
        precondition(AppAppearance.defaultValue == .graphite, "首次安装必须默认使用石墨黑")
        precondition(AppAppearance.allCases == [.graphite, .system, .light])
        precondition(AppAppearance.graphite.displayName == "石墨黑")
        precondition(!AppAppearance.graphite.detail.isEmpty)
        print("AppAppearanceSelfTest passed")
    }
}
