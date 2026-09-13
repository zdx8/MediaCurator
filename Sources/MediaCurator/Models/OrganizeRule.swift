import Foundation

// MARK: - 目标名冲突策略

enum ConflictPolicy: String, Codable, CaseIterable, Hashable {
    /// 自动追加序号 `_1`、`_2`
    case autoNumber
    /// 目标已存在则跳过该文件
    case skip
    /// 覆盖目标（默认不启用，风险较高）
    case overwrite

    var displayName: String {
        switch self {
        case .autoNumber: return "自动追加序号"
        case .skip: return "跳过已存在"
        case .overwrite: return "覆盖同名文件"
        }
    }

    var explanation: String {
        switch self {
        case .autoNumber: return "目标目录已有同名文件时，重命名为 name_1、name_2"
        case .skip: return "目标目录已有同名文件时，保留现场不做处理"
        case .overwrite: return "目标同名文件先移入回收站，再由新文件顶替（可撤销找回）"
        }
    }
}

// MARK: - 搬运方式

enum TransferMode: String, Codable, CaseIterable, Hashable {
    /// 移动（默认），整理后会释放源位置空间
    case move
    /// 复制，源文件保留
    case copy

    var displayName: String {
        switch self {
        case .move: return "移动"
        case .copy: return "复制"
        }
    }
}

// MARK: - 整理规则

struct OrganizeRule: Codable, Equatable {

    /// 目标目录模板，支持 `{yyyy}` 等变量，`/` 分隔层级
    var folderTemplate: String = "{yyyy}/{MM}/{MM-dd}"

    /// 重命名模板；留空表示保留原文件名
    var renameTemplate: String = ""

    /// 无法确定拍摄时间时使用的目录名
    var unknownDateFolder: String = "未识别日期"

    /// 排序编号的起始值
    var sequenceStart: Int = 1
    /// 排序编号补零位数
    var sequencePadding: Int = 3

    var conflictPolicy: ConflictPolicy = .autoNumber
    var transferMode: TransferMode = .move

    /// 目标根目录；为空表示“原地整理”（在各源目录内部建立子目录）
    var destinationRoot: String = ""

    /// 只处理拍摄时间在该范围内的文件；nil 表示不限
    var dateFrom: Date?
    var dateTo: Date?

    /// 只处理拍摄时间来源至少达到该可信度的文件
    var minimumTimeSourceConfidence: Int = 0

    /// 只处理指定设备（空集合表示不限）
    var deviceFilter: Set<String> = []

    var isInPlace: Bool { destinationRoot.trimmingCharacters(in: .whitespaces).isEmpty }

    static let folderPresets: [(String, String)] = [
        ("年 / 月 / 月-日 / 设备", "{yyyy}/{MM}/{MM-dd}/{camera}"),
        ("年 / 月 / 月-日 / 类型", "{yyyy}/{MM}/{MM-dd}/{kind}"),
        ("年 / 月 / 月-日", "{yyyy}/{MM}/{MM-dd}"),
        ("年 / 月-日 / 设备", "{yyyy}/{MM-dd}/{camera}"),
        ("年 / 月-日 / 类型", "{yyyy}/{MM-dd}/{kind}"),
        ("年 / 月-日", "{yyyy}/{MM-dd}"),
        ("月-日 / 设备", "{MM-dd}/{camera}"),
        ("月-日 / 类型", "{MM-dd}/{kind}"),
        ("月-日", "{MM-dd}")
    ]

    static let renamePresets: [(String, String)] = [
        ("保持原文件名", ""),
        ("日期时间_原文件名", "{datetime}_{orig}"),
        ("原文件名_短哈希", "{orig}_{hash8}"),
        ("日期时间_设备_序号", "{datetime}_{camera}_{seq}"),
        ("设备_日期_序号", "{camera}_{yyyyMMdd}_{seq}"),
        ("日期_序号", "{yyyyMMdd}_{seq}"),
        ("拍摄时间(紧凑)", "{yyyyMMdd_HHmmss}")
    ]

    static let templateVariables: [(String, String)] = [
        ("{yyyy}", "四位年份"),
        ("{yy}", "两位年份"),
        ("{MM}", "月份 01–12"),
        ("{dd}", "日期 01–31"),
        ("{HH}", "小时 00–23"),
        ("{mm}", "分钟 00–59"),
        ("{ss}", "秒 00–59"),
        ("{yyyyMMdd}", "紧凑日期 20240315"),
        ("{HHmmss}", "紧凑时间 143022"),
        ("{yyyy-MM-dd}", "2024-03-15"),
        ("{yyyy-MM}", "2024-03"),
        ("{MM-dd}", "03-15"),
        ("{yyyyMMdd_HHmmss}", "20240315_143022"),
        ("{yyyy-MM-dd_HH-mm-ss}", "2024-03-15_14-30-22"),
        ("{yyyy年MM月dd日}", "2024年03月15日"),
        ("{yyyy年MM月}", "2024年03月"),
        ("{datetime}", "2024-03-15_14-30-22"),
        ("{date}", "2024-03-15"),
        ("{time}", "14-30-22"),
        ("{weekNumber}", "一年中的第几周"),
        ("{camera}", "设备名（厂商+型号）"),
        ("{make}", "厂商"),
        ("{model}", "型号"),
        ("{lens}", "镜头"),
        ("{kind}", "图片 / 视频"),
        ("{ext}", "扩展名（不含点）"),
        ("{orig}", "原文件名（不含扩展名）"),
        ("{seq}", "排序编号"),
        ("{hash8}", "内容哈希前 8 位"),
        ("{sourceFolder}", "来源根目录名")
    ]
}

// MARK: - 计划生成范围

/// 一次生成计划时「做什么」的开关集合
struct PlanFilter: Equatable, Codable {
    /// 生成归档操作（按模板移动 / 重命名）
    var archiveFiles: Bool = true
    /// 把重复组里被判为冗余的副本移入回收站
    var cleanRedundantDuplicates: Bool = false
    /// 只处理重复项的冗余副本，忽略归档（纯清理模式）
    var onlyRedundantDuplicates: Bool = false

    var includeImages: Bool = true
    var includeVideos: Bool = true
    /// 低于该像素数量的图片不参与归档
    var minimumPixelCount: Int = 0

    var doesAnyWork: Bool { archiveFiles || cleanRedundantDuplicates }
}
