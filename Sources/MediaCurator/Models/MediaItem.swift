import Foundation

// MARK: - 媒体类型

enum MediaKind: String, Codable, CaseIterable, Hashable {
    case image
    case video
    case other

    var displayName: String {
        switch self {
        case .image: return "图片"
        case .video: return "视频"
        case .other: return "其他"
        }
    }

    var symbolName: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .other: return "doc"
        }
    }
}

// MARK: - 拍摄时间来源

enum CaptureTimeSource: String, Codable, Hashable {
    case exif            // 照片 EXIF DateTimeOriginal 系列
    case container       // 视频容器 creation_time
    case fileName        // 从文件名解析
    case fileSystem      // 文件系统创建/修改时间（兜底，可信度最低）
    case none            // 完全无法确定

    var displayName: String {
        switch self {
        case .exif: return "EXIF"
        case .container: return "视频元数据"
        case .fileName: return "文件名"
        case .fileSystem: return "文件时间"
        case .none: return "未识别"
        }
    }

    /// 可信度权重，用于在“保留最佳”推荐时排序
    var confidence: Int {
        switch self {
        case .exif: return 5
        case .container: return 4
        case .fileName: return 3
        case .fileSystem: return 1
        case .none: return 0
        }
    }
}

// MARK: - 单个媒体文件

struct MediaItem: Identifiable, Hashable {
    let id: UUID
    var path: String
    var fileName: String
    var parentPath: String
    var sourceRoot: String
    var kind: MediaKind
    var fileSize: Int64
    var fileCreated: Date?
    var fileModified: Date?

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
    /// 系统解码器能否处理该文件（RAW 常见为 false，此时不做抽帧与缩略图）
    var decodable: Bool = true

    /// 首尾块+大小组合出的快速签名，用于精确查重的候选预筛
    var quickSignature: String?
    /// 完整 SHA-256，仅对候选组计算
    var contentHash: String?
    /// 64 位感知哈希（DCT pHash）
    var perceptualHash: UInt64?
    /// 4×4 平均色网格，用于排除「结构像但颜色完全不同」的误判
    var colorSignature: [UInt8]?
    /// 视频多点抽帧的感知哈希序列
    var videoFrames: [UInt64]?

    var error: String?

    init(url: URL, sourceRoot: String) {
        self.id = UUID()
        self.path = url.path
        self.fileName = url.lastPathComponent
        self.parentPath = url.deletingLastPathComponent().path
        self.sourceRoot = sourceRoot
        self.kind = .other
        self.fileSize = 0
    }

    var url: URL { URL(fileURLWithPath: path) }

    var pixelCount: Int { max(0, width * height) }

    var resolutionLabel: String {
        guard width > 0, height > 0 else { return "—" }
        return "\(width)×\(height)"
    }

    var durationLabel: String? {
        guard let d = duration, d.isFinite, d >= 0 else { return nil }
        let total = Int(d.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    var cameraLabel: String {
        if let make, let model {
            if model.lowercased().hasPrefix(make.lowercased()) { return model }
            return "\(make) \(model)"
        }
        return model ?? make ?? "未知设备"
    }

    var fileSizeLabel: String { ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file) }

    var capturedAtLabel: String {
        guard let capturedAt else { return "未识别" }
        return DateFormat.display(capturedAt)
    }

    var locationLabel: String? {
        guard let latitude, let longitude, latitude != 0 || longitude != 0 else { return nil }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }
}

// MARK: - 日期格式化（线程安全，规划阶段并发调用）

enum DateFormat {
    /// 依次尝试多种日期格式，输出统一的展示用字符串
    static func display(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let y = c.year, let mo = c.month, let d = c.day else { return "—" }
        if let h = c.hour, let mi = c.minute, let s = c.second {
            return String(format: "%04d-%02d-%02d %02d:%02d:%02d", y, mo, d, h, mi, s)
        }
        return String(format: "%04d-%02d-%02d", y, mo, d)
    }

    static func displayShort(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let mo = c.month, let d = c.day else { return "—" }
        return String(format: "%04d-%02d-%02d", y, mo, d)
    }
}
