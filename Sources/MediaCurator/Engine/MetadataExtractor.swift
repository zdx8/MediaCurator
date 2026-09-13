import Foundation
import ImageIO
import AVFoundation
import CoreGraphics

/// 从文件里抽出来的元数据（不含内容指纹）
struct MediaMetadata {
    var capturedAt: Date?
    var timeSource: CaptureTimeSource = .none
    var make: String?
    var model: String?
    var lens: String?
    var width: Int = 0
    var height: Int = 0
    var duration: Double?
    var latitude: Double?
    var longitude: Double?
    /// 系统解码器能否处理（决定后续能否抽帧 / 生成缩略图）
    var decodable: Bool = true
    var note: String?
}

enum MetadataExtractor {

    // MARK: - 扩展名分类

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "heic", "heif", "tif", "tiff",
        "gif", "bmp", "webp", "ico", "avif",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf", "srw", "pef", "x3f"
    ]

    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "3gp", "3g2", "qt",
        "mts", "m2ts", "m2t", "ts", "mkv", "avi", "wmv", "flv", "webm",
        "mpg", "mpeg", "mpe", "vob", "ogv", "mxf", "divx", "asf", "rm", "rmvb"
    ]

    /// ISO BMFF 系容器，可以直接读文件头里的 `mvhd` 拿拍摄时间
    static let bmffExtensions: Set<String> = ["mp4", "mov", "m4v", "3gp", "3g2", "qt"]

    static func kind(forExtension ext: String) -> MediaKind {
        let e = ext.lowercased()
        if imageExtensions.contains(e) { return .image }
        if videoExtensions.contains(e) { return .video }
        return .other
    }

    // MARK: - 照片

    static func readImage(url: URL, settings: ScanSettings) -> MediaMetadata {
        var meta = MediaMetadata()

        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            meta.decodable = false
            meta.note = "无法打开图像"
            return fallbackFromFileName(url: url, into: &meta)
        }

        let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let exif = raw[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = raw[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = raw[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        meta.width = intValue(raw[kCGImagePropertyPixelWidth]) ?? 0
        meta.height = intValue(raw[kCGImagePropertyPixelHeight]) ?? 0

        // 系统读不出像素尺寸，通常意味着这是相机 RAW，CGImage 解不开
        if meta.width == 0 || meta.height == 0 { meta.decodable = false }

        var make = (tiff[kCGImagePropertyTIFFMake] as? String)?.cleanedMetadataString()
        var model = (tiff[kCGImagePropertyTIFFModel] as? String)?.cleanedMetadataString()
        if make == nil { make = (exif[kCGImagePropertyExifMakerNote] as? String)?.cleanedMetadataString() }
        meta.make = make
        meta.model = model
        meta.lens = (exif[kCGImagePropertyExifLensModel] as? String)?.cleanedMetadataString()

        // 拍摄时间优先级：原始拍摄 → 数字化 → TIFF 通用字段
        let candidates: [(String?, CaptureTimeSource)] = [
            (exif[kCGImagePropertyExifDateTimeOriginal] as? String, .exif),
            (exif[kCGImagePropertyExifDateTimeDigitized] as? String, .exif),
            (tiff[kCGImagePropertyTIFFDateTime] as? String, .exif)
        ]
        for (text, source) in candidates {
            if let text, let date = parseExifDate(text) {
                meta.capturedAt = date
                meta.timeSource = source
                break
            }
        }

        // GPS：ImageIO 一般已带符号，这里按 ref 再校正一次
        if let lat = doubleValue(gps[kCGImagePropertyGPSLatitude]),
           let lon = doubleValue(gps[kCGImagePropertyGPSLongitude]) {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            var la = lat, lo = lon
            if latRef.uppercased() == "S" { la = -abs(la) } else { la = abs(la) }
            if lonRef.uppercased() == "W" { lo = -abs(lo) } else { lo = abs(lo) }
            if la != 0 || lo != 0 {
                meta.latitude = la
                meta.longitude = lo
            }
        }

        if meta.capturedAt == nil {
            return fallbackFromFileName(url: url, into: &meta)
        }
        return meta
    }

    // MARK: - 视频

    static func readVideo(url: URL, settings: ScanSettings) async -> MediaMetadata {
        var meta = MediaMetadata()
        let ext = url.pathExtension.lowercased()

        var usedAVFoundation = false
        do {
            let asset = AVURLAsset(url: url, options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: false
            ])
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 {
                meta.duration = seconds
                usedAVFoundation = true
            }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            if let track = tracks.first {
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                // 手机竖拍视频靠 transform 记录旋转，直接看 naturalSize 会得到反的宽高
                let dw = abs(size.width * transform.a + size.height * transform.c)
                let dh = abs(size.width * transform.b + size.height * transform.d)
                // 损坏视频的轨道可能给出 NaN / 极大值，直接 Int() 会 trap
                meta.width = safePixelSize(dw)
                meta.height = safePixelSize(dh)
                usedAVFoundation = true
            } else if meta.duration == nil {
                usedAVFoundation = false
            }
        } catch {
            usedAVFoundation = false
        }

        // 容器时间：BMFF 系自己读头，最快且能区分 UTC / 当地钟表时间两种语义
        if bmffExtensions.contains(ext) {
            if let raw = BMFFParser.creationDate(url: url) {
                meta.capturedAt = settings.interpretVideoTimeAsLocalWallClock
                    ? VideoTimeNormalizer.toLocalWallClock(raw)
                    : raw
                meta.timeSource = .container
            }
        }

        if !usedAVFoundation {
            meta.decodable = ToolLocator.hasFFmpeg
            if ToolLocator.hasFFprobe, let probe = FFProbe.inspect(url: url) {
                if meta.width == 0 { meta.width = probe.width; meta.height = probe.height }
                if meta.duration == nil { meta.duration = probe.duration }
                if meta.capturedAt == nil, let raw = probe.creationDate {
                    meta.capturedAt = settings.interpretVideoTimeAsLocalWallClock
                        ? VideoTimeNormalizer.toLocalWallClock(raw)
                        : raw
                    meta.timeSource = .container
                }
                if meta.make == nil { meta.make = probe.make?.cleanedMetadataString() }
                if meta.model == nil { meta.model = probe.model?.cleanedMetadataString() }
            }
            if meta.duration == nil && meta.width == 0 {
                meta.decodable = false
                meta.note = "系统解码器无法识别该视频"
            }
        } else if meta.capturedAt == nil, ToolLocator.hasFFprobe,
                  let probe = FFProbe.inspect(url: url), let raw = probe.creationDate {
            meta.capturedAt = settings.interpretVideoTimeAsLocalWallClock
                ? VideoTimeNormalizer.toLocalWallClock(raw)
                : raw
            meta.timeSource = .container
        }

        if meta.capturedAt == nil {
            return fallbackFromFileName(url: url, into: &meta)
        }
        return meta
    }

    // MARK: - 文件名 / 文件系统兜底

    /// `IMG_20240315_143022.jpg`、`PXL_20240315_143022123.jpg`、`2024-03-15 14.30.22.jpg`、
    /// `2024-03-15 14:30:22.jpg`、`Screenshot 2024-08-12 at 22.10.04.png`
    /// 只接受“日期 + 时分秒”都完整的模式 —— 仅日期极易与设备编号混淆。
    ///
    /// 三段日期之间、日期与时间之间都允许 `_ - . 空格`（英文系统截图还会写成 ` at `），
    /// 时间内部的分隔符（`.` 或 `:`）可有可无。相机用下划线、macOS 导出用
    /// 「连字符 + 空格 + 点」，少写哪一段都不行 —— 之前只允许「日期与时间之间」有一个分隔符，
    /// 于是注释里承诺过的 `2024-03-15 14.30.22.jpg` 从来就匹配不上（年月日之间的连字符
    /// 就过不去），那批文件的时间会静默退回文件系统时间，进而被归进「未识别日期」目录。
    static let fileNameDatePattern = try! NSRegularExpression(
        pattern: "(19\\d{2}|20\\d{2})[-_. ]?(0[1-9]|1[0-2])[-_. ]?(0[1-9]|[12]\\d|3[01])(?: at |[-_. ])?([01]\\d|2[0-3])[:.]?([0-5]\\d)[:.]?([0-5]\\d)(?:[.](\\d{1,3}))?",
        options: []
    )

    static func captureDateFromFileName(_ name: String) -> Date? {
        let ns = name as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = fileNameDatePattern.firstMatch(in: name, options: [], range: range) else {
            return nil
        }
        func group(_ i: Int) -> Int? {
            let r = match.range(at: i)
            guard r.location != NSNotFound else { return nil }
            return Int(ns.substring(with: r))
        }
        guard let y = group(1), let mo = group(2), let d = group(3),
              let h = group(4), let mi = group(5), let s = group(6) else { return nil }
        return makeDate(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    }

    private static func fallbackFromFileName(url: URL, into meta: inout MediaMetadata) -> MediaMetadata {
        if let date = captureDateFromFileName(url.lastPathComponent) {
            meta.capturedAt = date
            meta.timeSource = .fileName
            return meta
        }
        if let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
            if let created = values.creationDate, isSaneDate(created) {
                meta.capturedAt = created
                meta.timeSource = .fileSystem
                return meta
            }
            if let modified = values.contentModificationDate, isSaneDate(modified) {
                meta.capturedAt = modified
                meta.timeSource = .fileSystem
                return meta
            }
        }
        meta.timeSource = .none
        return meta
    }

    // MARK: - 日期工具

    private static let gregorianLocal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }()

    private static let gregorianUTC: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    static func isSaneDate(_ date: Date) -> Bool {
        let y = gregorianLocal.component(.year, from: date)
        return y >= 1970 && y <= 2100
    }

    /// EXIF 时间形如 `2024:03:15 14:30:22`，不带时区，按本机时区解释才与相机屏幕上一致。
    /// 手写解析而非用 DateFormatter —— 后者不是线程安全的，扫描阶段会并发调用。
    static func parseExifDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 19 else { return nil }
        let chars = Array(trimmed)
        func number(_ start: Int) -> Int? {
            var value = 0
            for i in start..<(start + 2) {
                guard let ascii = chars[i].asciiValue, ascii >= 48, ascii <= 57 else { return nil }
                value = value * 10 + Int(ascii - 48)
            }
            return value
        }
        guard let year = Int(String(chars[0..<4])),
              let month = number(5),
              let day = number(8),
              let hour = number(11),
              let minute = number(14),
              let second = number(17) else { return nil }
        return makeDate(year: year, month: month, day: day,
                        hour: hour, minute: minute, second: second)
    }

    /// 构造日期并回读校验 —— `Calendar.date(from:)` 会把 2 月 30 日静默进位成 3 月 2 日，
    /// 不校验的话非法 EXIF 会产出错误目录名。
    static func makeDate(year: Int, month: Int, day: Int,
                         hour: Int, minute: Int, second: Int) -> Date? {
        guard year >= 1970, year <= 2100,
              (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else {
            return nil
        }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = min(second, 59)
        guard let date = gregorianLocal.date(from: comps) else { return nil }
        let back = gregorianLocal.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }

    /// 把容器里按 UTC 记录、但实际填了当地钟表时间的值还原成当地语义
    static func utcComponentsToLocal(_ date: Date) -> Date? {
        let comps = gregorianUTC.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return gregorianLocal.date(from: comps)
    }

    static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return safeInt(d) }
        return nil
    }

    static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    /// 安全地把 Double 转成 Int。
    ///
    /// `Int(_:)` 对 NaN、±∞ 和超出 Int 表示范围的数值会直接 trap 整个进程，
    /// 而这些数值全部来自**用户磁盘上的任意文件**（EXIF 字段、损坏视频的轨道信息）。
    /// 一个畸形文件不该让整个扫描崩掉，所以这里一律判为「取值失败」。
    static func safeInt(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded()
        // 2^53 以内可被 Int64 精确表示，足以覆盖所有真实元数据
        let limit = 9_007_199_254_740_992.0
        guard rounded >= -limit, rounded <= limit else { return nil }
        return Int(rounded)
    }

    /// 像素尺寸专用：必须为正且不荒谬，否则视为「未知」。返回 0 而不是 nil，
    /// 与「读不到尺寸」的既有语义保持一致。
    static func safePixelSize(_ value: Double) -> Int {
        guard let size = safeInt(value), size > 0, size <= 1_000_000 else { return 0 }
        return size
    }
}

extension String {
    func cleanedMetadataString() -> String? {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // 部分设备会把型号填成问号或固定占位串
        if s == "?" || s == "unknown" || s == "Unknown" { return nil }
        return s
    }
}

enum VideoTimeNormalizer {
    static func toLocalWallClock(_ date: Date) -> Date {
        MetadataExtractor.utcComponentsToLocal(date) ?? date
    }
}

// MARK: - MP4 / MOV 头部解析

/// MP4 / MOV / M4V / 3GP 的拍摄时间就写在 `moov.mvhd` 里。
/// 读文件头比 fork 一次 ffprobe 快两三个数量级，几百个视频的导入也不会卡在规划阶段。
enum BMFFParser {

    private static let mvhd: [UInt8] = [0x6D, 0x76, 0x68, 0x64]   // "mvhd"
    private static let probeWindow = 512 * 1024

    static func creationDate(url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        if let head = try? handle.read(upToCount: probeWindow), let date = scan(head) {
            return date
        }

        // 边录边写或后期重封装过的文件会把 moov 挪到文件尾部
        guard let size = try? handle.seekToEnd(), size > UInt64(probeWindow) else { return nil }
        let offset = size - UInt64(probeWindow)
        guard (try? handle.seek(toOffset: offset)) != nil,
              let tail = try? handle.read(upToCount: probeWindow) else { return nil }
        return scan(tail)
    }

    /// 在字节流里定位 `mvhd` 盒子并解出 creation_time
    static func scan(_ data: Data) -> Date? {
        let bytes = [UInt8](data)
        guard bytes.count > 32 else { return nil }

        var i = 0
        let limit = bytes.count - 32
        while i <= limit {
            if bytes[i] == mvhd[0], bytes[i + 1] == mvhd[1],
               bytes[i + 2] == mvhd[2], bytes[i + 3] == mvhd[3] {
                let version = bytes[i + 4]
                var seconds: UInt64?
                if version == 0 {
                    seconds = UInt64(be32(bytes, i + 8))
                } else if version == 1 {
                    let hi = UInt64(be32(bytes, i + 8))
                    let lo = UInt64(be32(bytes, i + 12))
                    seconds = (hi << 32) | lo
                }
                if let seconds, let date = date(fromSeconds: seconds) { return date }
            }
            i += 1
        }
        return nil
    }

    /// mvhd 的时间基准是 1904-01-01 00:00:00 UTC，不是 1970。
    /// 不少设备把该字段写成 0（或写成完全离谱的值），用年份区间过滤掉这类占位值。
    ///
    /// 这里先用整数区间卡一道再构造 `Date`：把一个天文数字塞给 `Date` 再让
    /// `Calendar` 去解析年份，等于让 Foundation 处理远超其表示范围的时刻，没必要。
    static func date(fromSeconds seconds: UInt64) -> Date? {
        // 1970-01-01 与 2100-01-01 相对于 1904 基准的秒数
        let lowerBound: UInt64 = 2_082_844_800      // 1970-01-01T00:00:00Z
        let upperBound: UInt64 = 6_185_289_600      // 2100-01-01T00:00:00Z
        guard seconds >= lowerBound, seconds <= upperBound else { return nil }
        let epoch1904 = -2_082_844_800.0
        return Date(timeIntervalSince1970: epoch1904 + Double(seconds))
    }

    private static func be32(_ b: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(b[offset]) << 24) | (UInt32(b[offset + 1]) << 16)
            | (UInt32(b[offset + 2]) << 8) | UInt32(b[offset + 3])
    }
}

// MARK: - ffprobe 兜底

struct FFProbeResult {
    var creationDate: Date?
    var duration: Double?
    var width: Int = 0
    var height: Int = 0
    var make: String?
    var model: String?
}

/// 非 BMFF 容器（MKV / AVI / MTS / WMV …）系统解码器读不了，只能交给 ffprobe。
enum FFProbe {

    /// 同一进程里被多线程并发调用，缓存 formatter 会踩线程安全问题，这里每次新建。
    private static func parseISO(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: text)
    }

    static func inspect(url: URL) -> FFProbeResult? {
        guard let tool = ToolLocator.path(for: "ffprobe") else { return nil }
        let args = [
            "-v", "error",
            "-print_format", "json",
            "-show_format", "-show_streams",
            url.path
        ]
        guard let output = Subprocess.run(tool, args, timeout: 20),
              output.status == 0,
              let data = output.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var result = FFProbeResult()

        if let format = root["format"] as? [String: Any] {
            if let tags = format["tags"] as? [String: Any] {
                for key in ["creation_time", "creationTime", "date"] {
                    if let text = tags[key] as? String, let d = parseISO(text) {
                        result.creationDate = d
                        break
                    }
                }
                result.make = tags["make"] as? String ?? tags["com.apple.quicktime.make"] as? String
                result.model = tags["model"] as? String ?? tags["com.apple.quicktime.model"] as? String
            }
            if let durationText = format["duration"] as? String, let d = Double(durationText) {
                result.duration = d
            }
        }

        if let streams = root["streams"] as? [[String: Any]] {
            for stream in streams where (stream["codec_type"] as? String) == "video" {
                result.width = MetadataExtractor.intValue(stream["width"]) ?? 0
                result.height = MetadataExtractor.intValue(stream["height"]) ?? 0
                if result.duration == nil,
                   let text = stream["duration"] as? String, let d = Double(text) {
                    result.duration = d
                }
                break
            }
        }

        if result.creationDate == nil && result.duration == nil && result.width == 0 {
            return nil
        }
        return result
    }
}
