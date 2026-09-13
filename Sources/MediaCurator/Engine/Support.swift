import Foundation

/// 线程安全的值盒子。用于在并发闭包中安全承接非 Sendable 的操作系统对象。
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    var wrappedValue: T {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }

    /// 在锁保护下做一次读改写，避免 get/set 之间的竞态
    func mutate(_ body: (inout T) -> Void) {
        lock.lock()
        body(&value)
        lock.unlock()
    }
}

/// 统计计数器
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int

    init(_ value: Int = 0) { self._value = value }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    @discardableResult
    func increment(_ n: Int = 1) -> Int {
        lock.lock(); defer { lock.unlock() }
        _value += n
        return _value
    }
}

// MARK: - 外部工具定位

/// 应用以 .app 形式启动时 PATH 不含 Homebrew 目录，必须显式探测。
enum ToolLocator {
    private static let candidates: [String: [String]] = [
        "ffmpeg": [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ],
        "ffprobe": [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]
    ]

    private static let cache = Box<[String: String?]>([:])

    static func path(for tool: String) -> String? {
        if let cached = cache.wrappedValue[tool] { return cached }
        var found: String?
        if let list = candidates[tool] {
            for p in list where FileManager.default.isExecutableFile(atPath: p) {
                found = p
                break
            }
        }
        if found == nil {
            // 再从 PATH 里找一遍，便于从终端直接运行二进制
            let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
            for dir in env.split(separator: ":") {
                let p = String(dir) + "/" + tool
                if FileManager.default.isExecutableFile(atPath: p) { found = p; break }
            }
        }
        cache.mutate { $0[tool] = found }
        return found
    }

    static var hasFFmpeg: Bool { path(for: "ffmpeg") != nil }
    static var hasFFprobe: Bool { path(for: "ffprobe") != nil }
}

// MARK: - 子进程

enum Subprocess {

    struct Output {
        var status: Int32
        var stdout: String
        var timedOut: Bool

        var trimmed: String {
            stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 运行外部命令。`timeout` 到期会强制终止，避免 ffmpeg 在损坏文件上卡死。
    @discardableResult
    static func run(_ executable: String,
                    _ arguments: [String],
                    timeout: TimeInterval = 30,
                    captureStdout: Bool = true) -> Output? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        if captureStdout { process.standardOutput = outPipe }
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let box = Box(Data())
        if captureStdout {
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                box.mutate { $0.append(chunk) }
            }
        }

        let timedOut = Box(false)
        let done = DispatchSemaphore(value: 0)

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                timedOut.wrappedValue = true
                process.terminate()
            }
        }

        DispatchQueue.global().async {
            process.waitUntilExit()
            done.signal()
        }

        // 边等边泵主 RunLoop：可安全用于主线程之外的调用
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        if captureStdout {
            box.mutate { $0.append(outPipe.fileHandleForReading.readDataToEndOfFile()) }
        }

        let text = String(data: box.wrappedValue, encoding: .utf8) ?? ""
        return Output(status: process.terminationStatus,
                      stdout: text,
                      timedOut: timedOut.wrappedValue)
    }
}

// MARK: - 路径工具

enum PathTools {

    /// 把任意字符串清洗成合法的单层文件/目录名
    static func sanitizeComponent(_ raw: String, maxLength: Int = 120) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "/", with: "-")
        s = s.replacingOccurrences(of: ":", with: "-")
        s = s.replacingOccurrences(of: "\0", with: "")
        // 换行/制表等控制字符一并去掉
        s = s.unicodeScalars
            .filter { !($0.value < 0x20) }
            .map(String.init)
            .joined()
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // 避免生成 "." / ".." 这类特殊名
        if s == "." || s == ".." { s = "_" }
        if s.isEmpty { s = "_" }
        if s.count > maxLength {
            s = String(s.prefix(maxLength))
        }
        return s
    }

    /// 标准化路径：解析 "." / ".."、合并重复斜杠、去掉结尾斜杠。
    ///
    /// 同一个目录在系统各处拿到的字符串形态并不一致（`NSOpenPanel` 会给带尾斜杠的，
    /// `NSString.deletingLastPathComponent` 给不带尾斜杠的）。把它当 `Set` 的键、
    /// 做前缀比较或判断父子关系之前必须先过一遍，否则同一个目录会被当成两个。
    static func normalized(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// 判断 `child` 是否位于 `parent` 之内（含相等）
    static func isInside(_ child: String, parent: String) -> Bool {
        let c = normalized(child)
        let p = normalized(parent)
        if c == p { return true }
        return c.hasPrefix(p + "/")
    }

    static func uniquePath(_ desired: String) -> String {
        let url = URL(fileURLWithPath: desired)
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 1
        while index < 100_000 {
            let candidate = ext.isEmpty
                ? dir.appendingPathComponent("\(base)_\(index)")
                : dir.appendingPathComponent("\(base)_\(index).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
            index += 1
        }
        return dir.appendingPathComponent("\(base)_\(UUID().uuidString.prefix(8))"
            + (ext.isEmpty ? "" : ".\(ext)")).path
    }

    /// 生成 8 位短哈希，用于重命名模板
    static func shortHash(_ item: MediaItem) -> String {
        if let h = item.contentHash, h.count >= 8 { return String(h.prefix(8)) }
        if let q = item.quickSignature, q.count >= 8 { return String(q.prefix(8)) }
        if let p = item.perceptualHash {
            return String(format: "%08x", UInt32(truncatingIfNeeded: p))
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: item.id.hashValue))
    }
}
