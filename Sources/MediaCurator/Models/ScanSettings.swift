import Foundation

/// 扫描阶段的可配置参数。所有字段都有默认值，可直接使用。
struct ScanSettings: Codable, Equatable {

    /// 待扫描的根目录
    var sourceFolders: [String] = []

    var includeImages: Bool = true
    var includeVideos: Bool = true
    /// 跳过以 `.` 开头的隐藏文件与隐藏目录
    var skipHidden: Bool = true
    /// 跳过包目录（.app / .photoslibrary 等）
    var skipPackages: Bool = true
    /// 小于该体积的文件直接忽略。默认 1 KB —— 再往上就会开始误伤真正的小图
    /// （纯色或平坦画面的 JPEG 压缩后可能只有几 KB）。
    var minimumFileSize: Int64 = 1024

    /// 视频抽帧数量，越多越准也越慢
    var videoFrameSamples: Int = 5
    /// 是否对视频做相似度比对（耗时主要来自解码）
    var enableVideoSimilarity: Bool = true
    /// 抽帧失败时是否回退到 ffmpeg
    var useFFmpegFallback: Bool = true

    /// 感知哈希汉明距离阈值：≤ 该值视为相似。0–20，默认 6。
    var similarityThreshold: Int = 6
    /// 视频抽帧序列中允许“不相似”的帧比例
    var videoFrameTolerance: Double = 0.4
    /// 判定相似视频时要求时长差异不超过该比例
    var videoDurationTolerance: Double = 0.15
    /// 只把宽高比差异超过该比例的项排除在相似比较之外
    var aspectRatioTolerance: Double = 0.12

    /// 视频容器时间戳按当地钟表时间解释（默认，与照片 EXIF 语义一致）；
    /// 关闭则按 UTC 换算到本机时区（Apple 系设备符合规范）
    var interpretVideoTimeAsLocalWallClock: Bool = true

    /// 复用上次扫描结果，仅重新处理新增/修改的文件
    var useHashCache: Bool = true
    /// 并发工作线程数，0 表示自动
    var workerCount: Int = 0

    /// 用于比较的时间容差：同一秒内视为同一时刻
    static let captureTolerance: TimeInterval = 1.0

    var effectiveWorkers: Int {
        if workerCount > 0 { return min(workerCount, 32) }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return max(2, min(cores, 12))
    }

    var effectiveThreshold: Int { max(0, min(20, similarityThreshold)) }
}
