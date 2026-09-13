// 生成应用图标。独立用 swiftc 编译，不进 SwiftPM target。
//   swiftc -O -o /tmp/make-icon Scripts/make_icon.swift && /tmp/make-icon <iconset 目录>
import AppKit

func renderIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let context = NSGraphicsContext.current?.cgContext else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }

    let size = CGFloat(pixels)

    // 底板：圆角 + 绿色渐变（与界面主色一致）
    let inset = size * 0.055
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    context.addPath(CGPath(roundedRect: body,
                           cornerWidth: size * 0.225, cornerHeight: size * 0.225,
                           transform: nil))
    context.clip()

    // 品牌浅蓝，与 Palette.brand / brandBright / brandDeep 是同一组数值
    // （应用图标属于 logo，与界面强调色目前同色）。
    // 这里是独立脚本、引用不到 Palette，所以数值只能重复一份 ——
    // 改动这里要同步改 Palette，否则 App 内 logo 与访达里的图标会不同色。
    let colors = [
        CGColor(red: 0.40, green: 0.72, blue: 0.93, alpha: 1.0),
        CGColor(red: 0.21, green: 0.53, blue: 0.80, alpha: 1.0),
        CGColor(red: 0.10, green: 0.34, blue: 0.58, alpha: 1.0)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 0.55, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: body.minX, y: body.maxY),
                                   end: CGPoint(x: body.maxX, y: body.minY),
                                   options: [])
    }

    // 右下角一道柔和高光，避免整体过平。alpha 不能太高，
    // 否则会把绿色底冲淡成偏青的浅绿。
    if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.12),
                                      CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
                             locations: [0, 1]) {
        context.drawRadialGradient(glow,
                                   startCenter: CGPoint(x: body.maxX * 0.82, y: body.minY * 1.25),
                                   startRadius: 0,
                                   endCenter: CGPoint(x: body.maxX * 0.82, y: body.minY * 1.25),
                                   endRadius: size * 0.62,
                                   options: [])
    }

    // 图形：照片堆叠，纯白
    let symbolName = "photo.stack"
    if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil),
       let configured = symbol.withSymbolConfiguration(
           NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)) {
        let symbolSize = configured.size
        let tinted = NSImage(size: symbolSize)
        tinted.lockFocus()
        configured.draw(in: NSRect(origin: .zero, size: symbolSize))
        NSColor.white.set()
        NSRect(origin: .zero, size: symbolSize).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: NSRect(x: (size - symbolSize.width) / 2,
                               y: (size - symbolSize.height) / 2,
                               width: symbolSize.width, height: symbolSize.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/AppIcon.iconset"

try? FileManager.default.createDirectory(atPath: outputDirectory,
                                         withIntermediateDirectories: true)

// 文件名与像素的对应关系不能错，否则 iconutil 会报错或图标发虚
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

var failures = 0
for (name, pixels) in variants {
    guard let data = renderIcon(pixels: pixels) else {
        FileHandle.standardError.write(Data("渲染失败：\(name)\n".utf8))
        failures += 1
        continue
    }
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent(name)
    do {
        try data.write(to: url)
    } catch {
        FileHandle.standardError.write(Data("写入失败：\(name) \(error)\n".utf8))
        failures += 1
    }
}

if failures == 0 {
    print("已生成 \(variants.count) 个尺寸到 \(outputDirectory)")
    exit(0)
} else {
    exit(1)
}
