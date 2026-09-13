import Foundation

// MARK: - 并查集

/// 用于把「A 与 B 相似、B 与 C 相似」这类链式关系聚成一簇。
/// 显式栈做路径压缩，避免大库上递归过深。
struct UnionFind {
    private var parent: [Int]
    private var size: [Int]

    init(count: Int) {
        parent = Array(0..<max(0, count))
        size = [Int](repeating: 1, count: max(0, count))
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var node = x
        while parent[node] != root {
            let next = parent[node]
            parent[node] = root
            node = next
        }
        return root
    }

    @discardableResult
    mutating func union(_ a: Int, _ b: Int) -> Int {
        var ra = find(a)
        var rb = find(b)
        if ra == rb { return ra }
        // 按集合大小合并，保持树高在对数级
        if size[ra] < size[rb] { swap(&ra, &rb) }
        parent[rb] = ra
        size[ra] += size[rb]
        return ra
    }

    /// 根 → 成员下标列表
    mutating func clusters() -> [Int: [Int]] {
        var result = [Int: [Int]]()
        for i in parent.indices {
            let root = find(i)
            result[root, default: []].append(i)
        }
        return result
    }
}

// MARK: - 汉明距离分块索引

/// 把 64 位哈希切成若干块建立倒排表，用来在 O(1) 时间内找出「距离不超过 t」的候选。
///
/// 依据是鸽巢原理：若汉明距离 ≤ t，把 64 位分成 t+1 块，则**至少有一块完全相同**
/// （否则每块至少差 1 位，总差异就 ≥ t+1）。因此只需查这 t+1 个桶的并集，
/// 拿到候选后再算真实距离即可 —— 不漏判，只是候选里会有少数超过阈值的。
///
/// 相比 BK-tree，桶查询是常数时间且实现简单；代价是内存约为 64 位哈希的 chunkCount 倍。
struct HammingChunkIndex {
    let chunkBits: Int
    let chunkCount: Int
    /// 建索引时使用的距离阈值，用来判定分块数是否仍满足鸽巢原理
    let threshold: Int
    private var buckets: [UInt64: [Int]]
    private let mask: UInt64

    init(threshold: Int, expectedCount: Int = 0) {
        // 需要的块数至少是 threshold+1；同时把每块至少保持 2 位以免桶数爆炸
        let desired = max(2, min(32, threshold + 1))
        let bits = max(2, 64 / desired)
        self.threshold = max(0, threshold)
        self.chunkBits = bits
        self.chunkCount = (64 + bits - 1) / bits
        self.mask = bits >= 64 ? UInt64.max : ((UInt64(1) << UInt64(bits)) - 1)
        self.buckets = Dictionary(minimumCapacity: max(16, expectedCount * chunkCount / 4))
    }

    /// 块数是否足以保证不漏判。
    ///
    /// 鸽巢原理要求「块数 ≥ 阈值 + 1」；一旦不满足，距离在阈值内的候选会在某个分块上
    /// 全部错开，从而**静默漏判**（查重结果偏少，且没有任何报错）。
    /// 阈值被夹在 0–20（见 `ScanSettings.effectiveThreshold`）时这里恒为真，
    /// 但把判据写对，才能在有人放宽阈值时立刻暴露问题。
    var isComplete: Bool { chunkCount >= threshold + 1 }

    private func bucketKey(chunk: Int, value: UInt64) -> UInt64 {
        (UInt64(chunk) << 56) | value
    }

    mutating func add(_ hash: UInt64, payload: Int) {
        for chunk in 0..<chunkCount {
            let shift = UInt64(chunk * chunkBits)
            let value = shift >= 64 ? 0 : ((hash >> shift) & mask)
            buckets[bucketKey(chunk: chunk, value: value), default: []].append(payload)
        }
    }

    /// 返回可能落在阈值内的候选下标（含自身）
    func candidates(for hash: UInt64) -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        for chunk in 0..<chunkCount {
            let shift = UInt64(chunk * chunkBits)
            let value = shift >= 64 ? 0 : ((hash >> shift) & mask)
            guard let list = buckets[bucketKey(chunk: chunk, value: value)] else { continue }
            for payload in list where seen.insert(payload).inserted {
                out.append(payload)
            }
        }
        return out
    }
}

// MARK: - 通用计数器索引

/// 按字符串键分桶，用于「快速签名 / 精确哈希 / 设备名」这类精确分组
struct GroupIndex {
    private var buckets: [String: [Int]] = [:]

    mutating func add(_ key: String, payload: Int) {
        buckets[key, default: []].append(payload)
    }

    func bucketsWithMultipleMembers() -> [[Int]] {
        buckets.values.filter { $0.count > 1 }
    }

    func members(of key: String) -> [Int]? { buckets[key] }
}
