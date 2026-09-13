import Foundation

// MARK: - 重复类型

enum DuplicateKind: String, Codable, Hashable, CaseIterable {
    case exact          // 字节完全一致（SHA-256 相同）
    case similarImage   // 图片感知哈希接近
    case similarVideo   // 视频抽帧指纹接近

    var displayName: String {
        switch self {
        case .exact: return "精确重复"
        case .similarImage: return "相似图片"
        case .similarVideo: return "相似视频"
        }
    }

    var symbolName: String {
        switch self {
        case .exact: return "equal.circle"
        case .similarImage: return "photo.on.rectangle.angled"
        case .similarVideo: return "film.stack"
        }
    }

    /// 优先级：精确重复的结论比相似更强
    var rank: Int {
        switch self {
        case .exact: return 0
        case .similarVideo: return 1
        case .similarImage: return 2
        }
    }
}

/// 推荐保留某张/某个视频的理由
enum KeepReason: String, Codable, Hashable {
    case exactDuplicate      // 与其他成员字节一致
    case highestResolution
    case largestFile
    case earliestCapture
    case trustedTimestamp
    case shallowestPath
    case manual

    var displayName: String {
        switch self {
        case .exactDuplicate: return "内容完全相同，保留任意一个即可"
        case .highestResolution: return "分辨率最高"
        case .largestFile: return "文件体积最大（通常码率更高）"
        case .earliestCapture: return "拍摄时间最早"
        case .trustedTimestamp: return "拍摄时间来源更可信"
        case .shallowestPath: return "目录层级最浅"
        case .manual: return "人工指定"
        }
    }
}

// MARK: - 整组决定

/// 一组重复项的整体处置方式。
///
/// 做成**三态枚举**而不是几个布尔开关，是因为它天然互斥：
/// 「这几张都要留」和「这些一张都不要」不可能同时成立。
/// 之前用单个 `keepWholeGroup: Bool` 时，每加一种新决定就要多一个布尔，
/// 迟早会出现「两个开关都打开」这种自相矛盾的状态，而计划生成还得自己判断谁优先。
/// 现在处置方式只有一个来源，计划、摘要、界面文案都从它派生。
enum GroupDisposition: String, Hashable, CaseIterable {
    /// 按组内勾选（默认）：勾上的留下，没勾的算冗余副本
    case bySelection
    /// 保留整组：本组不产生任何清理操作
    case keepAll
    /// 都不保留：本组所有成员都会被移入系统回收站
    case discardAll

    var displayName: String {
        switch self {
        case .bySelection: return "按勾选"
        case .keepAll: return "保留整组"
        case .discardAll: return "都不保留"
        }
    }
}

// MARK: - 重复组

/// 一组互相重复或高度相似的媒体。
///
/// `keepIDs` 是用户决定保留的成员，**支持多选** —— 同组里「这几张都要留」是常态
/// （连拍里挑中的两张、同一段视频的横竖两版），只允许留一个会逼着用户去手工操作。
/// 程序检测时先给一个推荐项，用户再按需增减。
struct DuplicateGroup: Identifiable, Hashable {
    let id: UUID
    var kind: DuplicateKind
    /// 组内成员 id，首位是程序推荐保留的那个
    var memberIDs: [UUID]
    /// 用户决定保留的成员。空集合会被 `effectiveKeepIDs` 兜底，见那里的说明。
    var keepIDs: Set<UUID>
    /// 推荐理由（针对程序推荐的那一个成员）
    var keepReason: KeepReason = .manual
    /// 组内最大汉明距离（精确重复为 0）
    var maxDistance: Int = 0
    /// 重复组之间合并时记录来源
    var mergedFrom: Int = 1

    /// 整组决定。默认按勾选；`keepAll` / `discardAll` 会覆盖逐张勾选的结果。
    ///
    /// 两种整组决定都只影响**清理**，不影响归档 —— 除非被清掉，
    /// 文件仍会按整理规则被移动到目标目录。
    var disposition: GroupDisposition = .bySelection

    init(id: UUID = UUID(),
         kind: DuplicateKind,
         memberIDs: [UUID],
         keepIDs: Set<UUID> = [],
         keepReason: KeepReason = .manual,
         maxDistance: Int = 0,
         mergedFrom: Int = 1,
         disposition: GroupDisposition = .bySelection) {
        self.id = id
        self.kind = kind
        self.memberIDs = memberIDs
        self.keepIDs = keepIDs
        self.keepReason = keepReason
        self.maxDistance = maxDistance
        self.mergedFrom = mergedFrom
        self.disposition = disposition
    }

    var memberCount: Int { memberIDs.count }

    /// 本组是否已被整组保留（不产生任何清理）
    var keepWholeGroup: Bool { disposition == .keepAll }
    /// 本组是否已被整组清理（一份都不留）
    var discardWholeGroup: Bool { disposition == .discardAll }

    /// 实际生效的保留集合。
    ///
    /// **空集合是危险状态**：那样整组都会被当成冗余副本，清理计划会把原件也移进回收站。
    /// 界面上不允许取消最后一个勾选，这里再兜一层 —— 摘要计算只读这个属性，
    /// 不直接读 `keepIDs`，逐张勾选的路径不会出现「一组全被判为冗余」。
    ///
    /// 注意：`discardAll` 是**用户显式**选择「一张都不要」的结果，
    /// 它不通过这个兜底来表达，而是由 `redundantMemberIDs` 统一收口。
    var effectiveKeepIDs: Set<UUID> {
        if keepIDs.isEmpty, let first = memberIDs.first { return [first] }
        return keepIDs
    }

    /// 本组会被清理的成员 —— **整组决定的唯一收口处**。
    ///
    /// 计划生成、摘要统计、界面文案都只读它，不再各自拼一遍条件：
    /// 三处各写一份判断，迟早会出现「界面说清理 2 份、计划却清理 3 份」。
    var redundantMemberIDs: Set<UUID> {
        switch disposition {
        case .keepAll: return []
        case .discardAll: return Set(memberIDs)
        case .bySelection: return Set(memberIDs).subtracting(effectiveKeepIDs)
        }
    }

    /// 会被清理的成员数量
    var removableCount: Int { redundantMemberIDs.count }

    /// 组内是否每个成员都被标记为保留（此时等价于整组不清理，但语义不同：
    /// 这是逐张勾选的结果，而 `keepAll` 是「这几张都要留」的整组决定）
    var allMembersKept: Bool { redundantMemberIDs.isEmpty }

    /// 本组可释放的字节数
    func reclaimableBytes(sizes: [UUID: Int64]) -> Int64 {
        let redundant = redundantMemberIDs
        return redundant.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
    }
}

// MARK: - 查重汇总

struct DedupSummary {
    var exactGroupCount: Int = 0
    var similarImageGroupCount: Int = 0
    var similarVideoGroupCount: Int = 0
    var redundantFileCount: Int = 0
    var reclaimableBytes: Int64 = 0
    /// 被用户设为「保留整组」的组数
    var keptWholeGroupCount: Int = 0
    /// 被用户设为「都不保留」的组数
    var discardedWholeGroupCount: Int = 0

    var totalGroupCount: Int {
        exactGroupCount + similarImageGroupCount + similarVideoGroupCount
    }

    var reclaimableLabel: String {
        ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)
    }

    /// 从分组与文件体积重算。
    ///
    /// 之所以做成「可从分组重算」而不是只在检测时算一次：
    /// 用户在界面上改保留项或整组决定之后，冗余数与可释放空间都必须跟着变，
    /// 否则摘要会和实际计划对不上。检测阶段也走这个函数，不另写一份算法。
    ///
    /// 调用方不该把它当成「算过一次就不用管」的缓存 —— `AppState.groups` 一有变化
    /// 就会重新算（见那里的属性观察器），漏刷一次就会让顶部计数和实际分组对不上。
    static func compute(groups: [DuplicateGroup], sizes: [UUID: Int64]) -> DedupSummary {
        var summary = DedupSummary()
        for group in groups {
            switch group.kind {
            case .exact: summary.exactGroupCount += 1
            case .similarImage: summary.similarImageGroupCount += 1
            case .similarVideo: summary.similarVideoGroupCount += 1
            }
            switch group.disposition {
            case .keepAll: summary.keptWholeGroupCount += 1
            case .discardAll: summary.discardedWholeGroupCount += 1
            case .bySelection: break
            }
            summary.redundantFileCount += group.removableCount
            summary.reclaimableBytes += group.reclaimableBytes(sizes: sizes)
        }
        return summary
    }
}
