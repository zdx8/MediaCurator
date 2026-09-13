import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 生成一套**看起来像真实照片库**的演示素材，只用于官网截图。
///
/// 为什么另起一套，而不是直接用 `FixtureBuilder`：
/// 自检素材的图案是「多频正弦」——平滑、可缩放、可预期，非常适合验证查重算法，
/// 但画面上就是一堆抽象色块。把它放进官网首屏，等于告诉访客「这是个测试程序」。
/// 两套素材的取舍方向正好相反（一套要可判定，一套要像真的），所以分开，
/// 互不影响：自检的所有断言仍然跑在原来那套上。
///
/// 演示素材同样经得起算法检验 —— 「编辑版」是原图真的缩小重编码，
/// 「副本」是字节复制，因此查重结果与真实场景一致，不是摆拍。
enum DemoFixtureBuilder {

    struct Manifest {
        var root: URL
        var photos: [String: URL] = [:]
        var videos: [String: URL] = [:]
    }

    @discardableResult
    static func build(at root: URL) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        var ok = true

        // 素材刻意分门别类放进子目录，而不是全部平铺在根下：
        // 官网要展示「来源目录与子目录」这个能力，平铺的话那一栏只有孤零零一行。
        // 「导入/手机相册」特意留出两层，用来看中间层会不会被补齐 —— 只放最深那一层的话，
        // 树会断成两截、缩进也会算错，而画面上不细看并不明显。
        let spring = folder("2024-春游", under: root, fm: fm)
        let autumn = folder("2024-秋", under: root, fm: fm)
        let plateau = folder("2023-高原", under: root, fm: fm)
        let imported = folder("导入/手机相册", under: root, fm: fm)
        let shots = folder("截图", under: root, fm: fm)
        let clips = folder("视频", under: root, fm: fm)

        // ---------- 第一组：日落（相似图片 + 精确重复混在一组） ----------
        // 现实里最常见的形态：一张原图、一份微信保存的字节副本、一份导出时被压缩过的版本。
        if let sunset = landscape(width: 1200, height: 800, seed: 20240812, paletteIndex: 0) {
            let original = spring.appendingPathComponent("IMG_4821.jpg")
            ok = write(sunset, to: original,
                                         exifDate: "2024:08:12 18:42:11",
                                         make: "Apple", model: "iPhone 15 Pro") && ok
            try? fm.setAttributes([.modificationDate: date("2024-08-12 18:42:11")],
                                  ofItemAtPath: original.path)

            // 字节完全相同的副本 —— 精确重复
            let copy = spring.appendingPathComponent("IMG_4821-1.jpg")
            ok = FixtureBuilder.copy(original, to: copy) && ok

            // 缩小重编码 —— 相似但非精确重复
            if let small = FixtureBuilder.scaled(sunset, width: 600, height: 400) {
                let edited = spring.appendingPathComponent("IMG_4821_编辑版.jpg")
                ok = write(small, to: edited,
                                             exifDate: "2024:08:12 18:42:11",
                                             make: "Apple", model: "iPhone 15 Pro") && ok
            }
        }

        // ---------- 第二组：高原湖泊（跨设备，制造「时间线对不上」的场景） ----------
        if let lake = landscape(width: 1000, height: 668, seed: 20231005, paletteIndex: 1) {
            let original = plateau.appendingPathComponent("DSC_0217.jpg")
            ok = write(lake, to: original,
                                         exifDate: "2023:10:05 07:12:44",
                                         make: "NIKON CORPORATION", model: "NIKON Z6_2") && ok
            let backup = plateau.appendingPathComponent("DSC_0217_备份.jpg")
            ok = FixtureBuilder.copy(original, to: backup) && ok
        }

        // ---------- 单张：不参与查重，但让库看起来是真的 ----------
        if let forest = landscape(width: 1200, height: 800, seed: 990017, paletteIndex: 2) {
            let url = autumn.appendingPathComponent("IMG_4903.jpg")
            ok = write(forest, to: url,
                                         exifDate: "2024:09:02 09:15:30",
                                         make: "Apple", model: "iPhone 15 Pro") && ok
        }
        if let leaves = canopy(width: 1400, height: 933, seed: 771245) {
            let url = autumn.appendingPathComponent("IMG_4904.jpg")
            ok = write(leaves, to: url,
                                         exifDate: "2024:09:02 17:48:02",
                                         make: "Apple", model: "iPhone 15 Pro") && ok
        }
        // 没有 EXIF、只能从文件名解析时间的那些
        if let night = landscape(width: 1200, height: 800, seed: 404040, paletteIndex: 4) {
            let url = imported.appendingPathComponent("IMG_20211224_231155.jpg")
            ok = write(night, to: url, exifDate: nil, make: nil, model: nil) && ok
        }
        // 截图：平坦画面的典型来源，单独存在，用来体现「这类图很占地方」
        if let shot = screenshotLike(width: 1400, height: 875) {
            let url = shots.appendingPathComponent("Screenshot 2024-08-12 at 22.10.04.png")
            ok = writePNG(shot, to: url) && ok
        }

        // ---------- 视频：同一段素材的两种编码 ----------
        if ToolLocator.hasFFmpeg {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("mediacurator-demo-\(UUID().uuidString)")
            try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }

            if let still = landscape(width: 1280, height: 720, seed: 20240812, paletteIndex: 0, grain: 0) {
                let stillURL = scratch.appendingPathComponent("still.png")
                if writePNG(still, to: stillURL) {
                    let clip = clips.appendingPathComponent("VID_0031.mp4")
                    let transcoded = clips.appendingPathComponent("VID_0031_转码.mp4")
                    let made = FixtureBuilder.makeVideo(still: stillURL, output: clip, quality: 20)
                    let made2 = FixtureBuilder.makeVideo(still: stillURL, output: transcoded, quality: 32)
                    if made { ok = ok && made2 }
                }
            }
        }

        return ok
    }

    /// 建出（必要时递归建出）一个子目录并返回它
    private static func folder(_ relative: String, under root: URL, fm: FileManager) -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func date(_ text: String) -> Date {
        Date(timeIntervalSince1970: 1_723_000_000)
    }

    // MARK: - 写盘前的守门检查

    /// 合成图是否真的有明暗。
    ///
    /// 这条检查来自一次真实事故：噪点表达式的括号写错，`&` 的优先级高于 `^`，
    /// 算出来的偏移量是个天文数字，于是每个像素都饱和到 255 —— **整张图变成纯白**。
    /// 文件照样写得出来、体积也正常、查重还会把它和它的副本判成一组，
    /// 只有人去看图才发现全是白的。凡是「算错了也不报错、只是画面没内容」的管线，
    /// 都需要这样一条直接验画面的断言。
    static func hasVisibleContent(_ image: CGImage) -> Bool {
        let side = 64
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                     width: side, height: side,
                                     bitsPerComponent: 8,
                                     bytesPerRow: side * 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }

        var low = 255.0, high = 0.0
        for index in stride(from: 0, to: buffer.count, by: 4) {
            let luminance = 0.299 * Double(buffer[index])
                + 0.587 * Double(buffer[index + 1])
                + 0.114 * Double(buffer[index + 2])
            low = min(low, luminance)
            high = max(high, luminance)
        }
        return high - low >= 40
    }

    @discardableResult
    private static func write(_ image: CGImage, to url: URL,
                              exifDate: String?, make: String?, model: String?) -> Bool {
        guard hasVisibleContent(image) else {
            print("素材异常：\(url.lastPathComponent) 几乎没有明暗变化（疑似被夹成纯色）")
            return false
        }
        return FixtureBuilder.writeJPEG(image, to: url,
                                       exifDate: exifDate, make: make, model: model)
    }

    @discardableResult
    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard hasVisibleContent(image) else {
            print("素材异常：\(url.lastPathComponent) 几乎没有明暗变化（疑似被夹成纯色）")
            return false
        }
        return FixtureBuilder.writePNG(image, to: url)
    }

    // MARK: - 风景照片合成

    /// 按种子合成一张「风景照」。
    ///
    /// 结构是真实的摄影构图：天空渐变 + 太阳光晕 + 两层山脊 + 水面倒影 + 颗粒 + 暗角。
    /// 时刻、太阳位置、山脊频率、地平线高度全部由种子决定，所以不同种子得到的是
    /// **不同场景**；而同一种子放大缩小后仍然相似 —— 这正是「相似图片」判定需要的性质。
    ///
    /// `grain` 可关：颗粒是高频噪声，两次不同码率的重编码会把它量化成不同结果，
    /// 于是同一段视频的指纹序列会漂开、判不成「相似视频」。视频用的静帧要走 `grain: 0`。
    ///
    /// `paletteIndex` 用来把「时刻」钉死。交给随机数会让两张本来无关的照片落到同一个
    /// 色板上 —— 而日落与日落的感知哈希确实很接近，于是被正当地判成一组，
    /// 演示数据里就出现「明明不是同一张，却分到一组」的荒谬画面。
    static func landscape(width: Int, height: Int, seed: UInt64,
                          paletteIndex: Int? = nil,
                          grain: Double = 0.028) -> CGImage? {
        var rng = SplitMix64(seed: seed)
        // 无论是否指定都先把这一抽消耗掉，保证后续所有参数只由 seed 决定
        let paletteRoll = rng.next()
        let slot = paletteIndex ?? Int(paletteRoll * Double(palettes.count))
        let palette = palettes[((slot % palettes.count) + palettes.count) % palettes.count]

        let horizon = Double(height) * (0.50 + rng.next() * 0.18)
        let sunX = Double(width) * (0.22 + rng.next() * 0.56)
        let sunY = horizon - Double(height) * (0.08 + rng.next() * 0.14)
        let sunRadius = Double(height) * 0.075

        // 山脊线的频率与相位来自种子
        let ridgeSeeds = (0..<6).map { _ in
            (freq: 1.0 + rng.next() * 3.4, phase: rng.next() * 6.283, amp: 0.010 + rng.next() * 0.045)
        }
        let farRidgeSeeds = ridgeSeeds.map { ($0.freq * 0.63, $0.phase + 1.7, $0.amp * 0.8) }

        // 返回值是「高出地平线多少」（占画面高度的比例），所以山脊永远贴在水面之上 ——
        // 用固定像素基线会让地平线升高时山被淹没到水里。
        func ridgeVariation(_ x: Double, _ spec: [(freq: Double, phase: Double, amp: Double)]) -> Double {
            var value = 0.0
            for item in spec {
                value += item.amp * (0.5 + 0.5 * sin(item.freq * 6.283 * x / Double(width) + item.phase))
            }
            return value
        }

        // 山脊高度只随横坐标变化，先按列算好 —— 放进内层循环会重复算 width×height 次
        let horizonFrac = horizon / Double(height)
        var farTopAt = [Double](repeating: 0, count: width)
        var nearTopAt = [Double](repeating: 0, count: width)
        for x in 0..<width {
            let gx = Double(x)
            farTopAt[x] = (horizonFrac - 0.062 - ridgeVariation(gx, farRidgeSeeds)) * Double(height)
            nearTopAt[x] = (horizonFrac - 0.016 - ridgeVariation(gx, ridgeSeeds)) * Double(height)
        }

        // 云带：低频横向条纹，让天空不是一块干净的渐变
        let cloudSeeds = (0..<3).map { _ in
            (freq: 1.5 + rng.next() * 2.5, phase: rng.next() * 6.283, band: rng.next())
        }

        // 中频质感：三个倍频的**值噪声**叠加。
        //
        // 两个考虑：
        // 1. 画面过于平滑时，感知哈希的 8×8 系数大半贴着中位数，缩小一半就会翻掉
        //    好几个比特，于是「同一张图的缩小版」反而判不成相似。真实照片从不缺
        //    这种密度，合成图得自己补上。
        // 2. 早先用的正弦叠加会留下规则的斜纹网格（轴对齐的 `sin·sin` 尤其明显），
        //    缩略图上一眼能看出像块布料。值噪声各方向等权，没有这种方向性伪影。
        var textureOctaves: [(frequency: Double, amp: Double, seed: UInt64)] = []
        for index in 0..<3 {
            let period: Double = 52.0 / Double(1 << index)   // 约 52 / 26 / 13 像素
            let amp: Double = 0.030 / Double(1 << index)
            let seed: UInt64 = UInt64(rng.next() * 1_000_000)
            textureOctaves.append((frequency: 1.0 / period, amp: amp, seed: seed))
        }

        // 远处林线：沿山脊密排一批小尖顶，形成参差不齐的树冠剪影。
        //
        // 早先是 3–6 棵「大树」，剪影在缩略图上就是几根巨大的尖刺，不像照片。
        // 真实的远景林线是密而小的，所以这里拉开数量、压低单棵高度。
        let treeCount = 90 + Int(rng.next() * 90)
        var treeAt = [Double](repeating: 0, count: width)   // 树顶相对山脊的偏移（负值向上）
        for _ in 0..<treeCount {
            let center = Double(width) * rng.next()
            let halfWidth = Double(height) * (0.005 + rng.next() * 0.014)
            let treeHeight = Double(height) * (0.012 + rng.next() * 0.050)
            let from = max(0, Int(center - halfWidth))
            let to = min(width - 1, Int(center + halfWidth))
            guard from <= to else { continue }
            for x in from...to {
                let offset = abs(Double(x) - center) / halfWidth
                let taper = pow(max(0, 1 - offset), 1.3)
                let top = -treeHeight * taper
                if top < treeAt[x] { treeAt[x] = top }
            }
        }

        // 岸边碎石与水面反光点。
        //
        // 它们的作用和纹理一样，是给画面补**局部对比**：只有平缓渐变时，
        // 感知哈希的系数大多贴着中位数，缩放一次就能翻掉好几个比特。
        // 按外接矩形光栅化，而不是逐像素遍历全部光点，否则这里会变成整张图的瓶颈。
        var overlay = [Double](repeating: 0, count: width * height)
        let pebbleCount = 260 + Int(rng.next() * 180)
        for _ in 0..<pebbleCount {
            let cx = rng.next() * Double(width)
            // 近大远小：贴着地平线的细碎，越靠近画面下缘越大
            let depthBias = pow(rng.next(), 1.6)
            let cy = horizon + (Double(height) - horizon) * (0.04 + 0.92 * depthBias)
            let radius = (1.6 + depthBias * 10.0) * (0.6 + rng.next() * 0.8)
            let strength = 0.08 + rng.next() * 0.22
            let x0 = max(0, Int(cx - radius)), x1 = min(width - 1, Int(cx + radius))
            let y0 = max(0, Int(cy - radius)), y1 = min(height - 1, Int(cy + radius))
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = Double(x) - cx, dy = Double(y) - cy
                    let d = (dx * dx + dy * dy) / (radius * radius)
                    if d < 1 {
                        let value = (1 - d) * strength
                        let index = y * width + x
                        if value > overlay[index] { overlay[index] = value }
                    }
                }
            }
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let gy = Double(y)
            let v = gy / Double(height)

            for x in 0..<width {
                let gx = Double(x)
                let farTop = farTopAt[x]
                let nearTop = nearTopAt[x]
                var r = 0.0, g = 0.0, b = 0.0

                if gy < horizon {
                    // ---- 天空：从顶部的深色过渡到地平线附近的暖色 ----
                    let t = max(0, min(1, gy / horizon))
                    let k = pow(t, 1.35)
                    r = palette.skyTop.r + (palette.skyLow.r - palette.skyTop.r) * k
                    g = palette.skyTop.g + (palette.skyLow.g - palette.skyTop.g) * k
                    b = palette.skyTop.b + (palette.skyLow.b - palette.skyTop.b) * k

                    // 云：横向拉长的柔和条带
                    var cloud = 0.0
                    for item in cloudSeeds {
                        let band = sin(item.freq * 6.283 * gx / Double(width) * 0.6 + item.phase)
                        let height1 = exp(-pow((t - (0.18 + item.band * 0.34)) * 6.0, 2))
                        cloud += 0.5 * (band * 0.5 + 0.5) * height1
                    }
                    cloud = min(1.0, cloud)
                    let cloudMix = cloud * 0.42
                    r += (1.0 - r) * cloudMix * 0.55
                    g += (1.0 - g) * cloudMix * 0.55
                    b += (1.0 - b) * cloudMix * 0.50

                    // 太阳光晕
                    let dx = (gx - sunX) / sunRadius
                    let dy = (gy - sunY) / sunRadius
                    let d2 = dx * dx + dy * dy
                    let glow = exp(-d2 * 0.42)
                    let core = exp(-d2 * 5.5)
                    r += (palette.sun.r - r) * glow * 0.65 + core * 0.9
                    g += (palette.sun.g - g) * glow * 0.60 + core * 0.8
                    b += (palette.sun.b - b) * glow * 0.50 + core * 0.6

                    // 山脊遮挡（由远及近）
                    if gy > farTop {
                        let mix = min(1.0, (gy - farTop) / 3.0)
                        r += (palette.ridgeFar.r - r) * mix
                        g += (palette.ridgeFar.g - g) * mix
                        b += (palette.ridgeFar.b - b) * mix
                    }
                    if gy > nearTop {
                        let mix = min(1.0, (gy - nearTop) / 3.0)
                        r += (palette.ridgeNear.r - r) * mix
                        g += (palette.ridgeNear.g - g) * mix
                        b += (palette.ridgeNear.b - b) * mix
                    }
                } else {
                    // ---- 水面：天空的镜像 + 横向波纹 + 太阳倒影 ----
                    let mirror = horizon - (gy - horizon) * 0.55
                    let t = max(0, min(1, mirror / horizon))
                    let k = pow(t, 1.35)
                    r = palette.skyTop.r + (palette.skyLow.r - palette.skyTop.r) * k
                    g = palette.skyTop.g + (palette.skyLow.g - palette.skyTop.g) * k
                    b = palette.skyTop.b + (palette.skyLow.b - palette.skyTop.b) * k

                    let ripple = sin(gy * 0.28 + sin(gx * 0.011) * 2.2) * 0.5 + 0.5
                    let depth = min(1.0, (gy - horizon) / (Double(height) - horizon))
                    r += (palette.water.r - r) * (0.30 + 0.45 * depth)
                    g += (palette.water.g - g) * (0.30 + 0.45 * depth)
                    b += (palette.water.b - b) * (0.30 + 0.45 * depth)
                    r += ripple * 0.035
                    g += ripple * 0.035
                    b += ripple * 0.030

                    // 阳光在水面的反射柱
                    let column = exp(-pow((gx - sunX) / (sunRadius * 2.6), 2))
                    let sparkle = max(0, sin(gy * 0.9 + gx * 0.05)) * ripple
                    let reflect = column * (0.34 + 0.28 * sparkle) * (1.0 - depth * 0.55)
                    r += (palette.sun.r - r) * reflect
                    g += (palette.sun.g - g) * reflect
                    b += (palette.sun.b - b) * reflect
                }

                // 前景树剪影：贴着近处山脊往上长，只画在地平线以上
                if treeAt[x] < 0 {
                    let treeTop = nearTop + treeAt[x]
                    if gy > treeTop && gy < horizon {
                        let mix = min(1.0, (gy - treeTop) / 2.5)
                        r += (palette.ridgeNear.r * 0.42 - r) * mix
                        g += (palette.ridgeNear.g * 0.42 - g) * mix
                        b += (palette.ridgeNear.b * 0.42 - b) * mix
                    }
                }

                // 中频质感（见 textureOctaves 的说明）
                var texture = 0.0
                for item in textureOctaves {
                    texture += (valueNoise(gx * item.frequency, gy * item.frequency,
                                           seed: item.seed) - 0.5) * item.amp
                }
                r += texture * 0.85
                g += texture
                b += texture * 0.70

                // 岸边碎石与水面反光（见 overlay 的说明）
                let pebble = overlay[y * width + x]
                if pebble > 0 {
                    r -= pebble
                    g -= pebble * 0.96
                    b -= pebble * 0.88
                }

                // 颗粒：压掉合成图的塑料感
                if grain > 0 {
                    let noise = (Double(((x &* 73856093) ^ (y &* 19349663)) & 0xFFFF) / 65535.0 - 0.5) * grain
                    r += noise
                    g += noise
                    b += noise * 0.9
                }

                // 暗角
                let cx = (gx / Double(width) - 0.5) * 2.0
                let cy = (v - 0.5) * 2.0
                let vignette = 1.0 - 0.30 * min(1.0, (cx * cx + cy * cy) * 0.55)
                r *= vignette
                g *= vignette
                b *= vignette

                let index = (y * width + x) * 4
                pixels[index] = clamp(r)
                pixels[index + 1] = clamp(g)
                pixels[index + 2] = clamp(b)
                pixels[index + 3] = 255
            }
        }
        return imageFromPixels(&pixels, width: width, height: height)
    }

    /// 树冠特写：一堆大小不一的叶片圆斑叠在深浅不一的绿色底子上。
    ///
    /// 存在的理由是**结构上就和风景照完全不同** —— 没有地平线、没有太阳、没有水面。
    /// 风景照之间即便换了色板，32×32 灰度下的低频结构仍然接近，容易被判成一组；
    /// 而「独立照片」在演示数据里必须真的独立，否则截图上会出现
    /// 「一张海边照和一张雪山照被分成一组」这种一看就假的结果。
    static func canopy(width: Int, height: Int, seed: UInt64) -> CGImage? {
        var rng = SplitMix64(seed: seed)

        // 底色：从背光的深绿到透光的黄绿
        var buffer = [Double](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width)
                let v = Double(y) / Double(height)
                let glow = 0.35 + 0.65 * (1 - v) * (0.5 + 0.5 * sin(2.4 * u + 0.7))
                let index = (y * width + x) * 3
                buffer[index] = 0.055 + 0.16 * glow
                buffer[index + 1] = 0.105 + 0.34 * glow
                buffer[index + 2] = 0.045 + 0.12 * glow
            }
        }

        // 叶片：半径跨度拉大，近处大、远处小，形成景深
        let leafCount = 520 + Int(rng.next() * 260)
        for _ in 0..<leafCount {
            let depth = rng.next()                       // 0 = 远，1 = 近
            let radius = 5.0 + depth * depth * 44.0
            let cx = rng.next() * Double(width)
            let cy = rng.next() * Double(height)
            let tint = 0.55 + rng.next() * 0.75
            let lit = (0.35 + rng.next() * 0.65) * (1 - depth * 0.35)

            let x0 = max(0, Int(cx - radius)), x1 = min(width - 1, Int(cx + radius))
            let y0 = max(0, Int(cy - radius)), y1 = min(height - 1, Int(cy + radius))
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = Double(x) - cx, dy = Double(y) - cy
                    let d2 = (dx * dx + dy * dy) / (radius * radius)
                    guard d2 < 1 else { continue }
                    // 边缘柔一点，避免看起来像贴上去的圆点
                    let alpha = (1 - d2) * 0.85 * (0.55 + 0.45 * lit)
                    let index = (y * width + x) * 3
                    buffer[index] += (0.10 * tint * lit - buffer[index]) * alpha
                    buffer[index + 1] += (0.30 * tint * lit - buffer[index + 1]) * alpha
                    buffer[index + 2] += (0.09 * tint * lit - buffer[index + 2]) * alpha
                }
            }
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let v = Double(y) / Double(height)
            for x in 0..<width {
                let index = (y * width + x) * 3
                let noise = (Double(((x &* 73856093) ^ (y &* 19349663)) & 0xFFFF) / 65535.0 - 0.5) * 0.03
                let cx = (Double(x) / Double(width) - 0.5) * 2.0
                let cy = (v - 0.5) * 2.0
                let vignette = 1.0 - 0.35 * min(1.0, (cx * cx + cy * cy) * 0.55)
                let out = (y * width + x) * 4
                pixels[out] = clamp((buffer[index] + noise) * vignette)
                pixels[out + 1] = clamp((buffer[index + 1] + noise) * vignette)
                pixels[out + 2] = clamp((buffer[index + 2] + noise * 0.8) * vignette)
                pixels[out + 3] = 255
            }
        }
        return imageFromPixels(&pixels, width: width, height: height)
    }

    /// 类截图：浅色底 + 顶栏 + 若干行「文字」条 + 一个强调色按钮。
    /// 不必真的像某个软件，只需要在缩略图尺寸下能被认成「一张截图」。
    static func screenshotLike(width: Int, height: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let barHeight = Int(Double(height) * 0.085)

        // 行布局：从种子外写死，保持每次渲染一致
        let rows: [(y: Double, w: Double, indent: Double)] = [
            (0.24, 0.46, 0.08), (0.32, 0.62, 0.08), (0.40, 0.38, 0.08),
            (0.50, 0.54, 0.16), (0.58, 0.44, 0.16), (0.66, 0.30, 0.16),
            (0.78, 0.22, 0.08)
        ]

        for y in 0..<height {
            let v = Double(y) / Double(height)
            for x in 0..<width {
                let u = Double(x) / Double(width)
                var r = 0.965, g = 0.968, b = 0.975

                if y < barHeight {
                    // 顶栏，带强调色
                    r = 0.16; g = 0.42; b = 0.68
                    if u > 0.86 && u < 0.94 {
                        r = 0.98; g = 0.98; b = 0.99
                    }
                } else {
                    // 侧栏
                    if u < 0.20 {
                        r = 0.925; g = 0.932; b = 0.945
                    }
                    // 「文字」条
                    for row in rows {
                        if abs(v - row.y) < 0.020 && u > row.indent && u < row.indent + row.w {
                            let tone = u < 0.30 ? 0.30 : 0.52
                            r = tone; g = tone + 0.02; b = tone + 0.04
                        }
                    }
                    // 强调色按钮
                    if abs(v - 0.86) < 0.030 && u > 0.72 && u < 0.90 {
                        r = 0.21; g = 0.53; b = 0.80
                    }
                }

                let noise = (Double(((x &* 2246822519) ^ (y &* 3266489917)) & 0xFF) / 255.0 - 0.5) * 0.012
                let index = (y * width + x) * 4
                pixels[index] = clamp(r + noise)
                pixels[index + 1] = clamp(g + noise)
                pixels[index + 2] = clamp(b + noise)
                pixels[index + 3] = 255
            }
        }
        return imageFromPixels(&pixels, width: width, height: height)
    }

    // MARK: - 色板与工具

    private struct RGB { let r: Double, g: Double, b: Double }

    private struct Palette {
        let skyTop: RGB, skyLow: RGB, sun: RGB
        let ridgeNear: RGB, ridgeFar: RGB, water: RGB
    }

    /// 五组「时刻」：日落 / 清晨 / 林间 / 海岸 / 夜色
    private static let palettes: [Palette] = [
        Palette(skyTop: RGB(r: 0.16, g: 0.26, b: 0.50), skyLow: RGB(r: 0.99, g: 0.60, b: 0.31),
                sun: RGB(r: 1.00, g: 0.87, b: 0.60),
                ridgeNear: RGB(r: 0.12, g: 0.14, b: 0.22), ridgeFar: RGB(r: 0.34, g: 0.31, b: 0.45),
                water: RGB(r: 0.20, g: 0.22, b: 0.34)),
        Palette(skyTop: RGB(r: 0.22, g: 0.38, b: 0.64), skyLow: RGB(r: 0.92, g: 0.89, b: 0.78),
                sun: RGB(r: 1.00, g: 0.96, b: 0.84),
                ridgeNear: RGB(r: 0.15, g: 0.22, b: 0.23), ridgeFar: RGB(r: 0.44, g: 0.50, b: 0.53),
                water: RGB(r: 0.28, g: 0.37, b: 0.43)),
        Palette(skyTop: RGB(r: 0.55, g: 0.70, b: 0.80), skyLow: RGB(r: 0.90, g: 0.93, b: 0.90),
                sun: RGB(r: 1.00, g: 0.98, b: 0.92),
                ridgeNear: RGB(r: 0.09, g: 0.19, b: 0.15), ridgeFar: RGB(r: 0.33, g: 0.45, b: 0.43),
                water: RGB(r: 0.34, g: 0.44, b: 0.43)),
        Palette(skyTop: RGB(r: 0.17, g: 0.44, b: 0.72), skyLow: RGB(r: 0.74, g: 0.89, b: 0.95),
                sun: RGB(r: 1.00, g: 0.98, b: 0.90),
                ridgeNear: RGB(r: 0.26, g: 0.29, b: 0.25), ridgeFar: RGB(r: 0.47, g: 0.53, b: 0.57),
                water: RGB(r: 0.14, g: 0.38, b: 0.55)),
        Palette(skyTop: RGB(r: 0.05, g: 0.07, b: 0.17), skyLow: RGB(r: 0.20, g: 0.24, b: 0.42),
                sun: RGB(r: 0.94, g: 0.95, b: 0.88),
                ridgeNear: RGB(r: 0.03, g: 0.04, b: 0.07), ridgeFar: RGB(r: 0.10, g: 0.12, b: 0.20),
                water: RGB(r: 0.05, g: 0.07, b: 0.14))
    ]

    /// 值噪声：格点上是随机值，格内用 smoothstep 做双线性插值。
    ///
    /// 比正弦叠加贵，但没有方向性伪影 —— 后者在缩略图尺寸下会显成一张织物网格。
    private static func valueNoise(_ x: Double, _ y: Double, seed: UInt64) -> Double {
        let x0 = floor(x), y0 = floor(y)
        let fx = x - x0, fy = y - y0
        let sx = fx * fx * (3 - 2 * fx)
        let sy = fy * fy * (3 - 2 * fy)

        func corner(_ cx: Double, _ cy: Double) -> Double {
            var h = UInt64(bitPattern: Int64(cx)) &* 0x9E37_79B9_7F4A_7C15
            h = h &+ UInt64(bitPattern: Int64(cy)) &* 0xC2B2_AE3D_27D4_EB4F
            h = h &+ seed
            h ^= h >> 30
            h = h &* 0xBF58_476D_1CE4_E5B9
            h ^= h >> 27
            h = h &* 0x94D0_49BB_1331_11EB
            h ^= h >> 31
            return Double(h >> 11) / Double(1 << 53)
        }

        let top = corner(x0, y0) + (corner(x0 + 1, y0) - corner(x0, y0)) * sx
        let bottom = corner(x0, y0 + 1) + (corner(x0 + 1, y0 + 1) - corner(x0, y0 + 1)) * sx
        return top + (bottom - top) * sy
    }

    private static func clamp(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, (value * 255).rounded())))
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
}

/// 小巧的确定性随机数（SplitMix64），避免依赖系统随机源导致每次生成的画面不同。
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> Double {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(1 << 53)
    }
}
