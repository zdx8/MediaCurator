// 校验「系统实际展示的」应用图标颜色，而不是 icns 文件里写了什么。
//   swiftc -O -o /tmp/icon-probe Scripts/icon_probe.swift && /tmp/icon-probe <app 路径>
import AppKit
import Foundation

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/dist/MediaCurator.app"

let icon = NSWorkspace.shared.icon(forFile: path)
icon.size = NSSize(width: 128, height: 128)

guard let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
    print("无法取得系统渲染的图标")
    exit(1)
}

let width = rep.pixelsWide
let height = rep.pixelsHigh
print("系统图标尺寸：\(width)×\(height)")

// 采样：四角内缩处取底色，中心偏上取图形笔画
func sample(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
        return (0, 0, 0, 0)
    }
    return (Double(color.redComponent), Double(color.greenComponent),
            Double(color.blueComponent), Double(color.alphaComponent))
}

let probes: [(String, Int, Int)] = [
    ("左上底板", width / 5, height / 5),
    ("右上底板", width * 4 / 5, height / 5),
    ("左下底板", width / 5, height * 4 / 5),
    ("右下底板", width * 4 / 5, height * 4 / 5),
    ("中心图形", width / 2, height / 2)
]

var baseSamples: [(r: Double, g: Double, b: Double)] = []
for (label, x, y) in probes {
    let s = sample(x, y)
    print(String(format: "  %@：RGB(%.3f, %.3f, %.3f) alpha %.2f", label, s.r, s.g, s.b, s.a))
    if label != "中心图形" { baseSamples.append((s.r, s.g, s.b)) }
}

// 底板必须是浅蓝：蓝通道领先红与绿，且整体够亮（不是深蓝）
let avgR = baseSamples.map { $0.r }.reduce(0, +) / Double(baseSamples.count)
let avgG = baseSamples.map { $0.g }.reduce(0, +) / Double(baseSamples.count)
let avgB = baseSamples.map { $0.b }.reduce(0, +) / Double(baseSamples.count)
print(String(format: "\n底板平均色：RGB(%.3f, %.3f, %.3f)", avgR, avgG, avgB))

let isBlue = avgB > avgR + 0.15 && avgB > avgG + 0.05
let isLight = avgB > 0.55
let notTooDark = avgR + avgG + avgB > 1.0

if isBlue && isLight && notTooDark {
    print("✓ 底板为浅蓝（蓝通道领先，且整体偏亮）")
    exit(0)
} else {
    var reasons: [String] = []
    if !isBlue { reasons.append("蓝通道未领先") }
    if !isLight { reasons.append("偏暗，像深蓝") }
    if !notTooDark { reasons.append("过暗") }
    print("✗ 底板颜色不符合预期：\(reasons.joined(separator: "、"))")
    print("  （可能是旧图标未更新，或系统图标缓存未刷新）")
    exit(1)
}
