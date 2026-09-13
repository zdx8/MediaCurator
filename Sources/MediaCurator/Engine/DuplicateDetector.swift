import Foundation

struct DedupResult {
    var items: [MediaItem]
    var groups: [DuplicateGroup]
    var summary: DedupSummary
}

/// 查重主流程。
///
/// 设计要点：**用一个并查集承载所有关系**，而不是分别跑「精确重复」和「相似」两条流水线。
///
/// 原因很实际：如果先把精确重复挑出来、再把剩下的拿去做相似比对，就会出现盲区 ——
/// 「A 与它的字节副本」已经成组，那么「A 的缩小版」就再也找不到 A，明明它们是同一张照片。
/// 反过来若两条流水线都跑全量，同一批文件又会在两个结果里各出现一次，可释放空间被重复计算。
///
/// 所以这里：
/// 1. 先算出字节级重复所需的完整哈希；
/// 2. 把「字节同一」和「视觉相似」两种边全部并进同一棵并查集；
/// 3. 最后看每个簇里含几种不同的内容 —— 只有一种就是精确重复，多于一种就是相似。
///
/// 这样每个概念上的「同一批素材」只会产出一个分组，既不漏也不重。
enum DuplicateDetector {

    static func detect(items: [MediaItem],
                       settings: ScanSettings,
                       onStatus: (@Sendable (String) -> Void)? = nil) async -> DedupResult {
        var working = items

        // ---------- 1. 补全字节级哈希 ----------
        onStatus?("正在确认字节级重复…")
        await confirmContentHashes(items: &working, settings: settings, onStatus: onStatus)

        // ---------- 2. 图片簇 ----------
        onStatus?("正在比对图片相似度…")
        var groups = clusterImages(items: working, settings: settings)

        // ---------- 3. 视频簇 ----------
        if settings.enableVideoSimilarity {
            onStatus?("正在比对视频相似度…")
            groups.append(contentsOf: clusterVideos(items: working, settings: settings))
        }

        // ---------- 4. 排序：先按可释放空间，再按成员数，最后按保留项路径 ----------
        let sizeByID = Dictionary(uniqueKeysWithValues: working.map { ($0.id, $0.fileSize) })
        let pathByID = Dictionary(uniqueKeysWithValues: working.map { ($0.id, $0.path) })
        groups.sort { lhs, rhs in
            let l = reclaimable(lhs, sizeByID)
            let r = reclaimable(rhs, sizeByID)
            if l != r { return l > r }
            if lhs.memberCount != rhs.memberCount { return lhs.memberCount > rhs.memberCount }
            // 必须有一个稳定的最终裁决：分组来自 `clusters()` 的字典遍历，顺序本身不确定，
            // 而 Swift 的 sort 并不保证稳定 —— 少了这一条，同一批素材在不同次扫描里
            // 会给出不同的分组顺序，界面列表忽上忽下，测试也会时好时坏。
            let lp = lhs.memberIDs.first.flatMap { pathByID[$0] } ?? ""
            let rp = rhs.memberIDs.first.flatMap { pathByID[$0] } ?? ""
            return lp < rp
        }

        let summary = DedupSummary.compute(groups: groups, sizes: sizeByID)

        return DedupResult(items: working, groups: groups, summary: summary)
    }

    static func reclaimable(_ group: DuplicateGroup, _ sizes: [UUID: Int64]) -> Int64 {
        group.reclaimableBytes(sizes: sizes)
    }

    // MARK: - 内容标识

    /// 判断两个文件是否「字节级同一」。
    /// 完整哈希缺失时退回快速签名 —— 内容相同必然快速签名相同，所以判定不会漏。
    static func contentIdentity(_ item: MediaItem) -> String {
        if let h = item.contentHash { return "sha:" + h }
        if let q = item.quickSignature { return "q:" + q }
        return "u:" + item.id.uuidString
    }

    // MARK: - 完整哈希确认

    /// 只对「快速签名相同的候选组」逐字节确认。
    /// 快速签名相同是字节相同的必要条件，所以这个剪枝不会漏判，却省掉了全库的完整读取。
    private static func confirmContentHashes(items: inout [MediaItem],
                                             settings: ScanSettings,
                                             onStatus: (@Sendable (String) -> Void)?) async {
        var quickIndex = GroupIndex()
        for (index, item) in items.enumerated() {
            guard let signature = item.quickSignature else { continue }
            quickIndex.add(signature, payload: index)
        }

        var needFullHash = Set<Int>()
        for bucket in quickIndex.bucketsWithMultipleMembers() { needFullHash.formUnion(bucket) }
        guard !needFullHash.isEmpty else { return }

        let work: [(index: Int, url: URL)] = needFullHash.sorted().map { ($0, items[$0].url) }
        onStatus?("正在校验 \(work.count) 个候选文件…")

        var hashes: [Int: String] = [:]
        let maxConcurrent = settings.effectiveWorkers
        var cursor = 0
        await withTaskGroup(of: (Int, String?).self) { group in
            func submit() -> Bool {
                guard cursor < work.count else { return false }
                let entry = work[cursor]
                cursor += 1
                group.addTask { (entry.index, ContentHasher.fullSHA256(url: entry.url)) }
                return true
            }
            for _ in 0..<maxConcurrent where submit() {}
            while let result = await group.next() {
                if let hash = result.1 { hashes[result.0] = hash }
                _ = submit()
            }
        }

        for (index, hash) in hashes {
            items[index].contentHash = hash
        }
    }

    // MARK: - 图片聚簇

    private static func clusterImages(items: [MediaItem], settings: ScanSettings) -> [DuplicateGroup] {
        let indices = items.indices.filter { items[$0].kind == .image }
        guard indices.count > 1 else { return [] }

        var union = UnionFind(count: indices.count)
        var itemMax = [Int](repeating: 0, count: indices.count)

        // 边一：字节同一。这一条同时兜住了解不开像素的原始格式（RAW 没有感知哈希）。
        var identityBuckets: [String: [Int]] = [:]
        for (local, global) in indices.enumerated() {
            identityBuckets[contentIdentity(items[global]), default: []].append(local)
        }
        for (_, bucket) in identityBuckets where bucket.count > 1 {
            for other in bucket.dropFirst() { union.union(bucket[0], other) }
        }

        // 边二：视觉相似
        let threshold = settings.effectiveThreshold
        var index = HammingChunkIndex(threshold: threshold, expectedCount: indices.count)
        for (local, global) in indices.enumerated() {
            guard let hash = items[global].perceptualHash else { continue }
            for candidate in index.candidates(for: hash) where candidate != local {
                let other = items[indices[candidate]]
                guard let otherHash = other.perceptualHash else { continue }
                guard aspectCompatible(items[global], other, tolerance: settings.aspectRatioTolerance) else { continue }
                guard colorCompatible(items[global], other) else { continue }

                let distance = PerceptualHash.hamming(hash, otherHash)
                guard distance <= threshold else { continue }

                union.union(local, candidate)
                itemMax[local] = max(itemMax[local], distance)
                itemMax[candidate] = max(itemMax[candidate], distance)
            }
            index.add(hash, payload: local)
        }

        return buildGroups(union: &union,
                           itemMax: itemMax,
                           indices: indices,
                           items: items,
                           kindIfMixed: .similarImage)
    }

    // MARK: - 视频聚簇

    private static func clusterVideos(items: [MediaItem], settings: ScanSettings) -> [DuplicateGroup] {
        let indices = items.indices.filter { items[$0].kind == .video }
        guard indices.count > 1 else { return [] }

        var union = UnionFind(count: indices.count)
        var itemMax = [Int](repeating: 0, count: indices.count)

        var identityBuckets: [String: [Int]] = [:]
        for (local, global) in indices.enumerated() {
            identityBuckets[contentIdentity(items[global]), default: []].append(local)
        }
        for (_, bucket) in identityBuckets where bucket.count > 1 {
            for other in bucket.dropFirst() { union.union(bucket[0], other) }
        }

        let threshold = settings.effectiveThreshold
        var index = HammingChunkIndex(threshold: threshold, expectedCount: indices.count)
        for (local, global) in indices.enumerated() {
            // 用首帧做候选生成，再用完整序列验证：首帧相似是「整段相似」的必要条件
            guard let frames = items[global].videoFrames, let head = frames.first else { continue }
            for candidate in index.candidates(for: head) where candidate != local {
                let other = items[indices[candidate]]
                guard let otherFrames = other.videoFrames, !otherFrames.isEmpty else { continue }
                guard durationCompatible(items[global], other, tolerance: settings.videoDurationTolerance) else { continue }

                let agreement = VideoFingerprint.frameAgreement(frames, otherFrames, threshold: threshold)
                guard agreement.ratio >= 1.0 - settings.videoFrameTolerance else { continue }

                union.union(local, candidate)
                let distance = Int(agreement.meanDistance.rounded())
                itemMax[local] = max(itemMax[local], distance)
                itemMax[candidate] = max(itemMax[candidate], distance)
            }
            index.add(head, payload: local)
        }

        return buildGroups(union: &union,
                           itemMax: itemMax,
                           indices: indices,
                           items: items,
                           kindIfMixed: .similarVideo)
    }

    // MARK: - 从并查集产出分组

    private static func buildGroups(union: inout UnionFind,
                                    itemMax: [Int],
                                    indices: [Int],
                                    items: [MediaItem],
                                    kindIfMixed: DuplicateKind) -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []

        for (_, members) in union.clusters() where members.count > 1 {
            let globalIndices = members.map { indices[$0] }
            // 簇里只有一种内容标识 → 全是字节副本，属于精确重复；
            // 多于一种 → 里面既有原件也有改过的版本，属于相似。
            let identityCount = Set(globalIndices.map { contentIdentity(items[$0]) }).count
            let kind: DuplicateKind = identityCount > 1 ? kindIfMixed : .exact

            let decision = recommendKeep(indices: globalIndices,
                                         items: items,
                                         treatAsIdentical: kind == .exact)
            let maxDistance = members.map { itemMax[$0] }.max() ?? 0

            groups.append(DuplicateGroup(
                kind: kind,
                memberIDs: orderMembers(bucket: globalIndices, keep: decision.index, items: items),
                keepIDs: [items[decision.index].id],
                keepReason: decision.reason,
                maxDistance: kind == .exact ? 0 : maxDistance))
        }
        return groups
    }

    // MARK: - 兼容性判断

    static func aspectCompatible(_ a: MediaItem, _ b: MediaItem, tolerance: Double) -> Bool {
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return true }
        let ra = Double(a.width) / Double(a.height)
        let rb = Double(b.width) / Double(b.height)
        guard ra > 0, rb > 0 else { return true }
        return abs(ra - rb) / max(ra, rb) <= max(0.01, tolerance)
    }

    static func durationCompatible(_ a: MediaItem, _ b: MediaItem, tolerance: Double) -> Bool {
        guard let da = a.duration, let db = b.duration, da > 0, db > 0 else { return true }
        return abs(da - db) / max(da, db) <= max(0.01, tolerance)
    }

    /// 平坦画面（天空、白墙、截图、纯色）在灰度感知哈希上极易互相碰撞 ——
    /// 两张纯色图的哈希几乎完全相同。用 4×4 平均色再卡一道，
    /// 避免把「一张蓝天」和「一面灰墙」并成一组。
    static func colorCompatible(_ a: MediaItem, _ b: MediaItem) -> Bool {
        guard let ca = a.colorSignature, let cb = b.colorSignature,
              !ca.isEmpty, ca.count == cb.count else { return true }
        return PerceptualHash.colorDistance(ca, cb) <= 48
    }

    // MARK: - 保留推荐

    /// 在一组重复里挑出应当保留的那个。
    ///
    /// 维度依次为：分辨率 → 拍摄时间可信度 → 文件体积 → 目录层级 → 路径长度。
    /// `reason` 取第一个真正分出胜负的维度，让用户知道为什么留它。
    static func recommendKeep(indices: [Int],
                              items: [MediaItem],
                              treatAsIdentical: Bool) -> (index: Int, reason: KeepReason) {
        guard let first = indices.first else { return (0, .manual) }
        if indices.count == 1 { return (first, .manual) }

        if treatAsIdentical {
            // 内容一模一样，唯一有意义的区别是「时间戳是否可信」和「放在哪个位置更合理」
            let ordered = indices.sorted { lhs, rhs in
                let l = items[lhs], r = items[rhs]
                if l.timeSource.confidence != r.timeSource.confidence {
                    return l.timeSource.confidence > r.timeSource.confidence
                }
                let ld = pathDepth(l.path), rd = pathDepth(r.path)
                if ld != rd { return ld < rd }
                if l.fileName.count != r.fileName.count { return l.fileName.count < r.fileName.count }
                return l.path < r.path
            }
            let best = ordered[0], runnerUp = ordered[1]
            let reason: KeepReason
            if items[best].timeSource.confidence != items[runnerUp].timeSource.confidence {
                reason = .trustedTimestamp
            } else if pathDepth(items[best].path) != pathDepth(items[runnerUp].path) {
                reason = .shallowestPath
            } else {
                reason = .exactDuplicate
            }
            return (best, reason)
        }

        let ordered = indices.sorted { lhs, rhs in
            let l = items[lhs], r = items[rhs]
            if l.pixelCount != r.pixelCount { return l.pixelCount > r.pixelCount }
            if l.timeSource.confidence != r.timeSource.confidence {
                return l.timeSource.confidence > r.timeSource.confidence
            }
            if l.fileSize != r.fileSize { return l.fileSize > r.fileSize }
            let ld = pathDepth(l.path), rd = pathDepth(r.path)
            if ld != rd { return ld < rd }
            return l.path.count < r.path.count
        }

        let best = ordered[0]

        // 比较对象要排除「与保留项字节完全相同」的候选 —— 否则理由会落在
        // 两个一模一样的文件之间的平局上（例如"路径更短"），掩盖真正的原因。
        let competitor = ordered.dropFirst().first {
            contentIdentity(items[$0]) != contentIdentity(items[best])
        }

        guard let runnerUp = competitor else {
            return (best, .exactDuplicate)
        }

        let b = items[best], u = items[runnerUp]

        let reason: KeepReason
        if b.pixelCount != u.pixelCount {
            reason = .highestResolution
        } else if b.timeSource.confidence != u.timeSource.confidence {
            reason = .trustedTimestamp
        } else if b.fileSize != u.fileSize {
            reason = .largestFile
        } else if let bd = b.capturedAt, let ud = u.capturedAt, bd != ud {
            reason = .earliestCapture
        } else {
            reason = .shallowestPath
        }
        return (best, reason)
    }

    /// 组内排序：保留项排第一，其余按体积从大到小，便于界面首行直接展示推荐项
    private static func orderMembers(bucket: [Int], keep: Int, items: [MediaItem]) -> [UUID] {
        var rest = bucket.filter { $0 != keep }
        rest.sort { lhs, rhs in
            let l = items[lhs], r = items[rhs]
            if l.fileSize != r.fileSize { return l.fileSize > r.fileSize }
            return l.path < r.path
        }
        return ([keep] + rest).map { items[$0].id }
    }

    static func pathDepth(_ path: String) -> Int {
        path.reduce(0) { $1 == "/" ? $0 + 1 : $0 }
    }
}
