// 探针自校准用的 60Hz 动画窗口（只服务 QA 脚本，不进 App）。
//
//   校准动画 --seconds 6 [--size 400]
//
// 立刻打印自己的 CGWindowID，然后每 1/60 秒改一次图层内容和颜色。
// 用它跑一遍帧率探针，如果探针能测到接近 60fps，说明探针本身没有把上限压低；
// 之后测 App 得到的低帧率就是 App 自己的呈现节奏。
import AppKit
import QuartzCore

var seconds = 6.0
var size = 400
let arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index + 1 < arguments.count {
    if arguments[index] == "--seconds" { seconds = Double(arguments[index + 1]) ?? 6 }
    if arguments[index] == "--size" { size = Int(arguments[index + 1]) ?? 400 }
    index += 2
}

setbuf(stdout, nil)

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: size, height: size * 3 / 4),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "AF校准动画"
window.backgroundColor = .black
window.makeKeyAndOrderFront(nil)
window.orderFrontRegardless()

let host = NSView(frame: window.contentView!.bounds)
host.wantsLayer = true
host.layer?.backgroundColor = NSColor.white.cgColor
window.contentView?.addSubview(host)
let moving = CALayer()
moving.bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
moving.position = CGPoint(x: 40, y: 40)
moving.backgroundColor = NSColor.red.cgColor
host.layer?.addSublayer(moving)

print("{\"window\": \(window.windowNumber), \"seconds\": \(seconds)}")

var tick = 0
let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
    tick += 1
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    moving.position = CGPoint(x: 40 + CGFloat(tick % max(80, size - 80)), y: 40 + CGFloat((tick / 3) % 60))
    moving.backgroundColor = (tick % 2 == 0 ? NSColor.red : NSColor.systemBlue).cgColor
    CATransaction.commit()
}
RunLoop.main.add(timer, forMode: .common)
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    print("{\"stopped\": true, \"ticks\": \(tick)}")
    exit(0)
}
app.run()
