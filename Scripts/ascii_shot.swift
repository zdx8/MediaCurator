// 把截图降采样成字符图，用来在无法直接看图的环境里判断界面结构。
//
//   swiftc -O -o /tmp/ascii-shot Scripts/ascii_shot.swift
//   /tmp/ascii-shot <png> [列数] [行数]
//
// 输出两张图：亮度图（看版式与留白）与色块图（看强调色、警示色的分布）。
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("用法：ascii-shot <png> [列数] [行数]")
    exit(2)
}
let columns = arguments.count > 2 ? Int(arguments[2]) ?? 132 : 132
let rows = arguments.count > 3 ? Int(arguments[3]) ?? 44 : 44

guard let image = NSImage(contentsOfFile: arguments[1]),
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    print("无法读取图片")
    exit(1)
}

let width = rep.pixelsWide
let height = rep.pixelsHigh
print("图像：\(width)×\(height)  网格：\(columns)×\(rows)")

/// 取样时用「多数像素」而不是平均值来定色，避免边缘被背景冲淡
struct Cell {
    var luminance: Double
    var red: Double
    var green: Double
    var blue: Double
}

func sample(_ column: Int, _ row: Int) -> Cell {
    let x0 = column * width / columns
    let x1 = max(x0 + 1, (column + 1) * width / columns)
    let y0 = row * height / rows
    let y1 = max(y0 + 1, (row + 1) * height / rows)

    var lum = 0.0
    var r = 0.0, g = 0.0, b = 0.0
    var count = 0.0
    // 每格最多采 12×12 个点，够用且快
    let stepX = max(1, (x1 - x0) / 12)
    let stepY = max(1, (y1 - y0) / 12)
    var y = y0
    while y < y1 {
        var x = x0
        while x < x1 {
            if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                let rr = Double(color.redComponent)
                let gg = Double(color.greenComponent)
                let bb = Double(color.blueComponent)
                r += rr; g += gg; b += bb
                lum += 0.299 * rr + 0.587 * gg + 0.114 * bb
                count += 1
            }
            x += stepX
        }
        y += stepY
    }
    guard count > 0 else { return Cell(luminance: 1, red: 1, green: 1, blue: 1) }
    return Cell(luminance: lum / count, red: r / count, green: g / count, blue: b / count)
}

var cells = [[Cell]]()
var totalLuminance = 0.0
for row in 0..<rows {
    var line = [Cell]()
    for column in 0..<columns {
        let cell = sample(column, row)
        totalLuminance += cell.luminance
        line.append(cell)
    }
    cells.append(line)
}

print(String(format: "整图平均亮度：%.3f  → %@",
             totalLuminance / Double(columns * rows),
             totalLuminance / Double(columns * rows) > 0.5 ? "浅色主题" : "深色主题"))

// ---------- 亮度图 ----------
print("\n【亮度图】明暗分布（空格=最亮，@=最暗）")
let ramp = Array(" .:-=+*#%@")
for row in 0..<rows {
    var line = ""
    for column in 0..<columns {
        let value = cells[row][column].luminance
        let index = Int(((1.0 - value) * Double(ramp.count - 1)).rounded())
        line.append(ramp[max(0, min(ramp.count - 1, index))])
    }
    print(line)
}

// ---------- 色块图 ----------
print("\n【色块图】G=主色/正向(绿) B=蓝 V=紫 R=危险(红) Y=警示(橙) .=深色字迹 ' '=浅背景")

/// 注意：位图落在显示器自身的色彩空间（多半是 Display P3），主色在其中
/// 与 sRGB 下的分量不同，所以这里按「通道相对关系」判定色族，不比对绝对值。
func classify(_ cell: Cell) -> Character {
    let r = cell.red, g = cell.green, b = cell.blue
    let maxChannel = max(r, max(g, b))
    let minChannel = min(r, min(g, b))
    let saturation = maxChannel > 0 ? (maxChannel - minChannel) / maxChannel : 0

    if saturation > 0.18 {
        // 绿族：绿通道明显领先，且不弱于蓝
        if g > r + 0.12 && g >= b - 0.02 { return "G" }
        // 蓝族与紫族
        if b > r + 0.10 && b > g + 0.04 { return (g > r + 0.08) ? "B" : "V" }
        // 红 / 橙：看绿通道高低
        if r > g + 0.12 && r > b + 0.12 { return g > 0.42 ? "Y" : "R" }
        return "B"
    }
    return cell.luminance < 0.62 ? "." : " "
}

for row in 0..<rows {
    var line = ""
    for column in 0..<columns {
        line.append(classify(cells[row][column]))
    }
    print(line)
}

// ---------- 分区统计 ----------
print("\n【分区墨迹】与区域中位亮度差异 > 0.10 的像素占比")
func inkRatio(x0: Int, x1: Int, y0: Int, y1: Int) -> Double {
    var values: [Double] = []
    for row in y0..<min(y1, rows) {
        for column in x0..<min(x1, columns) {
            values.append(cells[row][column].luminance)
        }
    }
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let median = sorted[sorted.count / 2]
    let ink = values.filter { abs($0 - median) > 0.10 }.count
    return Double(ink) / Double(values.count)
}

let sidebarEnd = max(1, columns / 6)
print(String(format: "  左侧栏 (0–%d 列)      ：%.3f", sidebarEnd, inkRatio(x0: 0, x1: sidebarEnd, y0: 0, y1: rows)))
print(String(format: "  顶部区域 (12–22 行)   ：%.3f", inkRatio(x0: sidebarEnd, x1: columns, y0: rows / 5, y1: rows / 2)))
print(String(format: "  主内容区 (22 行以下)  ：%.3f", inkRatio(x0: sidebarEnd, x1: columns, y0: rows / 2, y1: rows)))
print(String(format: "  右下空白区（对照）    ：%.3f", inkRatio(x0: columns * 9 / 10, x1: columns, y0: rows * 9 / 10, y1: rows)))
