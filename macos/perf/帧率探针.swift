// 窗口内容更新率探针（外部测量，不改 App）。
//
//   帧率探针 --window <CGWindowID> --seconds 10 [--out <jsonl>] [--sample-stride 16]
//
// 原理：用系统自带的 ScreenCaptureKit 抓目标窗口，逐帧对窗口中部区域做抽样哈希；
// 哈希变了就记一帧「内容更新」，并写下该帧的显示时间戳（PTS，mach 绝对时间）。
// 由此得到帧间隔序列 → 平均帧率、中位帧间隔、最差 1% 帧间隔（1% low 帧率）。
//
// 口径边界（报告里要写清）：
// - 探针只能看到「窗口内容真的变了」的帧，上限是显示器刷新率与采集帧率里的较低者；
//   所以 summary 里同时给出 delivered_fps（采集到的帧率）作为上限。
// - 采集本身不驱动 App 渲染，也不改变 App 的布局代码路径。
// - 需要「屏幕录制」授权；没授权时抓到的是全黑画面，changed 会是 0，
//   所以 summary 里给出 mean_luma 供判断（接近 0 说明没抓到真实内容）。
import AVFoundation
import AppKit
import CoreVideo
import Foundation
import ScreenCaptureKit

struct Options {
    var windowID = 0
    var seconds = 10.0
    var outPath = ""
    var stride = 16
    var captureWidth = 1280
    var fps = 60
    var useDisplay = false
    static func parse() -> Options {
        var options = Options()
        let arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index + 1 < arguments.count {
            let key = arguments[index]
            let value = arguments[index + 1]
            switch key {
            case "--window": options.windowID = Int(value) ?? 0
            case "--seconds": options.seconds = Double(value) ?? 10
            case "--out": options.outPath = value
            case "--sample-stride": options.stride = max(1, Int(value) ?? 16)
            case "--capture-width": options.captureWidth = max(160, Int(value) ?? 1280)
            case "--fps": options.fps = max(1, Int(value) ?? 60)
            case "--display": options.useDisplay = value == "1" || value == "true"
            default: break
            }
            index += 2
        }
        return options
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("探针失败：" + message + "\n").utf8))
    exit(2)
}

final class Sink {
    private let handle: FileHandle?
    init(path: String) {
        if path.isEmpty { handle = nil; return }
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }
    func line(_ object: [String: Any]) {
        guard let handle else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }
}

final class Delegate: NSObject, SCStreamOutput, SCStreamDelegate {
    let sink: Sink
    let strideBytes: Int
    var previousHash: UInt64 = 0
    var hasPrevious = false
    var delivered = 0
    var changed = 0
    var changeTimes: [Double] = []
    var lumaSum = 0.0
    var lumaSamples = 0
    let startedWall = Date().timeIntervalSince1970

    init(sink: Sink, strideBytes: Int) { self.sink = sink; self.strideBytes = strideBytes }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferGetNumSamples(sampleBuffer) == 1,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        delivered += 1
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = presentation.isValid ? CMTimeGetSeconds(presentation) : 0
                CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { return }
        let width = CVPixelBufferGetBytesPerRow(image) / 4
        let height = CVPixelBufferGetHeight(image)
        // 中部区域：横向 20%~80%、纵向 30%~70%，避开标题栏、侧栏和右侧详情面板。
        let left = width * 20 / 100, right = width * 80 / 100
        let top = height * 30 / 100, bottom = height * 70 / 100
        var hash: UInt64 = 0xcbf29ce484222325
        var luma = 0.0
        var count = 0
        let step = strideBytes / 4 * 4
        base.withMemoryRebound(to: UInt8.self, capacity: CVPixelBufferGetDataSize(image)) { bytes in
            for y in stride(from: top, to: bottom, by: 4) {
                let row = bytes + y * CVPixelBufferGetBytesPerRow(image)
                var x = left
                while x < right {
                    let p = row + x * 4
                    let b = Double(p[0]), g = Double(p[1]), r = Double(p[2])
                    luma += 0.114 * b + 0.587 * g + 0.299 * r
                    count += 1
                    // 只取部分字节参与哈希，保证 60Hz 下每帧开销在亚毫秒级。
                    hash ^= UInt64(p[0]); hash = hash &* 0x100000001b3
                    hash ^= UInt64(p[2]); hash = hash &* 0x100000001b3
                    x += max(1, step)
                }
            }
        }
        if count > 0 { lumaSum += luma / Double(count); lumaSamples += 1 }

        if hasPrevious && hash != previousHash {
            changed += 1
            changeTimes.append(seconds)
            sink.line(["event": "change", "pts": seconds, "delivered": delivered,
                       "wall": Date().timeIntervalSince1970])
        }
        previousHash = hash; hasPrevious = true
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("采集中断：\(error)\n".utf8))
    }
}

// 无 UI 的命令行工具也要先建立 WindowServer 连接，否则 ScreenCaptureKit 会在 CGS_REQUIRE_INIT 断言退出。
_ = NSApplication.shared
let options = Options.parse()
guard options.windowID > 0 else { fail("需要 --window") }

let semaphore = DispatchSemaphore(value: 0)
var shareable: SCShareableContent?
var shareableError: Error?
SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
    shareable = content
    shareableError = error
    semaphore.signal()
}
semaphore.wait()
if let shareableError { fail("读取可采集内容失败：\(shareableError)") }
guard let content = shareable else { fail("读取可采集内容返回空") }
let targetWindow: SCWindow? = content.windows.first { Int($0.windowID) == options.windowID }
if !options.useDisplay && targetWindow == nil { fail("窗口 \(options.windowID) 不在可采集列表里（可能被最小化或无屏幕录制授权）") }
guard options.useDisplay || targetWindow != nil else { fail("采集源不可用") }

// 采集按宽度缩放到 captureWidth（默认 1280）：原尺寸 5120×2632 的 BGRA 帧约 43MB，
// 60Hz 采不动，实测会被压到 10fps；缩小后能跑满显示器刷新率，缩放不影响「内容变了没有」的判断。
let configuration = SCStreamConfiguration()
let sourceFrame = options.useDisplay ? (content.displays.first?.frame ?? .zero) : (targetWindow?.frame ?? .zero)
let aspect = sourceFrame.height / max(1, sourceFrame.width)
configuration.width = options.captureWidth
configuration.height = max(2, Int(round(Double(options.captureWidth) * Double(aspect))))
configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(options.fps))
configuration.queueDepth = 12
configuration.pixelFormat = kCVPixelFormatType_32BGRA
configuration.showsCursor = false

let sink = Sink(path: options.outPath)
let delegate = Delegate(sink: sink, strideBytes: options.stride)
let filter: SCContentFilter
if options.useDisplay, let display = content.displays.first {
    filter = SCContentFilter(display: display, excludingWindows: [])
} else {
    filter = SCContentFilter(desktopIndependentWindow: targetWindow!)
}
let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
do {
    try stream.addStreamOutput(delegate, type: .screen,
                               sampleHandlerQueue: DispatchQueue(label: "probe.sample", qos: .userInitiated))
    try stream.startCapture()
} catch { fail("启动采集失败：\(error)") }

let start = Date()
while Date().timeIntervalSince(start) < options.seconds { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
let captureSeconds = max(0.001, Date().timeIntervalSince(start))
stream.stopCapture()

let intervals: [Double] = zip(delegate.changeTimes.dropFirst(), delegate.changeTimes).map { $0 - $1 }
let sortedIntervals = intervals.sorted()
func percentile(_ p: Double) -> Double? {
    guard !sortedIntervals.isEmpty else { return nil }
    let index = min(sortedIntervals.count - 1, Int(Double(sortedIntervals.count - 1) * p))
    return sortedIntervals[index]
}
let worstCount = max(1, Int(Double(intervals.count) * 0.01))
let worstAverage = intervals.isEmpty ? nil : sortedIntervals.suffix(worstCount).reduce(0, +) / Double(worstCount)

func milliseconds(_ seconds: Double?) -> Any {
    guard let seconds else { return NSNull() }
    return round(seconds * 1_000_000) / 1000
}
var summary: [String: Any] = [:]
summary["event"] = "summary"
summary["window"] = options.windowID
summary["capture_size"] = "\(configuration.width)x\(configuration.height)"
summary["requested_fps"] = options.fps
summary["requested_seconds"] = options.seconds
summary["capture_seconds"] = round(captureSeconds * 1000) / 1000
summary["delivered_frames"] = delegate.delivered
summary["delivered_fps"] = round(Double(delegate.delivered) / captureSeconds * 100) / 100
summary["changed_frames"] = delegate.changed
summary["avg_fps"] = round(Double(delegate.changed) / captureSeconds * 100) / 100
summary["median_interval_ms"] = milliseconds(percentile(0.5))
summary["p95_interval_ms"] = milliseconds(percentile(0.95))
summary["p99_interval_ms"] = milliseconds(percentile(0.99))
summary["worst1pct_avg_interval_ms"] = milliseconds(worstAverage)
summary["worst1pct_fps"] = worstAverage == nil ? NSNull() : round(1 / worstAverage! * 100) / 100
summary["mean_luma"] = delegate.lumaSamples == 0 ? NSNull() : round(delegate.lumaSum / Double(delegate.lumaSamples) * 100) / 100
summary["start_wall"] = round(delegate.startedWall * 1000) / 1000
summary["end_wall"] = round(Date().timeIntervalSince1970 * 1000) / 1000
let data = try! JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
sink.line(summary)
