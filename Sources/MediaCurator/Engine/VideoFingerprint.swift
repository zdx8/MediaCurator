import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

/// 视频视觉指纹：在时间轴上等距抽若干帧，各自算感知哈希。
///
/// 这样能识别「转码过 / 加了片头片尾 / 重新剪辑过」的同一段视频 —— 字节不同、
/// 时长可能不同，但画面序列高度重合。
enum VideoFingerprint {

    /// 抽帧并返回哈希序列，失败返回 nil
    static func frames(url: URL,
                       duration: Double?,
                       sampleCount: Int,
                       allowFFmpegFallback: Bool) async -> [UInt64]? {
        let count = max(2, min(16, sampleCount))
        var hashes: [UInt64] = []

        if let d = duration, d.isFinite, d > 0.5 {
            hashes = await viaAVFoundation(url: url, duration: d, count: count)
        }

        // 系统解码器搞不定（MKV / MTS / WMV 等），交给 ffmpeg
        if hashes.count < max(1, count / 2), allowFFmpegFallback, ToolLocator.hasFFmpeg {
            if let ff = viaFFmpeg(url: url, duration: duration, count: count), ff.count > hashes.count {
                return ff
            }
        }

        return hashes.isEmpty ? nil : hashes
    }

    // MARK: - AVFoundation 路径

    private static func viaAVFoundation(url: URL, duration: Double, count: Int) async -> [UInt64] {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        // 允许落到最近的关键帧，避免为了精确取帧而解码整段视频
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)

        var hashes: [UInt64] = []
        // 均匀分布且避开首尾黑场
        for index in 1...count {
            let fraction = Double(index) / Double(count + 1)
            let seconds = duration * fraction
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let result = try? await generator.image(at: time) else { continue }
            if let hash = PerceptualHash.hashOnly(from: result.image) {
                hashes.append(hash)
            }
        }
        return hashes
    }

    // MARK: - ffmpeg 路径

    private static func viaFFmpeg(url: URL, duration: Double?, count: Int) -> [UInt64]? {
        guard let ffmpeg = ToolLocator.path(for: "ffmpeg") else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mediacurator-frame-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        var arguments = ["-nostdin", "-loglevel", "error"]
        if let d = duration, d.isFinite, d > 1 {
            // 一次调用把等距帧全抽出来，避免每帧 fork 一个进程
            let rate = Double(count) / d
            arguments += ["-i", url.path, "-vf", "fps=\(String(format: "%.6f", rate)),scale=160:-2"]
        } else {
            // 时长未知：从固定时间点试抽
            arguments += ["-i", url.path, "-vf", "select='gt(t\\,1)*not(mod(t\\,5))',scale=160:-2", "-vsync", "0"]
        }
        arguments += ["-frames:v", "\(count)", "-y", dir.appendingPathComponent("f_%03d.png").path]

        guard let output = Subprocess.run(ffmpeg, arguments, timeout: 90) else { return nil }
        _ = output

        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        guard !files.isEmpty else { return nil }

        var hashes: [UInt64] = []
        for file in files {
            autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let cg = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let hash = PerceptualHash.hashOnly(from: cg) else { return }
                hashes.append(hash)
            }
        }
        return hashes.isEmpty ? nil : hashes
    }

    // MARK: - 序列比对

    /// 两段视频的帧序列相似度：逐帧算距离，返回「落在阈值内的帧占比」
    static func frameAgreement(_ a: [UInt64], _ b: [UInt64], threshold: Int) -> (ratio: Double, meanDistance: Double) {
        guard !a.isEmpty, !b.isEmpty else { return (0, 64) }
        let n = min(a.count, b.count)
        var withinCount = 0
        var total = 0
        for i in 0..<n {
            let d = PerceptualHash.hamming(a[i], b[i])
            total += d
            if d <= threshold { withinCount += 1 }
        }
        // 帧数不同时，把「缺失的帧」计为不匹配，避免 2 帧与 5 帧被误判为一致
        let ratio = Double(withinCount) / Double(max(a.count, b.count))
        return (ratio, Double(total) / Double(n))
    }
}
