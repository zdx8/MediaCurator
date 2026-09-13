import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 生成一套可预期的测试素材，覆盖查重与归档流程中的各种边界。
///
/// 素材用 ImageIO 直接合成（而不是靠外部工具），这样写入与读取走的是同一套键名与解码路径，
/// 不会出现「素材格式和解析预期对不上」造成的假通过。
enum FixtureBuilder {

    struct Manifest {
        var root: URL
        var images: [String: URL] = [:]
        var videos: [String: URL] = [:]
        var hasVideos: Bool = false
    }

    static func build(at root: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        var manifest = Manifest(root: root)
        var ok = true

        // ---------- 照片素材 ----------
        guard let base = patternImage(width: 1200, height: 800, seed: 42) else {
            print("无法生成基准图像")
            return false
        }

        // 1. 原始照片：EXIF 时间 + 设备信息齐全
        let aOriginal = root.appendingPathComponent("A_original.jpg")
        ok = writeJPEG(base, to: aOriginal,
                       exifDate: "2023:05:10 12:00:00",
                       make: "Apple", model: "iPhone 13") && ok
        manifest.images["aOriginal"] = aOriginal

        // 2. 字节完全相同的副本 —— 应被判为精确重复
        let aCopy = root.appendingPathComponent("A_exact_copy.jpg")
        ok = copy(aOriginal, to: aCopy) && ok
        manifest.images["aExactCopy"] = aCopy

        // 3. 同一张图缩小一半 —— 应被判为「相似」而非「精确重复」
        if let small = scaled(base, width: 600, height: 400) {
            let aResized = root.appendingPathComponent("A_resized.jpg")
            ok = writeJPEG(small, to: aResized,
                           exifDate: "2023:05:10 12:00:05",
                           make: "Apple", model: "iPhone 13") && ok
            manifest.images["aResized"] = aResized
        }

        // 4. 完全不同的内容 —— 不应与上面任何一张成组
        if let other = patternImage(width: 1200, height: 800, seed: 777) {
            let aDifferent = root.appendingPathComponent("A_different.jpg")
            ok = writeJPEG(other, to: aDifferent,
                           exifDate: "2023:05:10 12:00:10",
                           make: "Apple", model: "iPhone 13") && ok
            manifest.images["aDifferent"] = aDifferent
        }

        // 5/6. 另一台设备的照片 + 字节副本
        if let canon = patternImage(width: 800, height: 600, seed: 99) {
            let bOriginal = root.appendingPathComponent("B_original.jpg")
            ok = writeJPEG(canon, to: bOriginal,
                           exifDate: "2024:07:01 08:30:00",
                           make: "Canon", model: "EOS R6") && ok
            manifest.images["bOriginal"] = bOriginal

            let bCopy = root.appendingPathComponent("B_exact_copy.jpg")
            ok = copy(bOriginal, to: bCopy) && ok
            manifest.images["bExactCopy"] = bCopy
        }

        // 7. 无 EXIF，只能从文件名解析时间
        if let named = patternImage(width: 640, height: 480, seed: 555) {
            let noExif = root.appendingPathComponent("IMG_20220301_101112.jpg")
            ok = writeJPEG(named, to: noExif, exifDate: nil, make: nil, model: nil) && ok
            manifest.images["noExif"] = noExif
        }

        // 8/9. 两张纯色图：感知哈希几乎相同（平坦画面），只有颜色不同。
        //      用来验证颜色签名确实拦住了这类误判。
        if let flatBlue = solidImage(width: 400, height: 300, red: 20, green: 60, blue: 200) {
            let url = root.appendingPathComponent("flat_blue.jpg")
            ok = writeJPEG(flatBlue, to: url, exifDate: "2024:01:01 10:00:00",
                           make: "Test", model: "Flat") && ok
            manifest.images["flatBlue"] = url
        }
        if let flatGray = solidImage(width: 400, height: 300, red: 130, green: 130, blue: 128) {
            let url = root.appendingPathComponent("flat_gray.jpg")
            ok = writeJPEG(flatGray, to: url, exifDate: "2024:01:01 11:00:00",
                           make: "Test", model: "Flat") && ok
            manifest.images["flatGray"] = url
        }

        // ---------- 视频素材 ----------
        if ToolLocator.hasFFmpeg {
            // 源图放在素材目录之外，否则会被当成待扫描的图片一起计入
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("mediacurator-videosrc-\(UUID().uuidString)")
            try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }

            let videoStill = scratch.appendingPathComponent("a.png")
            let otherStill = scratch.appendingPathComponent("b.png")

            let patternA = patternImage(width: 640, height: 480, seed: 20240520)
            let patternB = patternImage(width: 640, height: 480, seed: 31337)

            guard let patternA, let patternB,
                  writePNG(patternA, to: videoStill),
                  writePNG(patternB, to: otherStill) else {
                print("视频源图生成失败")
                return ok
            }

            let clipA = root.appendingPathComponent("clip_a.mp4")
            let clipB = root.appendingPathComponent("clip_b.mp4")
            let clipOther = root.appendingPathComponent("clip_other.mp4")

            // 同样的画面、不同的编码质量 —— 字节不同但画面一致，属于「相似视频」
            let madeA = makeVideo(still: videoStill, output: clipA, quality: 18)
            let madeB = makeVideo(still: videoStill, output: clipB, quality: 30)
            // 不同画面 —— 不应被归入同一组
            let madeOther = makeVideo(still: otherStill, output: clipOther, quality: 20)

            if madeA { manifest.videos["clipA"] = clipA }
            if madeB { manifest.videos["clipB"] = clipB }
            if madeOther { manifest.videos["clipOther"] = clipOther }
            manifest.hasVideos = madeA && madeB && madeOther
        }

        return ok
    }

    // MARK: - 图像合成

    /// 由种子决定的多频正弦图案：平滑、可缩放，因此可以稳定地造出「相似但不同尺寸」的版本。
    static func patternImage(width: Int, height: Int, seed: UInt64) -> CGImage? {
        let count = width * height * 4
        var pixels = [UInt8](repeating: 255, count: count)

        let f1 = Double(seed % 7) + 2.0
        let f2 = Double((seed / 7) % 6) + 2.0
        let f3 = Double((seed / 13) % 5) + 1.0
        let phase = Double(seed % 31) / 31.0 * Double.pi

        for y in 0..<height {
            let gy = Double(y) / Double(height)
            for x in 0..<width {
                let gx = Double(x) / Double(width)
                let wave = sin(f1 * Double.pi * gx + phase) * cos(f2 * Double.pi * gy)
                    + 0.5 * sin(f3 * Double.pi * (gx + gy))
                let index = (y * width + x) * 4
                let r = 128.0 + wave * 95.0
                let g = 128.0 + wave * 70.0
                let b = 128.0 - wave * 85.0
                pixels[index] = clampByte(r)
                pixels[index + 1] = clampByte(g)
                pixels[index + 2] = clampByte(b)
                pixels[index + 3] = 255
            }
        }
        return imageFromPixels(&pixels, width: width, height: height)
    }

    static func solidImage(width: Int, height: Int,
                           red: UInt8, green: UInt8, blue: UInt8) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = red
            pixels[i + 1] = green
            pixels[i + 2] = blue
            pixels[i + 3] = 255
        }
        return imageFromPixels(&pixels, width: width, height: height)
    }

    private static func clampByte(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, value.rounded())))
    }

    private static func imageFromPixels(_ pixels: inout [UInt8],
                                        width: Int, height: Int) -> CGImage? {
        pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress,
                                     width: width, height: height,
                                     bitsPerComponent: 8,
                                     bytesPerRow: width * 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }

    static func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil,
                                 width: width, height: height,
                                 bitsPerComponent: 8,
                                 bytesPerRow: width * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    // MARK: - 落盘

    @discardableResult
    static func writeJPEG(_ image: CGImage, to url: URL,
                          exifDate: String?, make: String?, model: String?) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                        UTType.jpeg.identifier as CFString,
                                                        1, nil) else { return false }
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ]
        if let exifDate {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: exifDate
            ] as [CFString: Any]
        }
        if make != nil || model != nil {
            var tiff: [CFString: Any] = [:]
            if let make { tiff[kCGImagePropertyTIFFMake] = make }
            if let model { tiff[kCGImagePropertyTIFFModel] = model }
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    @discardableResult
    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                        UTType.png.identifier as CFString,
                                                        1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    @discardableResult
    static func copy(_ from: URL, to: URL) -> Bool {
        do {
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.copyItem(at: from, to: to)
            return true
        } catch {
            print("复制失败 \(from.lastPathComponent)：\(error.localizedDescription)")
            return false
        }
    }

    /// 静态图像生成 3 秒短视频。用静帧而非动态图案，是为了让抽帧结果可预期 ——
    /// 否则不同编码参数会让关键帧落点不同，帧比对就变成了随机测试。
    static func makeVideo(still: URL, output: URL, quality: Int) -> Bool {
        guard let ffmpeg = ToolLocator.path(for: "ffmpeg") else { return false }
        let args = [
            "-nostdin", "-loglevel", "error", "-y",
            "-loop", "1", "-framerate", "15", "-i", still.path,
            "-t", "3",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-crf", "\(quality)",
            "-metadata", "creation_time=2024-05-20T08:15:30Z",
            output.path
        ]
        guard let result = Subprocess.run(ffmpeg, args, timeout: 120), result.status == 0 else {
            print("视频生成失败：\(output.lastPathComponent)")
            return false
        }
        return FileManager.default.fileExists(atPath: output.path)
    }
}
