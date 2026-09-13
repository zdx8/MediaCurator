import Foundation

/// 单个文件的指纹缓存条目
struct CachedFingerprint: Codable {
    var fileSize: Int64
    var modified: Date
    var capturedAt: Date?
    var timeSource: CaptureTimeSource
    var make: String?
    var model: String?
    var lens: String?
    var width: Int
    var height: Int
    var duration: Double?
    var latitude: Double?
    var longitude: Double?
    var quickSignature: String?
    var perceptualHash: UInt64?
    var colorSignature: [UInt8]?
    var videoFrames: [UInt64]?
    var decodable: Bool
    var note: String?

    // 逐字段可选解码：后续新增字段时，旧缓存文件仍能正常读取
    enum CodingKeys: String, CodingKey {
        case fileSize, modified, capturedAt, timeSource, make, model, lens
        case width, height, duration, latitude, longitude
        case quickSignature, perceptualHash, colorSignature, videoFrames, decodable, note
    }

    init(fileSize: Int64, modified: Date, capturedAt: Date?, timeSource: CaptureTimeSource,
         make: String?, model: String?, lens: String?, width: Int, height: Int,
         duration: Double?, latitude: Double?, longitude: Double?,
         quickSignature: String?, perceptualHash: UInt64?, colorSignature: [UInt8]?,
         videoFrames: [UInt64]?, decodable: Bool, note: String?) {
        self.fileSize = fileSize
        self.modified = modified
        self.capturedAt = capturedAt
        self.timeSource = timeSource
        self.make = make
        self.model = model
        self.lens = lens
        self.width = width
        self.height = height
        self.duration = duration
        self.latitude = latitude
        self.longitude = longitude
        self.quickSignature = quickSignature
        self.perceptualHash = perceptualHash
        self.colorSignature = colorSignature
        self.videoFrames = videoFrames
        self.decodable = decodable
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileSize = (try? c.decode(Int64.self, forKey: .fileSize)) ?? 0
        modified = (try? c.decode(Date.self, forKey: .modified)) ?? Date(timeIntervalSince1970: 0)
        capturedAt = try? c.decodeIfPresent(Date.self, forKey: .capturedAt)
        timeSource = (try? c.decode(CaptureTimeSource.self, forKey: .timeSource)) ?? .none
        make = try? c.decodeIfPresent(String.self, forKey: .make)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        lens = try? c.decodeIfPresent(String.self, forKey: .lens)
        width = (try? c.decode(Int.self, forKey: .width)) ?? 0
        height = (try? c.decode(Int.self, forKey: .height)) ?? 0
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        latitude = try? c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try? c.decodeIfPresent(Double.self, forKey: .longitude)
        quickSignature = try? c.decodeIfPresent(String.self, forKey: .quickSignature)
        perceptualHash = try? c.decodeIfPresent(UInt64.self, forKey: .perceptualHash)
        colorSignature = try? c.decodeIfPresent([UInt8].self, forKey: .colorSignature)
        videoFrames = try? c.decodeIfPresent([UInt64].self, forKey: .videoFrames)
        decodable = (try? c.decode(Bool.self, forKey: .decodable)) ?? true
        note = try? c.decodeIfPresent(String.self, forKey: .note)
    }
}

/// 指纹缓存。大库重复扫描时，只要文件的大小与修改时间没变就直接复用上次结果，
/// 二次扫描通常能快一个数量级。
final class FingerprintCache: @unchecked Sendable {

    private let lock = NSLock()
    private var entries: [String: CachedFingerprint]
    private var dirty = false
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("MediaCurator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("fingerprint-cache.json")
        entries = [:]
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([String: CachedFingerprint].self, from: data) else {
            // 缓存损坏不应该阻断扫描，直接丢弃重建
            return
        }
        lock.lock()
        entries = decoded
        lock.unlock()
    }

    func save() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let snapshot = entries
        dirty = false
        lock.unlock()

        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        dirty = true
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    func lookup(path: String, fileSize: Int64, modified: Date?) -> CachedFingerprint? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[path] else { return nil }
        guard entry.fileSize == fileSize else { return nil }
        // 修改时间精度在不同文件系统上不一致，放宽到 2 秒
        if let modified {
            guard abs(entry.modified.timeIntervalSince(modified)) < 2.0 else { return nil }
        }
        return entry
    }

    func store(path: String, entry: CachedFingerprint) {
        lock.lock()
        entries[path] = entry
        dirty = true
        lock.unlock()
    }

    /// 把已不存在的路径清理掉，避免缓存无限膨胀
    func pruneToExisting(paths: Set<String>) {
        lock.lock()
        let before = entries.count
        entries = entries.filter { paths.contains($0.key) }
        if entries.count != before { dirty = true }
        lock.unlock()
    }
}
