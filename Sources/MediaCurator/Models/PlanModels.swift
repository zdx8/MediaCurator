import Foundation

// MARK: - 操作类型

enum OperationKind: String, Codable, CaseIterable, Hashable {
    /// 移动到新位置（目标目录或新文件名）
    case move
    /// 原位置不变，仅改名
    case rename
    /// 复制到新位置，源文件保留
    case copy
    /// 移入系统回收站
    case trash
    /// 已在目标位置，无需处理
    case alreadyPlaced
    /// 因冲突策略跳过
    case skipped

    var displayName: String {
        switch self {
        case .move: return "移动"
        case .rename: return "重命名"
        case .copy: return "复制"
        case .trash: return "移入回收站"
        case .alreadyPlaced: return "已就位"
        case .skipped: return "跳过"
        }
    }

    var symbolName: String {
        switch self {
        case .move: return "arrow.right.doc.on.clipboard"
        case .rename: return "pencil"
        case .copy: return "plus.square.on.square"
        case .trash: return "trash"
        case .alreadyPlaced: return "checkmark.circle"
        case .skipped: return "minus.circle"
        }
    }

    /// 是否为真正会改动文件系统的操作
    var isMutating: Bool {
        switch self {
        case .move, .rename, .copy, .trash: return true
        case .alreadyPlaced, .skipped: return false
        }
    }

    var isDestructive: Bool { self == .trash }
}

// MARK: - 单条计划项

struct PlanOperation: Identifiable, Hashable {
    let id: UUID
    var kind: OperationKind
    var itemID: UUID
    var sourcePath: String
    var destinationPath: String?
    /// 触发该操作的原因，展示给用户
    var reason: String
    /// 所属重复组（若来自查重流程）
    var groupID: UUID?
    var fileSize: Int64
    var kindOfMedia: MediaKind
    var fileName: String
    /// 界面上是否勾选执行
    var selected: Bool
    /// 目标位置已存在同名文件，且用户选了「覆盖」策略。
    ///
    /// 明确记下这个意图，而不是让执行器去猜 —— 否则就会出现「计划说覆盖、执行却失败」
    /// 这种计划与执行不一致的情况。执行时的动作是：先把已存在的文件**移入回收站**，
    /// 再让本操作落位；不是不可恢复的删除，撤销时两者都会回到原位。
    var overwritesExisting: Bool

    init(id: UUID = UUID(),
         kind: OperationKind,
         itemID: UUID,
         sourcePath: String,
         destinationPath: String?,
         reason: String,
         groupID: UUID? = nil,
         fileSize: Int64 = 0,
         kindOfMedia: MediaKind = .other,
         fileName: String = "",
         selected: Bool = true,
         overwritesExisting: Bool = false) {
        self.id = id
        self.kind = kind
        self.itemID = itemID
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.reason = reason
        self.groupID = groupID
        self.fileSize = fileSize
        self.kindOfMedia = kindOfMedia
        self.fileName = fileName
        self.selected = selected
        self.overwritesExisting = overwritesExisting
    }
}

// MARK: - 计划汇总

struct PlanSummary {
    var moveCount = 0
    var renameCount = 0
    var copyCount = 0
    var trashCount = 0
    var skippedCount = 0
    var alreadyPlacedCount = 0
    var moveBytes: Int64 = 0
    var reclaimableBytes: Int64 = 0

    var totalSelected: Int { moveCount + renameCount + copyCount + trashCount }
    var totalRows: Int { totalSelected + skippedCount + alreadyPlacedCount }

    var moveBytesLabel: String {
        ByteCountFormatter.string(fromByteCount: moveBytes, countStyle: .file)
    }
    var reclaimableLabel: String {
        ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)
    }

    static func compute(from ops: [PlanOperation]) -> PlanSummary {
        var s = PlanSummary()
        for op in ops {
            switch op.kind {
            case .move:
                s.moveCount += 1
                if op.selected { s.moveBytes += op.fileSize }
            case .rename: s.renameCount += 1
            case .copy: s.copyCount += 1
            case .trash:
                s.trashCount += 1
                if op.selected { s.reclaimableBytes += op.fileSize }
            case .skipped: s.skippedCount += 1
            case .alreadyPlaced: s.alreadyPlacedCount += 1
            }
        }
        return s
    }
}

// MARK: - 执行日志

enum JournalResult: String, Codable, Hashable {
    case success
    case failed
    case skipped
    case undone

    var displayName: String {
        switch self {
        case .success: return "成功"
        case .failed: return "失败"
        case .skipped: return "跳过"
        case .undone: return "已撤销"
        }
    }
}

struct JournalEntry: Identifiable, Hashable, Codable {
    var id: UUID
    var timestamp: Date
    var kind: OperationKind
    var sourcePath: String
    var destinationPath: String?
    var result: JournalResult
    var message: String?
    var fileSize: Int64
    /// 被移入回收站后的实际位置
    var trashPath: String?
    var undone: Bool

    init(kind: OperationKind,
         sourcePath: String,
         destinationPath: String?,
         result: JournalResult,
         message: String? = nil,
         fileSize: Int64 = 0,
         trashPath: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.kind = kind
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.result = result
        self.message = message
        self.fileSize = fileSize
        self.trashPath = trashPath
        self.undone = false
    }

    // 手写解码：新增字段时旧日志仍可解析
    enum CodingKeys: String, CodingKey {
        case id, timestamp, kind, sourcePath, destinationPath, result, message, fileSize, trashPath, undone
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        timestamp = (try? c.decode(Date.self, forKey: .timestamp)) ?? Date()
        kind = (try? c.decode(OperationKind.self, forKey: .kind)) ?? .move
        sourcePath = (try? c.decode(String.self, forKey: .sourcePath)) ?? ""
        destinationPath = try? c.decodeIfPresent(String.self, forKey: .destinationPath)
        result = (try? c.decode(JournalResult.self, forKey: .result)) ?? .failed
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        fileSize = (try? c.decode(Int64.self, forKey: .fileSize)) ?? 0
        trashPath = try? c.decodeIfPresent(String.self, forKey: .trashPath)
        undone = (try? c.decode(Bool.self, forKey: .undone)) ?? false
    }
}

/// 一次执行会话的完整记录
struct JournalSession: Identifiable, Hashable {
    /// 用日志文件路径作为稳定标识，便于界面在多次刷新之间保持一致
    let id: String
    var startedAt: Date
    var finishedAt: Date?
    var entries: [JournalEntry]
    /// 日志文件落盘位置
    var filePath: String?

    init(id: String, startedAt: Date, finishedAt: Date? = nil,
         entries: [JournalEntry], filePath: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.entries = entries
        self.filePath = filePath
    }

    var successCount: Int { entries.filter { $0.result == .success }.count }
    var failedCount: Int { entries.filter { $0.result == .failed }.count }
    var undoneCount: Int { entries.filter { $0.undone }.count }
    var reclaimedBytes: Int64 {
        entries.filter { $0.result == .success && $0.kind == .trash && !$0.undone }
            .reduce(Int64(0)) { $0 + $1.fileSize }
    }
    var canUndo: Bool {
        entries.contains { $0.result == .success && !$0.undone && $0.kind != .skipped }
    }
}

// MARK: - 扫描阶段

enum ScanPhase: Equatable {
    case idle
    case enumerating
    case processing
    case analyzing
    case finished
    case cancelled
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .enumerating, .processing, .analyzing: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .idle: return "待扫描"
        case .enumerating: return "正在枚举文件"
        case .processing: return "正在读取元数据与指纹"
        case .analyzing: return "正在比对重复"
        case .finished: return "扫描完成"
        case .cancelled: return "已取消"
        case .failed: return "扫描失败"
        }
    }
}

struct ScanProgress: Equatable {
    var phase: ScanPhase = .idle
    var total: Int = 0
    var processed: Int = 0
    var currentFile: String = ""
    var startedAt: Date?
    var cachedHits: Int = 0
    var failureCount: Int = 0

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(processed) / Double(total))
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    var throughputLabel: String {
        guard elapsed > 0.5, processed > 0 else { return "—" }
        let rate = Double(processed) / elapsed
        return String(format: "%.1f 个/秒", rate)
    }

    var remainingLabel: String {
        guard elapsed > 0.5, processed > 0, total > processed else { return "—" }
        let rate = Double(processed) / elapsed
        let remain = Double(total - processed) / rate
        if remain < 60 { return String(format: "约 %.0f 秒", remain) }
        return String(format: "约 %.1f 分钟", remain / 60)
    }
}
