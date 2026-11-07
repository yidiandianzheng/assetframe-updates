// 测量用的界面驱动小工具（只服务 QA 脚本，不进 App、不参与打包）。
//
//   界面驱动 windows --pid <pid>              列出该进程的窗口（CGWindowID + 名字 + 尺寸）
//   界面驱动 raise --pid <pid> --window <id>  激活并把窗口提到最前
//   界面驱动 scroll --window <id> --dy <像素> --steps <次> --interval <秒>
//   界面驱动 key --pid <pid> --code <键码> --count <次> --interval <秒>
//   界面驱动 key --pid <pid> --code 5 --flags 4608   带修饰键（cmd=4096 shift=512，即 ⌘⇧G）
//   界面驱动 type --pid <pid> --text <文本>          往当前焦点输入 Unicode 文本（中文路径可用）
//   界面驱动 press --pid <pid> --text <按钮标题片段>   后台按 AXPress 点按钮
//   界面驱动 press --pid <pid> --text <标题> --role AXMenuItem --index -1   换控件类型/选第几个同名控件
//   界面驱动 settext --pid <pid> --index -1 --value <文本>   给输入框赋值并回读
//   界面驱动 texts --pid <pid> [--contains <片段>]   列出窗口里的静态文本（界面文字证据）
//
// 滚动用 CGEvent 投到窗口中心点，因此测量前窗口必须可见且在最前（先跑 raise）。
import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func argument(_ name: String, _ arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "--" + name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func doubleArgument(_ name: String, _ arguments: [String], fallback: Double) -> Double {
    guard let raw = argument(name, arguments), let value = Double(raw) else { return fallback }
    return value
}

func intArgument(_ name: String, _ arguments: [String], fallback: Int) -> Int {
    guard let raw = argument(name, arguments), let value = Int(raw) else { return fallback }
    return value
}

func jsonLine(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? ""
let rest = Array(arguments.dropFirst())

func onScreenWindows(of pid: Int32, includeOffscreen: Bool = false) -> [[String: Any]] {
    let option: CGWindowListOption = includeOffscreen ? .optionAll : .optionOnScreenOnly
    let list = (CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]]) ?? []
    return list.filter { ($0[kCGWindowOwnerPID as String] as? Int).map { Int32($0) == pid } ?? false }
}

func windowRecord(_ window: [String: Any]) -> [String: Any] {
    let bounds = (window[kCGWindowBounds as String] as? [String: Any]) ?? [:]
    return [
        "id": window[kCGWindowNumber as String] ?? 0,
        "name": window[kCGWindowName as String] ?? "",
        "layer": window[kCGWindowLayer as String] ?? 0,
        "x": bounds["X"] ?? 0, "y": bounds["Y"] ?? 0,
        "width": bounds["Width"] ?? 0, "height": bounds["Height"] ?? 0,
    ]
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let children = value as? [AXUIElement] else { return [] }
    return children
}

func axRole(_ element: AXUIElement) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
          let role = value as? String else { return "" }
    return role
}

func axSubrole(_ element: AXUIElement) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success,
          let subrole = value as? String else { return "" }
    return subrole
}

/// 广度优先收集所有匹配角色（可选次级角色）的元素，深度受限避免遍历整棵树。
func axFindAll(_ root: AXUIElement, role: String, subrole: String = "", maxDepth: Int = 24) -> [AXUIElement] {
    var found: [AXUIElement] = []
    var level: [AXUIElement] = [root]
    var depth = 0
    while !level.isEmpty && depth < maxDepth {
        for element in level where axRole(element) == role && (subrole.isEmpty || axSubrole(element) == subrole) {
            found.append(element)
        }
        level = level.flatMap { axChildren($0) }
        depth += 1
    }
    return found
}

func axArea(_ element: AXUIElement) -> Double {
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let size = sizeValue, CFGetTypeID(size) == AXValueGetTypeID() else { return 0 }
    var cgSize = CGSize.zero
    AXValueGetValue(size as! AXValue, .cgSize, &cgSize)
    return Double(cgSize.width * cgSize.height)
}

/// 广度优先找第一个匹配角色（可选次级角色）的元素，深度受限避免遍历整棵树。
func axFind(_ root: AXUIElement, role: String, subrole: String = "", maxDepth: Int = 24) -> AXUIElement? {
    var level: [AXUIElement] = [root]
    var depth = 0
    while !level.isEmpty && depth < maxDepth {
        for element in level {
            if axRole(element) == role && (subrole.isEmpty || axSubrole(element) == subrole) { return element }
        }
        level = level.flatMap { axChildren($0) }
        depth += 1
    }
    return nil
}

func axAllWindows(_ pid: Int32) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return [] }
    return windows
}

func axWidth(_ element: AXUIElement) -> Double {
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let size = sizeValue, CFGetTypeID(size) == AXValueGetTypeID() else { return 0 }
    var cgSize = CGSize.zero
    AXValueGetValue(size as! AXValue, .cgSize, &cgSize)
    return Double(cgSize.width)
}

func biggestWindow(_ pid: Int32) -> AXUIElement? { axAllWindows(pid).max { axWidth($0) < axWidth($1) } }

func axString(_ element: AXUIElement, _ attribute: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
    return value as? String ?? ""
}

func axLabel(_ element: AXUIElement) -> String {
    [axString(element, kAXTitleAttribute), axString(element, kAXDescriptionAttribute),
     axString(element, kAXIdentifierAttribute), axString(element, kAXHelpAttribute)]
        .filter { !$0.isEmpty }.joined(separator: "|")
}

switch command {
case "unhide":
    // 安静模式：只取消隐藏，不 activate、不提序，焦点留在用户当前窗口。
    guard let raw = argument("pid", rest), let pid = Int32(raw) else { die("需要 --pid") }
    let applicationElement = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(applicationElement, kAXHiddenAttribute as CFString, kCFBooleanFalse)
    jsonLine(["unhidden": true, "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? ""])

case "axscroll":
    // 后台滚动：直接设垂直滚动条的百分比，不需要窗口在最前，也不碰鼠标键盘。
    guard let raw = argument("pid", rest), let pid = Int32(raw) else { die("需要 --pid") }
    let percent = doubleArgument("percent", rest, fallback: 50)
    guard let window = biggestWindow(pid) else { die("读不到 AX 窗口（需要辅助功能授权，且窗口不能处于隐藏）") }
    // 窗口里有多个滚动区（侧栏、分类栏、图库），面积最大的那个才是图库。
    let areas = axFindAll(window, role: "AXScrollArea")
    guard !areas.isEmpty else { die("窗口里找不到 AXScrollArea") }
    var reports: [[String: Any]] = []
    for area in areas.sorted(by: { axArea($0) > axArea($1) }) {
        var applied = ""
        if let bar = axFind(area, role: "AXScrollBar", subrole: "AXVerticalScrollBar", maxDepth: 6) {
            if AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: percent)) == .success {
                applied = "AXScrollBar"
            }
        }
        if applied.isEmpty {
            var point = CGPoint(x: 0, y: percent)
            if let value = AXValueCreate(.cgPoint, &point),
               AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, value) == .success {
                applied = "AXScrollArea"
            }
        }
        reports.append(["area": axArea(area), "applied": applied])
        if !applied.isEmpty { break }
    }
    jsonLine(["scrolled_to_percent": percent, "scroll_areas": reports.count, "attempts": reports])

case "axselect":
    // 后台选侧栏文件夹行：AXOutline 的第 index 行设为选中，等价于点一下但不抢焦点。
    guard let raw = argument("pid", rest), let pid = Int32(raw) else { die("需要 --pid") }
    let index = intArgument("index", rest, fallback: 0)
    guard let window = biggestWindow(pid) else { die("读不到 AX 窗口") }
    guard let outline = axFind(window, role: "AXOutline") else { die("窗口里找不到 AXOutline（侧栏文件夹树）") }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(outline, kAXRowsAttribute as CFString, &value) == .success,
          let rows = value as? [AXUIElement], index < rows.count else { die("取不到第 \(index) 行") }
    let error = AXUIElementSetAttributeValue(outline, kAXSelectedRowsAttribute as CFString, [rows[index]] as CFArray)
    var title = ""
    var cellValue: CFTypeRef?
    if AXUIElementCopyAttributeValue(rows[index], kAXTitleAttribute as CFString, &cellValue) == .success { title = (cellValue as? String) ?? "" }
    jsonLine(["selected_row": index, "row_title": title, "set_error": error.rawValue, "rows_total": rows.count])

case "press":
    // 后台点按钮：按标题/描述/标识找到控件并 AXPress，不依赖屏幕坐标，也不抢焦点。
    guard let raw = argument("pid", rest), let pid = Int32(raw) else { die("需要 --pid") }
    guard let target = argument("text", rest) else { die("需要 --text") }
    let role = argument("role", rest) ?? "AXButton"
    let depth = intArgument("depth", rest, fallback: 40)
    let appRoot = AXUIElementCreateApplication(pid) as AXUIElement
    // 菜单项/复选框不是 AXButton，用 --role 换一类控件（如 AXMenuItem、AXCheckBox）。
    // 先扫最大窗口，找不到再扫整个 App：「待确认」箱与弹层菜单是另一个窗口，只查主窗口会一个都点不到。
    func head(_ label: String) -> String { label.split(separator: "|").first.map(String.init) ?? "" }
    var matches: [(AXUIElement, String)] = []
    var scanned = 0
    for root in [biggestWindow(pid) ?? appRoot, appRoot] where matches.isEmpty {
        let found = axFindAll(root, role: role, maxDepth: depth)
        scanned = found.count
        let labelled = found.map { ($0, axLabel($0)) }
        // 优先标题字段完全相等或以「目标、」开头（文件夹行的标题是「名称、数量」），
        // 否则退回包含匹配——包含会先撞上「展开 xx」这类箭头按钮。
        let exact = labelled.filter { head($0.1) == target || head($0.1).hasPrefix(target + "、") }
        matches = exact.isEmpty ? labelled.filter { $0.1.contains(target) } : exact
    }
    // 同名控件并存时（卡片上的「改名后采纳」和弹层里的默认按钮）用 --index 选第几个，-1 表示最后一个。
    let wanted = intArgument("index", rest, fallback: 0)
    let chosenIndex = wanted < 0 ? matches.count + wanted : wanted
    guard matches.indices.contains(chosenIndex) else {
        jsonLine(["pressed": false, "text": target, "reason": "index_out_of_range", "matches": matches.count,
                  "wanted": wanted, "buttons": scanned,
                  "sample": matches.prefix(12).map { $0.1 }])
        exit(2)
    }
    let chosen = matches[chosenIndex].0
    // 把「为什么点不动」写清楚：SwiftUI 里 .disabled(true) 的按钮 AXPress 会回 -25204，
    // 光看 code 分不清是控件不存在、被禁用，还是 App 没响应，所以顺手读 AXEnabled。
    var enabledValue: CFTypeRef?
    let enabledError = AXUIElementCopyAttributeValue(chosen, kAXEnabledAttribute as CFString, &enabledValue)
    let enabled = (enabledValue as? Bool).map { ["read": true, "value": $0, "error": enabledError.rawValue] }
        ?? ["read": false, "error": enabledError.rawValue]
    let error = AXUIElementPerformAction(chosen, kAXPressAction as CFString)
    jsonLine(["pressed": error == .success, "code": error.rawValue, "text": target, "index": chosenIndex,
              "label": matches[chosenIndex].1, "matches": matches.count, "buttons": scanned,
              "enabled": enabled,
              "matchedLabels": matches.prefix(6).map { $0.1 },
              "mode": matches.allSatisfy { head($0.1) == target || head($0.1).hasPrefix(target + "、") } ? "exact" : "contains"])

case "settext":
    // 给输入框赋值：SwiftUI 的 TextField 在 AX 里是 AXTextField，值就是文本。
    // 从 App 根节点找，弹层（sheet）里的输入框才不会被主窗口尺寸过滤掉；--index -1 取最后一个。
    guard let raw = argument("pid", rest), let pid = Int32(raw) else { die("需要 --pid") }
    guard let value = argument("value", rest) else { die("需要 --value") }
    let app = AXUIElementCreateApplication(pid) as AXUIElement
    let fields = axFindAll(app, role: "AXTextField", maxDepth: intArgument("depth", rest, fallback: 40))
        + axFindAll(app, role: "AXTextArea", maxDepth: intArgument("depth", rest, fallback: 40))
    let wanted = intArgument("index", rest, fallback: -1)
    let chosenIndex = wanted < 0 ? fields.count + wanted : wanted
    guard fields.indices.contains(chosenIndex) else {
        jsonLine(["set": false, "reason": "index_out_of_range", "fields": fields.count, "wanted": wanted])
        exit(2)
    }
    // 赋值前把每个框的原值带出来，便于确认改到的是弹层里那个框而不是工具栏搜索框。
    let before = fields.map { (axString($0, kAXValueAttribute)) }
    let error = AXUIElementSetAttributeValue(fields[chosenIndex], kAXValueAttribute as CFString, value as CFString)
    var readBack: CFTypeRef?
    AXUIElementCopyAttributeValue(fields[chosenIndex], kAXValueAttribute as CFString, &readBack)
    jsonLine(["set": error == .success, "code": error.rawValue, "index": chosenIndex, "fields": fields.count,
              "values_before": before, "wanted_value": value, "read_back": (readBack as? String) ?? ""])

case "windows":
    guard let raw = argument("pid", rest), let pid = Int32(raw) else { die("需要 --pid") }
    for window in onScreenWindows(of: pid, includeOffscreen: rest.contains("--all")) {
        jsonLine(windowRecord(window))
    }

case "raise":
    guard let raw = argument("pid", rest), let pid = Int32(raw) else { die("需要 --pid") }
    guard let application = NSRunningApplication(processIdentifier: pid) else { die("进程不存在: \(pid)") }
    application.activate()
    // 从命令行/脚本起来的实例常常处于「隐藏」状态，窗口不在屏上列表里；先取消隐藏再提到最前。
    let applicationElement = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(applicationElement, kAXHiddenAttribute as CFString, kCFBooleanFalse)
    var value: CFTypeRef?
    var chosen: AXUIElement?
    if AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &value) == .success,
       let windows = value as? [AXUIElement], !windows.isEmpty {
        chosen = windows.max { axWidth($0) < axWidth($1) }
        if let chosen {
            AXUIElementPerformAction(chosen, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, chosen)
        }
    }
    let wantedWidth = argument("width", rest).flatMap(Double.init)
    var target: [String: Any]?
    for _ in 0..<60 {
        let onScreen = onScreenWindows(of: pid)
        let candidates = onScreen.filter { (($0[kCGWindowLayer as String] as? Int) ?? 0) == 0 }
        target = candidates.max {
            (($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0)
                < (($1[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0)
        }
        if let target, let wantedWidth,
           let actual = (target[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double,
           abs(actual - wantedWidth) > 2 { continue }
        if target != nil { break }
        usleep(50_000)
    }
    guard let window = target else { die("找不到在屏窗口（辅助功能授权或窗口未创建）") }
    jsonLine(windowRecord(window).merging(["raised": true]) { current, _ in current })

case "scroll":
    guard let raw = argument("window", rest), let windowID = Int(raw) else { die("需要 --window") }
    guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
          let first = info.first,
          let bounds = first[kCGWindowBounds as String] as? [String: Any],
          let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
          let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat
    else { die("窗口不可见: \(windowID)") }

    let step = doubleArgument("dy", rest, fallback: 120)
    let steps = intArgument("steps", rest, fallback: 1)
    let interval = doubleArgument("interval", rest, fallback: 0.016)
    // 默认落在窗口中心略偏上；图库在不同窗口宽度下位置会变，用 --fx/--fy 指定窗口内的比例。
    let fx = doubleArgument("fx", rest, fallback: 0.5)
    let fy = doubleArgument("fy", rest, fallback: 0.45)
    let point = CGPoint(x: x + width * CGFloat(fx), y: y + height * CGFloat(fy))
    // AppKit 把滚轮事件投给「真实光标所在」的视图，只设 event.location 不够，
    // 所以先把光标移到窗口中心，测完再移回原位。
    let original = CGEvent(source: nil)?.location ?? point
    if !rest.contains("--no-warp") {
        CGWarpMouseCursorPosition(point)
        // 解除绑定，否则下一个硬件移动会把光标拉回用户手边，滚轮就打到别的 App 上。
        CGAssociateMouseAndMouseCursorPosition(rest.contains("--keep-associed") ? 1 : 0)
        if let moved = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            moved.post(tap: .cghidEventTap)
        }
        usleep(120_000)
    }
    let cursorNow = CGEvent(source: nil)?.location ?? point
    let tap: CGEventTapLocation = rest.contains("--session-tap") ? .cgSessionEventTap : .cghidEventTap
    let start = Date()
    for index in 0..<steps {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(step), wheel2: 0, wheel3: 0) else {
            die("无法创建滚动事件")
        }
        event.location = point
        event.post(tap: tap)
        if interval > 0 { usleep(UInt32(interval * 1_000_000)) }
        if index == 0 { FileHandle.standardError.write(Data("first scroll at \(Date().timeIntervalSince1970)\n".utf8)) }
    }
    if !rest.contains("--no-warp") {
        CGAssociateMouseAndMouseCursorPosition(1)
        CGWarpMouseCursorPosition(original)
    }
    jsonLine(["posted_scrolls": steps, "dy_each": step, "window": windowID,
              "scroll_point": [point.x, point.y], "cursor_after_warp": [cursorNow.x, cursorNow.y],
              "warped": !rest.contains("--no-warp"), "tap": rest.contains("--session-tap") ? "session" : "hid",
              "elapsed_seconds": Date().timeIntervalSince(start),
              "start_wall": start.timeIntervalSince1970, "end_wall": Date().timeIntervalSince1970])

case "buttons":
    // 列出窗口里某类控件的可访问标签（默认 AXButton，可用 --role 换 AXMenuButton／AXPopUpButton），供脚本挑要点的行。
    guard let raw = argument("pid", rest), let pid = Int32(raw) else { die("需要 --pid") }
    let role = argument("role", rest) ?? "AXButton"
    let appRoot = AXUIElementCreateApplication(pid) as AXUIElement
    var seen: Set<String> = []
    for root in [biggestWindow(pid) ?? appRoot, appRoot] {
        for (_, label) in axFindAll(root, role: role, maxDepth: 40).map({ ($0, axLabel($0)) })
        where !label.isEmpty && !seen.contains(label) {
            seen.insert(label)
            jsonLine(["label": label])
        }
    }

case "texts":
    // 列出窗口里所有静态文本：用来证明界面显示的是文字（「把握：高」「已索引 120 / 300」），不只靠颜色。
    guard let raw = argument("pid", rest), let pid = Int32(raw) else { die("需要 --pid") }
    let filter = argument("contains", rest) ?? ""
    var count = 0
    for window in axAllWindows(pid) where axWidth(window) > 400 {
        for element in axFindAll(window, role: "AXStaticText", maxDepth: intArgument("depth", rest, fallback: 60)) {
            let value = axString(element, kAXValueAttribute)
            guard !value.isEmpty, filter.isEmpty || value.contains(filter) else { continue }
            jsonLine(["text": value, "window_width": axWidth(window)])
            count += 1
        }
    }
    jsonLine(["texts": count, "filter": filter, "windows": axAllWindows(pid).count])

case "display":
    _ = NSApplication.shared
    for screen in NSScreen.screens {
        jsonLine(["name": screen.localizedName, "frame": [screen.frame.origin.x, screen.frame.origin.y,
                                                           screen.frame.width, screen.frame.height],
                  "visibleFrame": [screen.visibleFrame.origin.x, screen.visibleFrame.origin.y,
                                   screen.visibleFrame.width, screen.visibleFrame.height],
                  "scale": screen.backingScaleFactor])
    }

case "setframe":
    guard let raw = argument("pid", rest), let pid = Int32(raw) else { die("需要 --pid") }
    let x = doubleArgument("x", rest, fallback: 0)
    let y = doubleArgument("y", rest, fallback: 30)
    let width = doubleArgument("width", rest, fallback: 1440)
    let height = doubleArgument("height", rest, fallback: 900)
    let applicationElement = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement], !windows.isEmpty else { die("读不到 AX 窗口（需要辅助功能授权）") }
    func axWidth(_ element: AXUIElement) -> Double {
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let size = sizeValue, CFGetTypeID(size) == AXValueGetTypeID() else { return 0 }
        var cgSize = CGSize.zero
        AXValueGetValue(size as! AXValue, .cgSize, &cgSize)
        return Double(cgSize.width)
    }
    let window = windows.max { axWidth($0) < axWidth($1) }!
    var position = CGPoint(x: x, y: y)
    var size = CGSize(width: width, height: height)
    let positionValue = AXValueCreate(.cgPoint, &position)!
    let sizeValue = AXValueCreate(.cgSize, &size)!
    // 先改尺寸再改位置：某些窗口在放大尺寸时会把左上角推回屏内。
    let sizeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    usleep(200_000)
    let positionError = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
    usleep(200_000)
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    jsonLine(["setframe_size_error": sizeError.rawValue, "setframe_position_error": positionError.rawValue,
              "requested": [x, y, width, height]])

case "scrollpid":
    // 安静模式滚动：把滚轮事件直接投给目标进程，不要求窗口在最前，也不占鼠标。
    guard let raw = argument("pid", rest), let pid = Int32(raw) else { die("需要 --pid") }
    let step = doubleArgument("dy", rest, fallback: 120)
    let steps = intArgument("steps", rest, fallback: 1)
    let interval = doubleArgument("interval", rest, fallback: 0.016)
    let start = Date()
    for _ in 0..<steps {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: Int32(step), wheel2: 0, wheel3: 0) else { die("无法创建滚动事件") }
        event.postToPid(pid)
        if interval > 0 { usleep(UInt32(interval * 1_000_000)) }
    }
    jsonLine(["posted_scrolls": steps, "dy_each": step, "pid": pid,
              "start_wall": start.timeIntervalSince1970, "end_wall": Date().timeIntervalSince1970])

case "click":
    let x = doubleArgument("x", rest, fallback: 0)
    let y = doubleArgument("y", rest, fallback: 0)
    let repeat_ = intArgument("count", rest, fallback: 1)
    let interval = doubleArgument("interval", rest, fallback: 0.4)
    let point = CGPoint(x: x, y: y)
    let start = Date()
    for _ in 0..<repeat_ {
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { die("无法创建移动事件") }
        move.post(tap: .cghidEventTap)
        usleep(20_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(40_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        if interval > 0 { usleep(UInt32(interval * 1_000_000)) }
    }
    jsonLine(["clicked": repeat_, "x": x, "y": y,
              "start_wall": start.timeIntervalSince1970, "end_wall": Date().timeIntervalSince1970])

case "key":
    let code = CGKeyCode(UInt16(intArgument("code", rest, fallback: 0)))
    let count = intArgument("count", rest, fallback: 1)
    let interval = doubleArgument("interval", rest, fallback: 0.5)
    let pid = argument("pid", rest).flatMap(Int32.init)
    // --flags 为 CGEventFlags 原始掩码（cmd=4096、shift=512 → 「前往文件夹」是 4096+512+5=G）。
    // 不带修饰键时与旧行为一致，纯键码事件。
    let flags = CGEventFlags(rawValue: UInt64(intArgument("flags", rest, fallback: 0)))
    let start = Date()
    for _ in 0..<count {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        if let pid {
            down?.postToPid(pid); up?.postToPid(pid)
        } else {
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        }
        if interval > 0 { usleep(UInt32(interval * 1_000_000)) }
    }
    jsonLine(["posted_keys": count, "keycode": code, "flags": Int(flags.rawValue),
              "start_wall": start.timeIntervalSince1970, "end_wall": Date().timeIntervalSince1970])

case "type":
    // 往当前焦点输入 Unicode 文本：中文路径用键码打不出来。只用于自动化自己的面板输入框。
    guard let text = argument("text", rest) else { die("需要 --text") }
    guard let pid = argument("pid", rest).flatMap(Int32.init) else { die("需要 --pid") }
    let units = Array(text.utf16)
    var chunks = 0
    for start in stride(from: 0, to: units.count, by: 20) {
        let slice = Array(units[start..<min(start + 20, units.count)])
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: slice)
        up?.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: slice)
        down?.postToPid(pid); up?.postToPid(pid)
        chunks += 1
        usleep(30_000)
    }
    jsonLine(["typed": true, "characters": text.count, "chunks": chunks, "pid": Int(pid)])

default:
    die("用法: 界面驱动 windows|raise|scroll|key|type …")
}
