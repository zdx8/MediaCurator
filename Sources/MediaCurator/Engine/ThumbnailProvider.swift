import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import ImageIO

/// 缩略图提供者。
///
/// 「大量照片」场景下界面上会同时出现成百上千个缩略图，因此：
/// - 用 `NSCache` 按字节数自动淘汰，避免内存被吃穿；
/// - 同一个 key 的并发请求合并成一次实际解码；
/// - 视频取首帧，走同一套缓存。
actor ThumbnailProvider {

    static let shared = ThumbnailProvider()

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Entry>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    private init() {
        cache.countLimit = 1200
        // 约 400 MB 上限：一张 480px 缩略图解码后约 0.9 MB
        cache.totalCostLimit = 400 * 1024 * 1024
    }

    func clear() {
        cache.removeAllObjects()
        inFlight.removeAll()
    }

    func thumbnail(for url: URL, maxPixel: CGFloat) async -> CGImage? {
        let pixel = Int(max(64, min(2048, maxPixel)))
        let key = "\(url.path)|\(pixel)"
        if let cached = cache.object(forKey: key as NSString) { return cached.image }

        if let task = inFlight[key] { return await task.value }

        let task = Task<CGImage?, Never> { [pixel] in
            let image = await Self.render(url: url, maxPixel: pixel)
            return image
        }
        inFlight[key] = task

        let image = await task.value
        inFlight[key] = nil
        if let image {
            let cost = image.bytesPerRow * image.height
            cache.setObject(Entry(image), forKey: key as NSString, cost: cost)
        }
        return image
    }

    private static func render(url: URL, maxPixel: Int) async -> CGImage? {
        // 视频走 AVFoundation 取首帧
        if MetadataExtractor.videoExtensions.contains(url.pathExtension.lowercased()) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 3, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 3, preferredTimescale: 600)
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            if let result = try? await generator.image(at: time) { return result.image }
        }
        return PerceptualHash.downsampledImage(url: url, maxPixel: maxPixel)
    }

    /// 生成用于界面展示的 NSImage（在调用侧的 actor 上构造，避免跨 actor 传递 NSImage）
    static func nsImage(from cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
