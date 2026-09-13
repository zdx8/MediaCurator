import Foundation
import CoreGraphics
import ImageIO

/// 一张图片的视觉指纹
struct ImageSignature {
    /// 64 位 DCT 感知哈希
    var perceptualHash: UInt64
    /// 4×4 网格的平均 RGB（48 字节），用于排除“结构相同但颜色完全不同”的误判
    var colorSignature: [UInt8]
}

/// 感知哈希：与主流实现（ImageHash 的 phash）保持一致的算法路径，
/// 因此社区通用的汉明距离阈值在这里可以直接套用。
///
/// 流程：原图等比缩放 → 拉伸绘制到 32×32 灰度 → 二维 DCT → 取左上 8×8 低频 →
/// 与中位数比较得到 64 个比特。
enum PerceptualHash {

    // MARK: - 常量

    private static let n = 32          // 采样边长
    private static let k = 8           // 低频保留阶数，k×k = 64 bit
    private static let colorSide = 4   // 颜色签名的网格边长

    private static let cosTable: [[Double]] = {
        var table = [[Double]]()
        table.reserveCapacity(k)
        for freq in 0..<k {
            var row = [Double](repeating: 0, count: n)
            for pos in 0..<n {
                row[pos] = cos(Double.pi * Double(2 * pos + 1) * Double(freq) / Double(2 * n))
            }
            table.append(row)
        }
        return table
    }()

    private static let alpha: [Double] = (0..<k).map { freq in
        freq == 0 ? (1.0 / Double(n)).squareRoot() : (2.0 / Double(n)).squareRoot()
    }

    // MARK: - 对外入口

    /// 直接从文件生成指纹。内部只解码到 64px 缩略图，不加载原始像素。
    static func signature(for url: URL) -> ImageSignature? {
        guard let cg = downsampledImage(url: url, maxPixel: 64) else { return nil }
        return signature(from: cg)
    }

    static func signature(from cgImage: CGImage) -> ImageSignature? {
        guard let gray = grayMatrix(from: cgImage, side: n) else { return nil }
        let hash = phash64(gray)
        let color = colorGrid(from: cgImage, side: colorSide)
        return ImageSignature(perceptualHash: hash, colorSignature: color)
    }

    /// 仅从内存中的像素矩阵生成哈希（供 ffmpeg 解码出的帧复用）
    static func hashOnly(from cgImage: CGImage) -> UInt64? {
        guard let gray = grayMatrix(from: cgImage, side: n) else { return nil }
        return phash64(gray)
    }

    // MARK: - 图像取样

    /// 用 ImageIO 生成小尺寸缩略图；`withTransform` 会按 EXIF 方向摆正，
    /// 否则同一张竖拍照片与它旋转后的副本会算出完全不同的哈希。
    static func downsampledImage(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 把图像拉伸绘制到 side×side 的 8 位灰度缓冲。
    /// 这里刻意不做等比缩放 —— 与 ImageHash 的 `resize((32,32))` 行为一致，
    /// 顺带把宽高比差异归一化掉。
    static func grayMatrix(from cgImage: CGImage, side: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: side * side)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: side,
                                      height: side,
                                      bitsPerComponent: 8,
                                      bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? buffer : nil
    }

    /// 4×4 平均色网格。
    ///
    /// **`bytesPerRow` 必须与像素格式一致**：`noneSkipLast` 是每像素 4 字节（RGBX），
    /// 若把它写成 `side * 3`，`CGContext` 会直接创建失败并返回 nil —— 于是整个签名
    /// 静默变成全 0，这道「颜色不同就不算相似」的校验彻底失效。
    /// 所以这里按 4 字节/像素作图，再把 RGB 三通道抽出来紧凑存放（48 字节）。
    ///
    /// 用意：平坦画面（纯色、天空、白墙、截图）在灰度感知哈希上会严重碰撞 ——
    /// 实测纯绿 `(30,180,60)` 与近白 `(240,240,240)` 的 64 位哈希**完全相同**。
    /// 两张这样的图若被并成一组，工具就会建议删掉其中一张，所以必须靠颜色再卡一道。
    static func colorGrid(from cgImage: CGImage, side: Int) -> [UInt8] {
        let rowStride = side * 4
        var buffer = [UInt8](repeating: 0, count: side * rowStride)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: side,
                                      height: side,
                                      bitsPerComponent: 8,
                                      bytesPerRow: rowStride,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        // 画不出来就返回空数组，让比较逻辑退化为「不做颜色判定」，
        // 而不是端上一份全 0 的假签名 —— 后者会让校验永远通过，属于最坏情况。
        guard ok else { return [] }

        var rgb = [UInt8]()
        rgb.reserveCapacity(side * side * 3)
        for offset in Swift.stride(from: 0, to: buffer.count, by: 4) {
            rgb.append(buffer[offset])
            rgb.append(buffer[offset + 1])
            rgb.append(buffer[offset + 2])
        }
        return rgb
    }

    // MARK: - DCT 感知哈希

    private static func phash64(_ gray: [UInt8]) -> UInt64 {
        // 行变换：每行取前 k 个频率分量
        var rows = [[Double]](repeating: [Double](repeating: 0, count: k), count: n)
        for y in 0..<n {
            let base = y * n
            for f in 0..<k {
                let cosRow = cosTable[f]
                var sum = 0.0
                for x in 0..<n {
                    sum += (Double(gray[base + x]) - 128.0) * cosRow[x]
                }
                rows[y][f] = alpha[f] * sum
            }
        }

        // 列变换：得到 k×k 低频块
        var coeffs = [Double](repeating: 0, count: k * k)
        for fx in 0..<k {
            for fy in 0..<k {
                let cosRow = cosTable[fy]
                var sum = 0.0
                for y in 0..<n {
                    sum += rows[y][fx] * cosRow[y]
                }
                coeffs[fy * k + fx] = alpha[fy] * sum
            }
        }

        // 中位数作为阈值
        let sorted = coeffs.sorted()
        let median = (sorted[k * k / 2 - 1] + sorted[k * k / 2]) / 2.0

        var hash: UInt64 = 0
        for (index, value) in coeffs.enumerated() where value > median {
            hash |= UInt64(1) << UInt64(index)
        }
        return hash
    }

    // MARK: - 距离度量

    /// 64 位汉明距离，用内置 popcount，单次约几纳秒
    @inline(__always)
    static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// 两组颜色签名的平均通道偏差（0–255）
    static func colorDistance(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 255 }
        var sum = 0
        for i in 0..<a.count {
            sum += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(sum) / Double(a.count)
    }
}
