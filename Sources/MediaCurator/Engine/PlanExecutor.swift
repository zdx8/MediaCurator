import Foundation

struct ExecutionProgress: Equatable {
    var total: Int = 0
    var completed: Int = 0
    var succeeded: Int = 0
    var failed: Int = 0
    var currentPath: String = ""

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
}

typealias ExecutionProgressHandler = @MainActor @Sendable (ExecutionProgress) -> Void

struct ExecutionReport {
    var session: JournalSession
    var succeeded: Int = 0
    var failed: Int = 0
    var skipped: Int = 0
    var reclaimedBytes: Int64 = 0
    var messages: [String] = []

    var summaryLine: String {
        var parts = ["成功 \(succeeded)"]
        if skipped > 0 { parts.append("跳过 \(skipped)") }
        if failed > 0 { parts.append("失败 \(failed)") }
        if reclaimedBytes > 0 {
            parts.append("释放 " + ByteCountFormatter.string(fromByteCount: reclaimedBytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 日志存储

enum JournalStore {

    /// 仅供自检使用的日志目录重定向。
    ///
    /// 自检会真的执行计划、也就必须真的落盘日志；但绝不能写进用户的日志目录 ——
    /// 否则每跑一次自检，用户的「操作日志」页就凭空多出几条他从未做过的操作。
    /// （这个污染真实发生过：反复调试后日志页里堆了四十多条假记录。）
    private static let overrideLock = NSLock()
    private static var _overrideDirectory: URL?

    static var overrideDirectory: URL? {
        get { overrideLock.lock(); defer { overrideLock.unlock() }; return _overrideDirectory }
        set { overrideLock.lock(); _overrideDirectory = newValue; overrideLock.unlock() }
    }

    static var directory: URL {
        if let override = overrideDirectory {
            try? FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("MediaCurator/Journals", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func makeSessionFile() -> URL {
        let stamp = DateFormat.fileStamp(Date())
        let unique = String(UUID().uuidString.prefix(6))
        return directory.appendingPathComponent("\(stamp)-\(unique).jsonl")
    }

    /// 逐条追加。中途崩溃也不会丢掉已经完成的操作记录。
    static func append(_ entry: JournalEntry, to file: URL) {
        guard let data = try? encoder.encode(entry) else { return }
        var line = data
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file, options: .atomic)
        }
    }

    /// 撤销后会改写整份日志（条目数量有限，整体重写最简单可靠）
    static func rewrite(_ entries: [JournalEntry], to file: URL) {
        var payload = Data()
        for entry in entries {
            guard let data = try? encoder.encode(entry) else { continue }
            payload.append(data)
            payload.append(0x0A)
        }
        try? payload.write(to: file, options: .atomic)
    }

    static func loadEntries(from file: URL) -> [JournalEntry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var entries: [JournalEntry] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8) else { continue }
            if let entry = try? decoder.decode(JournalEntry.self, from: data) {
                entries.append(entry)
            }
        }
        return entries
    }

    static func loadSessions() -> [JournalSession] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]))?
            .filter { $0.pathExtension == "jsonl" } ?? []

        var sessions: [JournalSession] = []
        for file in files {
            let entries = loadEntries(from: file)
            guard !entries.isEmpty else { continue }
            let stamps = entries.map { $0.timestamp }
            sessions.append(JournalSession(
                id: file.path,
                startedAt: stamps.min() ?? Date(),
                finishedAt: stamps.max(),
                entries: entries,
                filePath: file.path))
        }
        sessions.sort { $0.startedAt > $1.startedAt }
        return sessions
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension DateFormat {
    /// 用于日志文件名：20260913-145630
    static func fileStamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}

// MARK: - 执行器

/// 计划执行器。
///
/// 安全约束（硬性）：
/// - 只做三件事：移动、复制、**移入回收站**。绝不调用不可恢复的删除；
/// - 每条操作先做前置校验（源存在、目标目录可写），不满足就记为失败而不是强行执行；
/// - 每一条结果都落盘到日志，重命名/移动可原路回退，回收站文件可从日志里找到位置。
enum PlanExecutor {

    static func execute(operations: [PlanOperation],
                        onProgress: ExecutionProgressHandler? = nil) async -> ExecutionReport {
        let file = JournalStore.makeSessionFile()
        var entries: [JournalEntry] = []

        let selected = operations.filter { $0.selected && $0.kind.isMutating }
        // 先搬运后清理：万一搬运阶段出错，回收站里还不该有东西
        let ordered = selected.filter { $0.kind != .trash } + selected.filter { $0.kind == .trash }

        var report = ExecutionReport(session: JournalSession(
            id: file.path, startedAt: Date(), entries: [], filePath: file.path))

        var progress = ExecutionProgress(total: ordered.count)
        await onProgress?(progress)

        for operation in ordered {
            if Task.isCancelled {
                report.messages.append("执行被用户中断，已完成的操作仍可通过日志撤销。")
                break
            }

            progress.currentPath = operation.sourcePath
            // 一条操作可能产出多条日志：开启「覆盖」时，被顶掉的原文件也会记一条，
            // 撤销时才能把它从回收站取回来。
            let produced = perform(operation)
            for entry in produced {
                entries.append(entry)
                JournalStore.append(entry, to: file)
            }
            // 主结果取最后一条 —— 前面的都是为它让路的辅助记录
            guard let entry = produced.last else { continue }

            switch entry.result {
            case .success:
                report.succeeded += 1
                progress.succeeded += 1
                if operation.kind == .trash { report.reclaimedBytes += operation.fileSize }
            case .failed:
                report.failed += 1
                progress.failed += 1
                if report.messages.count < 12, let message = entry.message {
                    report.messages.append("\(operation.fileName)：\(message)")
                }
            case .skipped:
                report.skipped += 1
            case .undone:
                break
            }

            progress.completed += 1
            await onProgress?(progress)
        }

        report.session.entries = entries
        report.session.finishedAt = Date()
        return report
    }

    // MARK: - 单条操作

    /// 执行一条操作，返回它产生的日志条目。
    ///
    /// 正常情况只返回一条；开启「覆盖同名文件」且目标确实已存在时返回两条：
    /// 第一条记录「原文件被移入回收站」，第二条才是本操作本身。
    /// 顺序很重要 —— 撤销是逆序进行的，先回退本操作腾出目标位置，
    /// 再把被顶掉的原文件取回来，两者才能同时回到原位。
    private static func perform(_ operation: PlanOperation) -> [JournalEntry] {
        let source = URL(fileURLWithPath: operation.sourcePath)
        let manager = FileManager.default

        guard manager.fileExists(atPath: operation.sourcePath) else {
            return [JournalEntry(kind: operation.kind,
                                 sourcePath: operation.sourcePath,
                                 destinationPath: operation.destinationPath,
                                 result: .failed,
                                 message: "源文件已不存在",
                                 fileSize: operation.fileSize)]
        }

        switch operation.kind {
        case .alreadyPlaced, .skipped:
            return [JournalEntry(kind: operation.kind,
                                 sourcePath: operation.sourcePath,
                                 destinationPath: operation.destinationPath,
                                 result: .skipped,
                                 message: operation.reason,
                                 fileSize: operation.fileSize)]

        case .move, .rename, .copy:
            guard let destinationPath = operation.destinationPath else {
                return [JournalEntry(kind: operation.kind,
                                     sourcePath: operation.sourcePath,
                                     destinationPath: nil,
                                     result: .failed,
                                     message: "缺少目标路径",
                                     fileSize: operation.fileSize)]
            }
            let destination = URL(fileURLWithPath: destinationPath)
            let parent = destination.deletingLastPathComponent()

            do {
                if !manager.fileExists(atPath: parent.path) {
                    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
                }
            } catch {
                return [JournalEntry(kind: operation.kind,
                                     sourcePath: operation.sourcePath,
                                     destinationPath: destinationPath,
                                     result: .failed,
                                     message: "无法创建目标目录：\(error.localizedDescription)",
                                     fileSize: operation.fileSize)]
            }

            var produced: [JournalEntry] = []

            // 计划生成到执行之间可能已经出现同名文件，这里再确认一次
            if manager.fileExists(atPath: destinationPath) {
                guard operation.overwritesExisting else {
                    return [JournalEntry(kind: operation.kind,
                                         sourcePath: operation.sourcePath,
                                         destinationPath: destinationPath,
                                         result: .failed,
                                         message: "目标已存在同名文件，未执行",
                                         fileSize: operation.fileSize)]
                }
                // 先把原文件移入回收站，而不是直接删除 —— 撤销时能原样取回
                var displaced: NSURL?
                do {
                    try manager.trashItem(at: destination, resultingItemURL: &displaced)
                    produced.append(JournalEntry(kind: .trash,
                                                 sourcePath: destinationPath,
                                                 destinationPath: nil,
                                                 result: .success,
                                                 message: "被同名文件顶替，已移入回收站（撤销可取回）",
                                                 fileSize: fileSizeOf(destinationPath),
                                                 trashPath: (displaced as URL?)?.path))
                } catch {
                    // 腾不出位置就不动原文件，整条操作记为失败
                    return [JournalEntry(kind: operation.kind,
                                         sourcePath: operation.sourcePath,
                                         destinationPath: destinationPath,
                                         result: .failed,
                                         message: "目标已存在同名文件，且无法移入回收站：\(error.localizedDescription)",
                                         fileSize: operation.fileSize)]
                }
            }

            do {
                if operation.kind == .copy {
                    try manager.copyItem(at: source, to: destination)
                } else {
                    try manager.moveItem(at: source, to: destination)
                }
                produced.append(JournalEntry(kind: operation.kind,
                                             sourcePath: operation.sourcePath,
                                             destinationPath: destinationPath,
                                             result: .success,
                                             message: operation.reason,
                                             fileSize: operation.fileSize))
            } catch {
                produced.append(JournalEntry(kind: operation.kind,
                                             sourcePath: operation.sourcePath,
                                             destinationPath: destinationPath,
                                             result: .failed,
                                             message: error.localizedDescription,
                                             fileSize: operation.fileSize))
            }
            return produced

        case .trash:
            var resulting: NSURL?
            do {
                try manager.trashItem(at: source, resultingItemURL: &resulting)
                return [JournalEntry(kind: .trash,
                                     sourcePath: operation.sourcePath,
                                     destinationPath: nil,
                                     result: .success,
                                     message: operation.reason,
                                     fileSize: operation.fileSize,
                                     trashPath: (resulting as URL?)?.path)]
            } catch {
                return [JournalEntry(kind: .trash,
                                     sourcePath: operation.sourcePath,
                                     destinationPath: nil,
                                     result: .failed,
                                     message: "移入回收站失败：\(error.localizedDescription)",
                                     fileSize: operation.fileSize)]
            }
        }
    }

    private static func fileSizeOf(_ path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - 撤销

    struct UndoReport {
        var restored: Int = 0
        var removedCopies: Int = 0
        var failed: Int = 0
        var messages: [String] = []

        var summaryLine: String {
            var parts = ["还原 \(restored)"]
            if removedCopies > 0 { parts.append("移除副本 \(removedCopies)") }
            if failed > 0 { parts.append("失败 \(failed)") }
            return parts.joined(separator: " · ")
        }
    }

    /// 按相反顺序回退一次执行。移动/重命名原路退回，回收站里的文件从回收站取回。
    static func undo(session: JournalSession) async -> UndoReport {
        var report = UndoReport()
        guard let filePath = session.filePath else {
            report.messages.append("找不到该次执行的日志文件")
            return report
        }
        let file = URL(fileURLWithPath: filePath)
        var entries = session.entries

        // 逆序回退：后做的先撤
        for index in stride(from: entries.count - 1, through: 0, by: -1) {
            var entry = entries[index]
            guard entry.result == .success, !entry.undone else { continue }

            let manager = FileManager.default
            let source = URL(fileURLWithPath: entry.sourcePath)

            var failure: String?

            switch entry.kind {
            case .move, .rename:
                guard let destinationPath = entry.destinationPath else { continue }
                let destination = URL(fileURLWithPath: destinationPath)
                guard manager.fileExists(atPath: destinationPath) else {
                    failure = "目标位置的副本已不存在，无法还原"
                    break
                }
                if manager.fileExists(atPath: entry.sourcePath) {
                    // 原位置被别的东西占了，退回时加序号而不是覆盖
                    let alternative = PlanBuilder.numberedAlternative(entry.sourcePath, reserved: [])
                    do {
                        try manager.moveItem(at: destination, to: URL(fileURLWithPath: alternative))
                        report.restored += 1
                        report.messages.append("原位置已被占用，已还原为 \(URL(fileURLWithPath: alternative).lastPathComponent)")
                        entry.undone = true
                        entries[index] = entry
                        continue
                    } catch {
                        failure = error.localizedDescription
                        break
                    }
                }
                do {
                    try manager.moveItem(at: destination, to: source)
                    report.restored += 1
                    entry.undone = true
                } catch {
                    failure = error.localizedDescription
                }

            case .copy:
                guard let destinationPath = entry.destinationPath else { continue }
                let destination = URL(fileURLWithPath: destinationPath)
                guard manager.fileExists(atPath: destinationPath) else {
                    entry.undone = true
                    entries[index] = entry
                    continue
                }
                var resulting: NSURL?
                do {
                    // 撤销复制时也不用删除，直接进回收站，留一条后路
                    try manager.trashItem(at: destination, resultingItemURL: &resulting)
                    report.removedCopies += 1
                    entry.undone = true
                } catch {
                    failure = error.localizedDescription
                }

            case .trash:
                guard let trashPath = entry.trashPath else {
                    failure = "日志未记录回收站位置，请手动从回收站取回"
                    break
                }
                let trashed = URL(fileURLWithPath: trashPath)
                guard manager.fileExists(atPath: trashPath) else {
                    failure = "回收站中的文件已被清空，无法还原"
                    break
                }
                if manager.fileExists(atPath: entry.sourcePath) {
                    failure = "原位置已存在同名文件，未还原以免覆盖"
                    break
                }
                do {
                    try manager.moveItem(at: trashed, to: source)
                    report.restored += 1
                    entry.undone = true
                } catch {
                    failure = error.localizedDescription
                }

            case .alreadyPlaced, .skipped:
                continue
            }

            if let failure {
                entry.result = .failed
                entry.message = "撤销失败：" + failure
                report.failed += 1
                report.messages.append("\(URL(fileURLWithPath: entry.sourcePath).lastPathComponent)：\(failure)")
            }
            entries[index] = entry
        }

        JournalStore.rewrite(entries, to: file)
        return report
    }
}
