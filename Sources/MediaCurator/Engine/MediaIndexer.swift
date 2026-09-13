import Foundation
import ImageIO
import CoreGraphics

typealias ProgressHandler = @MainActor @Sendable (ScanProgress) -> Void

struct ScanFailure: Hashable {
    var path: String
    var message: String
}

struct ScanOutcome {
    var items: [MediaItem] = []
    var failures: [ScanFailure] = []
    var candidates: Int = 0
    var cachedHits: Int = 0
    var wasCancelled: Bool = false
    var elapsed: TimeInterval = 0
}

/// 扫描流水线：枚举 → 元数据 → 指纹 → 写入缓存。
///
/// 全程只读。任何一步失败都只记录到 `failures`，不会中断整批处理 ——
/// 大库里总会有几个损坏文件或权限受限的目录。
enum MediaIndexer {

    // MARK: - 枚举

    static func enumerate(settings: ScanSettings,
                          excluding: [String],
                          onProgress: @escaping ProgressHandler) async -> (items: [MediaItem], truncated: Bool) {
        var collected: [MediaItem] = []
        var seenPaths = Set<String>()
        var lastReport = Date.distantPast

        // 去重：用户可能同时选了父子目录
        let roots = uniquedRoots(settings.sourceFolders)

        for root in roots {
            if Task.isCancelled { break }
            let rootURL = URL(fileURLWithPath: root)
            guard let enumerator = makeEnumerator(rootURL: rootURL, settings: settings) else { continue }

            while let next = enumerator.nextObject() {
                if Task.isCancelled { break }
                guard let url = next as? URL else { continue }
                let path = url.path

                if isExcluded(path, exclusions: excluding) {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                if seenPaths.contains(path) { continue }

                guard let values = try? url.resourceValues(forKeys: mediaResourceKeys),
                      values.isRegularFile == true else { continue }

                let ext = url.pathExtension.lowercased()
                let kind = MetadataExtractor.kind(forExtension: ext)
                guard kind != .other else { continue }
                if kind == .image && !settings.includeImages { continue }
                if kind == .video && !settings.includeVideos { continue }

                let size = Int64(values.fileSize ?? 0)
                guard size >= settings.minimumFileSize else { continue }

                seenPaths.insert(path)

                var item = MediaItem(url: url, sourceRoot: root)
                item.kind = kind
                item.fileSize = size
                item.fileCreated = values.creationDate
                item.fileModified = values.contentModificationDate
                collected.append(item)

                // 枚举阶段每 200ms 报一次，避免刷爆主线程
                if Date().timeIntervalSince(lastReport) > 0.2 {
                    lastReport = Date()
                    let snapshot = collected.count
                    await onProgress(ScanProgress(phase: .enumerating, total: snapshot, processed: snapshot))
                }
            }
        }

        let snapshot = collected.count
        await onProgress(ScanProgress(phase: .enumerating, total: snapshot, processed: snapshot))
        return (collected, Task.isCancelled)
    }

    private static let mediaResourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey
    ]

    private static func makeEnumerator(rootURL: URL, settings: ScanSettings) -> FileManager.DirectoryEnumerator? {
        // 这里原本写成 `var options: … = [.skipsPackageDescendants]`，然后下面再按设置
        // 插一次同一个选项 —— 集合插入是幂等的，于是 `skipPackages` 这个设置**从来没有生效过**：
        // 包目录永远被跳过。界面上那个开关因此成了摆设（而且当时还只有「跳过隐藏文件与包目录」
        // 一个标签、绑的是 `skipHidden`，连个能关掉包目录跳过的入口都没有）。
        var options: FileManager.DirectoryEnumerationOptions = []
        if settings.skipHidden { options.insert(.skipsHiddenFiles) }
        if settings.skipPackages { options.insert(.skipsPackageDescendants) }
        return FileManager.default.enumerator(at: rootURL,
                                             includingPropertiesForKeys: Array(mediaResourceKeys),
                                             options: options,
                                             errorHandler: { _, _ in true })
    }

    /// 去掉被其他根目录包含的根目录，避免同一批文件被枚举两遍
    static func uniquedRoots(_ roots: [String]) -> [String] {
        let normalized = roots
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { !$0.isEmpty }
        var result: [String] = []
        for path in normalized.sorted(by: { $0.count < $1.count }) {
            if result.contains(where: { PathTools.isInside(path, parent: $0) }) { continue }
            result.append(path)
        }
        return result
    }

    private static func isExcluded(_ path: String, exclusions: [String]) -> Bool {
        for ex in exclusions where !ex.isEmpty {
            if PathTools.isInside(path, parent: ex) { return true }
        }
        return false
    }

    // MARK: - 指纹提取

    static func index(settings: ScanSettings,
                      cache: FingerprintCache,
                      onProgress: @escaping ProgressHandler) async -> ScanOutcome {
        let started = Date()
        let (candidates, truncated) = await enumerate(settings: settings, excluding: [], onProgress: onProgress)

        var outcome = ScanOutcome(items: candidates, candidates: candidates.count)
        guard !candidates.isEmpty else {
            outcome.elapsed = Date().timeIntervalSince(started)
            await onProgress(ScanProgress(phase: .finished, total: 0, processed: 0, startedAt: started))
            return outcome
        }

        let total = candidates.count
        let processed = Counter()
        let cachedHits = Counter()
        let failures = Counter()
        let currentFile = Box("")
        let failureList = Box<[ScanFailure]>([])

        let progress = ScanProgress(phase: .processing, total: total, processed: 0, startedAt: started)

        // 进度上报走独立任务，避免每个文件都触发一次主线程更新
        let reporter = Task { [progress] in
            var snapshot = progress
            while !Task.isCancelled {
                snapshot.processed = processed.value
                snapshot.cachedHits = cachedHits.value
                snapshot.failureCount = failures.value
                snapshot.currentFile = currentFile.wrappedValue
                snapshot.phase = .processing
                await onProgress(snapshot)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        await onProgress(progress)

        let workers = settings.effectiveWorkers
        let ordered: [MediaItem?] = await withTaskGroup(of: (Int, MediaItem?, Bool).self) { group -> [MediaItem?] in
            var results = [MediaItem?](repeating: nil, count: total)
            var cursor = 0

            func submit() -> Bool {
                guard cursor < total, !Task.isCancelled else { return false }
                let index = cursor
                let base = candidates[index]
                cursor += 1
                group.addTask {
                    // 让界面能显示「正在处理哪一个」—— 大库上这是唯一能看出还活着的线索
                    currentFile.wrappedValue = base.fileName
                    let outcome = await processOne(base: base, settings: settings, cache: cache)
                    return (index, outcome.item, outcome.fromCache)
                }
                return true
            }

            for _ in 0..<workers where submit() {}

            while let (index, item, fromCache) = await group.next() {
                if let item {
                    results[index] = item
                    if item.error != nil {
                        failures.increment()
                        failureList.mutate { $0.append(ScanFailure(path: item.path, message: item.error ?? "")) }
                    }
                }
                if fromCache { cachedHits.increment() }
                processed.increment()
                _ = submit()
            }

            if Task.isCancelled { group.cancelAll() }
            return results
        }

        reporter.cancel()

        let items = ordered.compactMap { $0 }
        outcome.items = items
        outcome.failures = failureList.wrappedValue
        outcome.cachedHits = cachedHits.value
        outcome.wasCancelled = truncated || Task.isCancelled
        outcome.elapsed = Date().timeIntervalSince(started)

        // 清理缓存中已消失的路径
        if settings.useHashCache {
            let alive = Set(items.map { $0.path })
            cache.pruneToExisting(paths: alive)
            cache.save()
        }

        var final = ScanProgress(phase: outcome.wasCancelled ? .cancelled : .finished,
                                 total: total,
                                 processed: processed.value,
                                 startedAt: started)
        final.cachedHits = cachedHits.value
        final.failureCount = failures.value
        await onProgress(final)

        return outcome
    }

    // MARK: - 单文件处理

    private static func processOne(base: MediaItem,
                                   settings: ScanSettings,
                                   cache: FingerprintCache) async -> (item: MediaItem?, fromCache: Bool) {
        var item = base

        if settings.useHashCache,
           let hit = cache.lookup(path: item.path, fileSize: item.fileSize, modified: item.fileModified) {
            applyCache(hit, to: &item)
            return (item, true)
        }

        var entry = CachedFingerprint(fileSize: item.fileSize,
                                      modified: item.fileModified ?? Date(timeIntervalSince1970: 0),
                                      capturedAt: nil, timeSource: .none,
                                      make: nil, model: nil, lens: nil,
                                      width: 0, height: 0, duration: nil,
                                      latitude: nil, longitude: nil,
                                      quickSignature: nil, perceptualHash: nil,
                                      colorSignature: nil, videoFrames: nil,
                                      decodable: true, note: nil)

        switch item.kind {
        case .image:
            autoreleasepool {
                let meta = MetadataExtractor.readImage(url: item.url, settings: settings)
                apply(meta, to: &item)

                // 已经判定解不开的文件（多半是没有解码器的相机 RAW）不再试一次 ImageIO：
                // `PerceptualHash` 会重新打开文件、解析容器，几万张 RAW 时这笔开销很实在，
                // 而结果必然是 nil。错误文案照旧补上，界面上的解释不变。
                if item.decodable {
                    if let signature = PerceptualHash.signature(for: item.url) {
                        item.perceptualHash = signature.perceptualHash
                        item.colorSignature = signature.colorSignature
                    } else {
                        // 尺寸读到了但像素解不开
                        item.error = item.error ?? "无图像解码器（可能是 RAW 格式）"
                    }
                }

                item.quickSignature = ContentHasher.quickSignature(url: item.url, fileSize: item.fileSize)
            }

        case .video:
            let meta = await MetadataExtractor.readVideo(url: item.url, settings: settings)
            apply(meta, to: &item)

            item.quickSignature = ContentHasher.quickSignature(url: item.url, fileSize: item.fileSize)

            if item.decodable {
                item.videoFrames = await VideoFingerprint.frames(url: item.url,
                                                                 duration: item.duration,
                                                                 sampleCount: settings.videoFrameSamples,
                                                                 allowFFmpegFallback: settings.useFFmpegFallback)
                if item.videoFrames == nil {
                    item.error = item.error ?? "未能抽取视频帧"
                }
            }

        case .other:
            item.quickSignature = ContentHasher.quickSignature(url: item.url, fileSize: item.fileSize)
        }

        entry.capturedAt = item.capturedAt
        entry.timeSource = item.timeSource
        entry.make = item.make
        entry.model = item.model
        entry.lens = item.lens
        entry.width = item.width
        entry.height = item.height
        entry.duration = item.duration
        entry.latitude = item.latitude
        entry.longitude = item.longitude
        entry.quickSignature = item.quickSignature
        entry.perceptualHash = item.perceptualHash
        entry.colorSignature = item.colorSignature
        entry.videoFrames = item.videoFrames
        entry.decodable = item.decodable
        entry.note = item.error

        cache.store(path: item.path, entry: entry)
        return (item, false)
    }

    private static func apply(_ meta: MediaMetadata, to item: inout MediaItem) {
        // 文件系统时间永远作为兜底存在，即使 metadata 什么都没读出来
        item.capturedAt = meta.capturedAt
        item.timeSource = meta.timeSource
        item.make = meta.make
        item.model = meta.model
        item.lens = meta.lens
        item.width = meta.width
        item.height = meta.height
        item.duration = meta.duration
        item.latitude = meta.latitude
        item.longitude = meta.longitude
        item.decodable = meta.decodable
        item.error = meta.note
    }

    private static func applyCache(_ entry: CachedFingerprint, to item: inout MediaItem) {
        item.capturedAt = entry.capturedAt
        item.timeSource = entry.timeSource
        item.make = entry.make
        item.model = entry.model
        item.lens = entry.lens
        item.width = entry.width
        item.height = entry.height
        item.duration = entry.duration
        item.latitude = entry.latitude
        item.longitude = entry.longitude
        item.quickSignature = entry.quickSignature
        item.perceptualHash = entry.perceptualHash
        item.colorSignature = entry.colorSignature
        item.videoFrames = entry.videoFrames
        item.decodable = entry.decodable
        // 命中缓存的失败记录不再展示，避免每次扫描都报同一批老问题
        item.error = nil
    }
}
