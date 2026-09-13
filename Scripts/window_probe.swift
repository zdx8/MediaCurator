// 列出某个进程的主窗口边界，供 screencapture -R 定位截图区域。
//   swiftc -O -o /tmp/window-probe Scripts/window_probe.swift && /tmp/window-probe <pid>
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("用法：window-probe <pid>\n".utf8))
    exit(2)
}

guard let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("无法读取窗口列表\n".utf8))
    exit(1)
}

var found = 0
for window in windows {
    guard let owner = window[kCGWindowOwnerPID as String] as? Int32, owner == pid else { continue }
    // layer 0 才是普通应用窗口；状态栏项之类不在这一层
    guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else { continue }

    let x = (bounds["X"] as? Double) ?? 0
    let y = (bounds["Y"] as? Double) ?? 0
    let width = (bounds["Width"] as? Double) ?? 0
    let height = (bounds["Height"] as? Double) ?? 0
    guard width > 200, height > 200 else { continue }

    let title = (window[kCGWindowName as String] as? String) ?? ""
    print("\(Int(x)),\(Int(y)),\(Int(width)),\(Int(height))|\(title)")
    found += 1
}

if found == 0 {
    print("NO_WINDOW")
    exit(3)
}
