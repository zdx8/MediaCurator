// GUI 行为验证工具。模型无法读图时，这是判定「界面到底画出来了什么」的可靠手段。
//
//   swiftc -O -o /tmp/verify-gui Scripts/verify_gui.swift
//   /tmp/verify-gui tree  <pid>            # 转储控件树
//   /tmp/verify-gui press <pid> <控件标题>  # 按下某个按钮
//   /tmp/verify-gui find  <pid> <子串>      # 查找包含该子串的控件
//   /tmp/verify-gui pressat <pid> <x> <y>   # 按下包含该坐标的最内层按钮
//   /tmp/verify-gui clickat <pid> <x> <y>   # 在坐标处发真实鼠标按下/抬起事件
//   /tmp/verify-gui hover   <pid> <x> <y>   # 把鼠标移过去（唤起仅悬停可见的控件）
//   /tmp/verify-gui scroll  <pid> <x> <y> <行数|负数为向上>  # 在坐标处滚轮
//   /tmp/verify-gui bounds  <pid>           # 检查有没有控件超出窗口边界（窄窗口布局回归）
import ApplicationServices
import AppKit
import Foundation

func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
    attribute(element, name) as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let positionValue = attribute(element, kAXPositionAttribute as CFString),
          let sizeValue = attribute(element, kAXSizeAttribute as CFString) else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    if size.width <= 0 || size.height <= 0 { return nil }
    return CGRect(origin: origin, size: size)
}

/// 递归收集控件。深度受限，避免某些容器自我引用导致无限展开。
func collect(_ element: AXUIElement, depth: Int, maxDepth: Int, into result: inout [(AXUIElement, Int)]) {
    result.append((element, depth))
    guard depth < maxDepth else { return }
    for child in children(element) {
        collect(child, depth: depth + 1, maxDepth: maxDepth, into: &result)
    }
}

func describe(_ element: AXUIElement) -> (role: String, title: String, value: String, rect: CGRect?) {
    let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "?"
    let title = stringAttribute(element, kAXTitleAttribute as CFString) ?? ""
    var value = ""
    if let raw = attribute(element, kAXValueAttribute as CFString) {
        if let text = raw as? String { value = text }
        else if let number = raw as? NSNumber { value = number.stringValue }
        else if let flag = raw as? Bool { value = flag ? "true" : "false" }
    }
    if value.isEmpty {
        value = stringAttribute(element, kAXDescriptionAttribute as CFString) ?? ""
    }
    return (role, title, value, frame(element))
}

// MARK: - 命令

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("用法：verify-gui tree|press|find <pid> [参数]")
    exit(2)
}
let command = arguments[1]
guard let pid = Int32(arguments[2]) else { exit(2) }
let app = AXUIElementCreateApplication(pid)

// 无辅助功能权限时属性读取会失败，这本身就是结论，不要误判成「控件不存在」
var probe: CFTypeRef?
let probeStatus = AXUIElementCopyAttributeValue(app, kAXTitleAttribute as CFString, &probe)
if probeStatus != .success {
    print("AX_PERMISSION_DENIED status=\(probeStatus.rawValue)")
    exit(4)
}

var all: [(AXUIElement, Int)] = []
collect(app, depth: 0, maxDepth: 14, into: &all)

switch command {
case "tree":
    print("控件总数：\(all.count)")
    for (element, depth) in all {
        let info = describe(element)
        // 只打印有信息量的控件，纯容器会淹没输出
        let hasText = !info.title.isEmpty || !info.value.isEmpty
        let interestingRoles: Set<String> = [
            "AXButton", "AXStaticText", "AXCheckBox", "AXPopUpButton", "AXSlider",
            "AXTextField", "AXWindow", "AXRadioButton", "AXDisclosureTriangle",
            "AXTabGroup", "AXScrollArea", "AXTable", "AXRow", "AXProgressIndicator"
        ]
        guard hasText || interestingRoles.contains(info.role) else { continue }
        let indent = String(repeating: "  ", count: depth)
        var line = "\(indent)\(info.role)"
        if !info.title.isEmpty { line += " title=\"\(info.title)\"" }
        if !info.value.isEmpty { line += " value=\"\(info.value.prefix(90))\"" }
        if let rect = info.rect {
            line += " @\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
        }
        print(line)
    }

case "press", "find":
    guard arguments.count >= 4 else { exit(2) }
    let needle = arguments[3]
    var matches: [AXUIElement] = []
    for (element, _) in all {
        let info = describe(element)
        if info.title.contains(needle) || info.value.contains(needle) {
            matches.append(element)
        }
    }
    print("匹配 \(matches.count) 个包含「\(needle)」的控件")
    for element in matches.prefix(6) {
        let info = describe(element)
        var rectText = ""
        if let rect = info.rect { rectText = " @\(Int(rect.minX)),\(Int(rect.minY))" }
        print("  \(info.role) title=\"\(info.title)\" value=\"\(info.value.prefix(60))\"\(rectText)")
    }
    if command == "press" {
        // 优先按可点击的控件
        let clickable = matches.first { describe($0).role == "AXButton" } ?? matches.first
        guard let target = clickable else { print("未找到可点击控件"); exit(3) }
        let status = AXUIElementPerformAction(target, kAXPressAction as CFString)
        print("按下结果：\(status == .success ? "成功" : "失败(\(status.rawValue))")")
        exit(status == .success ? 0 : 1)
    }

case "pressat":
    // 有些控件（例如缩略图按钮）没有可访问标签，只能按坐标定位。
    // 取「包含该点、面积最小」的按钮，避免点到外层的容器按钮。
    guard arguments.count >= 5, let px = Double(arguments[3]), let py = Double(arguments[4]) else {
        print("用法：verify-gui pressat <pid> <x> <y>")
        exit(2)
    }
    let point = CGPoint(x: px, y: py)
    var best: (element: AXUIElement, area: Double)?
    for (element, _) in all {
        let info = describe(element)
        guard info.role == "AXButton", let rect = info.rect, rect.contains(point) else { continue }
        let area = Double(rect.width * rect.height)
        if best == nil || area < best!.area {
            best = (element, area)
        }
    }
    guard let target = best?.element else {
        print("坐标 (\(Int(px)), \(Int(py))) 处没有按钮")
        exit(3)
    }
    let info = describe(target)
    print("命中按钮：\(info.rect.map { "@\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "")")
    let status = AXUIElementPerformAction(target, kAXPressAction as CFString)
    print("按下结果：\(status == .success ? "成功" : "失败(\(status.rawValue))")")
    exit(status == .success ? 0 : 1)

case "hover":
    // 有些控件只在鼠标悬停时才出现（例如 AVPlayerView 的播放控件），
    // 需要能在不点击的前提下把它们唤出来再读控件树。
    guard arguments.count >= 5, let px = Double(arguments[3]), let py = Double(arguments[4]) else {
        print("用法：verify-gui hover <pid> <x> <y>")
        exit(2)
    }
    let point = CGPoint(x: px, y: py)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(150_000)
    // 再补一次微小的位移：从「无移动」状态进入时部分视图不触发 hover
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: px + 1, y: py + 1), mouseButton: .left)?
        .post(tap: .cghidEventTap)
    print("已悬停在 (\(Int(px)), \(Int(py)))")
    exit(0)

case "clickat":
    // 真实鼠标事件。有些控件对 AXPress 与真实点击的响应路径不同
    // （例如 SwiftUI 的手势识别器只认真实事件流），排查交互问题时要能区分。
    guard arguments.count >= 5, let px = Double(arguments[3]), let py = Double(arguments[4]) else {
        print("用法：verify-gui clickat <pid> <x> <y>")
        exit(2)
    }
    let point = CGPoint(x: px, y: py)
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                             mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                           mouseCursorPosition: point, mouseButton: .left) else {
        print("事件构造失败")
        exit(1)
    }
    // 先移动过去，否则某些视图收不到 hover 相关的状态更新
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(120_000)
    down.post(tap: .cghidEventTap)
    usleep(60_000)
    up.post(tap: .cghidEventTap)
    print("已在 (\(Int(px)), \(Int(py))) 发出真实点击")
    exit(0)

case "scroll":
    guard arguments.count >= 6, let px = Double(arguments[3]), let py = Double(arguments[4]),
          let lines = Int32(arguments[5]) else {
        print("用法：verify-gui scroll <pid> <x> <y> <行数>")
        exit(2)
    }
    let point = CGPoint(x: px, y: py)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(80_000)
    // 逐格发送并留出间隔，避免被合并成一次大跳
    let step: Int32 = lines > 0 ? 1 : -1
    for _ in 0..<abs(lines) {
        CGEvent(scrollWheelEvent2Source: nil, units: .line,
                wheelCount: 1, wheel1: step, wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
        usleep(30_000)
    }
    print("已在 (\(Int(px)), \(Int(py))) 滚动 \(lines) 行")
    exit(0)

case "resize":
    // 把窗口改到指定尺寸，用来复现「最小窗口下布局是否被裁」这类问题。
    // 没有它就只能靠人手拖动窗口，验证不可重复。
    guard arguments.count >= 5, let width = Double(arguments[3]),
          let height = Double(arguments[4]) else {
        print("用法：verify-gui resize <pid> <宽> <高>")
        exit(2)
    }
    guard let window = all.first(where: { describe($0.0).role == "AXWindow" })?.0 else {
        print("找不到窗口")
        exit(3)
    }
    var size = CGSize(width: width, height: height)
    guard let value = AXValueCreate(.cgSize, &size) else {
        print("尺寸构造失败")
        exit(1)
    }
    let status = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    print("调整结果：\(status == .success ? "成功" : "失败(\(status.rawValue))")")
    usleep(400_000)
    if let rect = describe(window).rect {
        print("当前窗口：\(Int(rect.width))x\(Int(rect.height))")
    }
    exit(status == .success ? 0 : 1)

case "bounds":
    // 窄窗口布局回归检查。
    //
    // 界面上「按钮显示不完全」这类问题的根因都是内容超出了窗口边界，
    // 而 SwiftUI 只会默默压缩或裁掉它们、不会报任何错。这条命令把
    // 「窗口有多大」与「每个控件落在哪」摆在一起比，越界就是失败。
    // 纵向不检查：滚动区域里的内容本来就在可视范围之外。
    guard let window = all.first(where: { describe($0.0).role == "AXWindow" })?.0,
          let windowRect = describe(window).rect else {
        print("找不到窗口")
        exit(3)
    }
    let right = windowRect.maxX
    print("窗口：@\(Int(windowRect.minX)),\(Int(windowRect.minY)) "
          + "\(Int(windowRect.width))x\(Int(windowRect.height))")
    print("右边界：\(Int(right))")

    var offenders: [(String, Int)] = []
    // 菜单栏、下拉菜单这类元素挂在应用的 AX 树上，但不属于窗口内容，
    // 不排掉会把系统菜单栏误报成「越界」。
    let ignoredRoles: Set<String> = ["AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem",
                                     "AXMenuExtra", "AXScrollBar", "AXPopover", "AXSheet"]
    for (element, _) in all {
        let info = describe(element)
        guard let rect = info.rect, !ignoredRoles.contains(info.role) else { continue }
        // 只检查真正落在窗口内的控件（滚动到可视区外的内容纵向超出属正常）
        guard rect.midY >= windowRect.minY, rect.midY <= windowRect.maxY else { continue }
        guard rect.midX <= right else { continue }
        if rect.maxX > right {
            let label = !info.value.isEmpty ? info.value : info.title
            offenders.append(("\(info.role) \(label.prefix(40)) "
                              + "@\(Int(rect.minX)),\(Int(rect.minY)) "
                              + "\(Int(rect.width))x\(Int(rect.height))",
                              Int(rect.maxX - right)))
        }
    }

    if offenders.isEmpty {
        print("✓ 没有控件超出窗口右边界")
        exit(0)
    }
    print("✗ 有 \(offenders.count) 个控件超出右边界（会被裁掉或压扁）：")
    for (text, over) in offenders.sorted(by: { $0.1 > $1.1 }).prefix(12) {
        print("   越界 \(over)px：\(text)")
    }
    exit(1)

default:
    print("未知命令 \(command)")
    exit(2)
}
