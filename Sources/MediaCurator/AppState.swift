import Foundation
import SwiftUI
import AppKit

// MARK: - 页面

enum AppPage: String, CaseIterable, Identifiable {
    case scan
    case allMedia
    case duplicates
    case organize
    case plan
    case journal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: return "扫描"
        case .allMedia: return "所有媒体"
        case .duplicates: return "重复项"
        case .organize: return "整理规则"
        case .plan: return "执行计划"
        case .journal: return "操作日志"
        }
    }

    var subtitle: String {
        switch self {
        case .scan: return "选择目录、读取拍摄信息"
        case .allMedia: return "浏览全部文件，勾选要清理的"
        case .duplicates: return "审阅并决定保留哪一份"
        case .organize: return "目录结构与命名规则"
        case .plan: return "确认每一项改动"
        case .journal: return "执行记录与撤销"
        }
    }

    var symbolName: String {
        switch self {
        case .scan: return "magnifyingglass.circle"
        case .allMedia: return "square.grid.2x2"
        case .duplicates: return "square.on.square.dashed"
        case .organize: return "folder.badge.gearshape"
        case .plan: return "list.bullet.rectangle"
        case .journal: return "clock.arrow.circlepath"
        }
    }

    var step: Int {
        switch self {
        case .scan: return 1
        case .allMedia: return 2
        case .duplicates: return 3
        case .organize: return 4
        case .plan: return 5
        case .journal: return 6
        }
    }

    /// 官网截图用的稳定文件名。
    ///
    /// 刻意**不带步骤序号** —— 序号会随导航插入新页面而整体后移，
    /// 截图名跟着漂移就会让 `make_site_shots.sh` 里那张对照表失配
    /// （改了导航，官网截图静默少一张或错位）。文件名只跟页面身份绑定。
    var shotName: String {
        switch self {
        case .scan: return "scan"
        case .allMedia: return "all-media"
        case .duplicates: return "duplicates"
        case .organize: return "organize"
        case .plan: return "plan"
        case .journal: return "journal"
        }
    }
}

// MARK: - 「所有媒体」页的浏览筛选

/// 只决定这一页**看到**哪些文件，不参与计划生成。
///
/// 与 `PlanFilter` 刻意分开：那个是「这次要做什么操作」，这个是「现在想看什么」。
/// 合并成一个的话，用户为了找一张照片而临时改的筛选，会连带改变生成计划的范围。
struct MediaFilter: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case all, image, video

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: return "全部"
            case .image: return "图片"
            case .video: return "视频"
            }
        }

        var mediaKind: MediaKind? {
            switch self {
            case .all: return nil
            case .image: return .image
            case .video: return .video
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case capturedDesc, capturedAsc, name, sizeDesc

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .capturedDesc: return "拍摄时间 新→旧"
            case .capturedAsc: return "拍摄时间 旧→新"
            case .name: return "文件名"
            case .sizeDesc: return "体积 大→小"
            }
        }
    }

    var kind: Kind = .all
    var sort: Sort = .capturedDesc
    var keyword: String = ""

    var isDefault: Bool {
        kind == .all && sort == .capturedDesc && keyword.isEmpty
    }
}

// MARK: - 来源目录树

/// 一个来源目录，以及它下面出现过的所有子目录。
struct SourceFolderGroup: Identifiable {
    var id: String { root }
    /// 来源目录的绝对路径
    var root: String
    var name: String
    /// 含根在内、按路径字典序排列 —— 字典序等价于树的先序，直接顺序渲染即可
    var folders: [SourceSubfolder]
    var totalFileCount: Int
    var totalBytes: Int64

    var excludedCount: Int { folders.filter { $0.isExcluded }.count }

    /// 有下级的目录 —— 折叠箭头只在有下级时才画。
    /// 给叶子目录也画一个，点下去毫无反应，用户会当成坏了。
    var foldersWithChildren: Set<String> {
        var result: Set<String> = []
        for index in folders.indices where index + 1 < folders.count {
            // 先序序列里，紧邻的下一行层级更深，就说明当前这一行有子节点
            if folders[index + 1].depth > folders[index].depth {
                result.insert(folders[index].path)
            }
        }
        return result
    }

    /// 每个目录的**直接**下级数量（不含更深的后代）—— 折叠起来时要显示「里面有几个」
    var directChildCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for folder in folders where folder.depth > 0 {
            let parent = PathTools.normalized((folder.path as NSString).deletingLastPathComponent)
            counts[parent, default: 0] += 1
        }
        return counts
    }

    /// 按折叠状态算出实际要显示的行。
    ///
    /// 抽成数据层的纯函数而不是写在视图里，是为了**能被自检直接断言** ——
    /// 「收起一个目录后它的后代全部消失、再展开又原样回来」这种性质，
    /// 靠看截图是验不出来的（少几行和多几行在缩略图上很难分辨）。
    ///
    /// 依赖「字典序即先序」这个前提：子树在数组里一定是连续的一段，
    /// 所以只要记住当前折叠到哪一层，跳过层级更深的行即可，一次遍历完成。
    func visibleFolders(collapsed: Set<String>) -> [SourceSubfolder] {
        var result: [SourceSubfolder] = []
        var collapsedDepth: Int?
        for folder in folders {
            if let depth = collapsedDepth {
                if folder.depth > depth { continue }   // 仍在收起的子树里
                collapsedDepth = nil                   // 回到了同层或更外层
            }
            result.append(folder)
            if collapsed.contains(folder.path) { collapsedDepth = folder.depth }
        }
        return result
    }
}

struct SourceSubfolder: Identifiable {
    var id: String { path }
    var path: String
    var name: String
    /// 相对来源根的层级，根为 0
    var depth: Int
    /// 直接放在这个目录里的文件数与体积（不含子目录）
    var fileCount: Int
    var bytes: Int64
    /// 含子目录在内的文件总数
    var totalFileCount: Int
    /// 用户是否勾选了「不参与整理」
    var isExcluded: Bool
    /// 上级目录已被排除（自己没勾，但连带不参与）—— 界面要区分这两种状态
    var isInherited: Bool
}

// MARK: - 提示

struct AppNotice: Identifiable {
    enum Level { case info, success, warning, failure }

    let id = UUID()
    var level: Level
    var title: String
    var message: String
}

/// 全局状态。所有文件系统写操作都必须经过这里，并且只从「执行计划」页发起。
@MainActor
final class AppState: ObservableObject {

    // MARK: 配置
    @Published var settings = ScanSettings()
    @Published var rule = OrganizeRule()
    @Published var filter = PlanFilter()

    // MARK: 扫描结果
    @Published var items: [MediaItem] = []
    /// 重复分组。
    ///
    /// `dedupSummary` 是它的**派生数据**，所以这里挂了属性观察器：
    /// 只要分组变了就重算摘要，不依赖各个改动点自觉调用刷新。
    ///
    /// 之前是「谁改了分组谁负责刷新」，结果「执行计划后剔除失效分组」那条路径漏了，
    /// 顶部「整组保留 N 组」和摘要卡就一直显示已经不存在（或已被清理）的分组 ——
    /// 数字看起来只是差一点，用户却无法判断该信哪个。派生数据不该靠自觉同步。
    @Published var groups: [DuplicateGroup] = [] {
        didSet { refreshDedupSummary() }
    }
    @Published var dedupSummary = DedupSummary()
    @Published var failures: [ScanFailure] = []
    @Published var progress = ScanProgress()
    @Published var lastScanElapsed: TimeInterval = 0
    @Published var cachedHitCount: Int = 0

    // MARK: 计划
    @Published var operations: [PlanOperation] = []
    @Published var planSummary = PlanSummary()
    @Published var planWarnings: [String] = []
    @Published var folderCounts: [String: Int] = [:]

    // MARK: 执行
    @Published var executionProgress: ExecutionProgress?
    @Published var lastExecution: ExecutionReport?
    @Published var sessions: [JournalSession] = []

    // MARK: 界面
    @Published var page: AppPage = .scan
    @Published var notice: AppNotice?
    @Published var duplicateFilter: DuplicateKind? = nil
    @Published var isDedupRunning = false
    @Published var scannedOnce = false

    // MARK: 「所有媒体」页
    /// 勾选准备移入回收站的文件。
    ///
    /// 与「重复项」页的整组决定是两条独立的路：那边由程序判定哪几份算冗余，
    /// 这边由用户直接点名。两者最终都只生成 `trash` 操作，但各有各的生成入口，
    /// 不会互相覆盖 —— 在这页勾选不会改变任何一个重复组的决定。
    @Published var cleanupSelection: Set<UUID> = []
    @Published var mediaFilter = MediaFilter()

    /// 勾选了「不参与整理」的子目录（绝对路径）。
    ///
    /// 存路径而不是别的引用：重新扫描后目录内容会变、`MediaItem.id` 全部重来，
    /// 只有路径在两次扫描之间是稳定的。
    ///
    /// 作用范围刻意收窄成**只影响归档**（按模板移动 / 重命名）。重复项的清理
    /// 与这一页的手动勾选清理都不受它影响 —— 前者由程序判定哪些是冗余副本，
    /// 后者由用户逐张点名，两者都与「目录结构要不要重排」无关。
    @Published var excludedFromOrganizing: Set<String> = []

    let cache = FingerprintCache()

    /// 自检专用：置为 true 后 `persistPreferences()` 不再写 `UserDefaults`。
    ///
    /// 自检驱动的是真实的 `AppState`，其中不少动作会顺手持久化。若放任它写，
    /// 每跑一次自检都会覆盖用户的扫描目录、整理规则、以及「不参与整理」的标记 ——
    /// 这类污染不会报错，只会让用户某天发现配置莫名变了。
    nonisolated(unsafe) static var suppressPreferenceWrites = false

    private var scanTask: Task<Void, Never>?
    private var isLoaded = false

    // MARK: - 派生数据

    var itemsByID: [UUID: MediaItem] {
        Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var imageCount: Int { items.filter { $0.kind == .image }.count }
    var videoCount: Int { items.filter { $0.kind == .video }.count }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.fileSize } }

    var unknownTimeCount: Int { items.filter { $0.capturedAt == nil }.count }
    var unreliableTimeCount: Int { items.filter { $0.timeSource == .fileSystem }.count }

    var yearHistogram: [(label: String, count: Int)] {
        var buckets: [Int: Int] = [:]
        for item in items {
            guard let date = item.capturedAt else { continue }
            let year = Calendar.current.component(.year, from: date)
            buckets[year, default: 0] += 1
        }
        return buckets.sorted { $0.key < $1.key }
            .map { (String($0.key), $0.value) }
    }

    var deviceHistogram: [(label: String, count: Int)] {
        var buckets: [String: Int] = [:]
        for item in items { buckets[item.cameraLabel, default: 0] += 1 }
        return buckets.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.prefix(8).map { ($0.key, $0.value) }
    }

    var availableDevices: [String] {
        Array(Set(items.map { $0.cameraLabel })).sorted()
    }

    var filteredGroups: [DuplicateGroup] {
        guard let kind = duplicateFilter else { return groups }
        return groups.filter { $0.kind == kind }
    }

    // MARK: - 「所有媒体」页的派生数据

    /// 当前筛选条件下要显示的文件。
    ///
    /// 排序必须**全序且稳定**：拍摄时间相同的照片很多（连拍），只按时间排的话
    /// 顺序由底层数组决定，界面每次重算都可能换位置，网格会自己跳动。
    /// 所以每组比较都以「文件名 → 路径」兜底。
    var visibleMediaItems: [MediaItem] {
        var list = items.filter { $0.kind == .image || $0.kind == .video }
        if let wanted = mediaFilter.kind.mediaKind {
            list = list.filter { $0.kind == wanted }
        }
        let keyword = mediaFilter.keyword.trimmingCharacters(in: .whitespaces).lowercased()
        if !keyword.isEmpty {
            list = list.filter {
                $0.fileName.lowercased().contains(keyword)
                    || $0.parentPath.lowercased().contains(keyword)
                    || $0.cameraLabel.lowercased().contains(keyword)
            }
        }
        let sort = mediaFilter.sort
        list.sort { a, b in
            switch sort {
            case .capturedDesc, .capturedAsc:
                let ad = a.capturedAt, bd = b.capturedAt
                // 时间未知的一律排在最后，不参与「新旧」的语义
                if (ad == nil) != (bd == nil) { return bd == nil }
                if let ad, let bd, ad != bd {
                    return sort == .capturedDesc ? ad > bd : ad < bd
                }
            case .name:
                break
            case .sizeDesc:
                if a.fileSize != b.fileSize { return a.fileSize > b.fileSize }
            }
            if a.fileName != b.fileName { return a.fileName < b.fileName }
            return a.path < b.path
        }
        return list
    }

    /// 勾选中的文件。按 `items` 的顺序返回，也会自动丢掉已经不存在的文件 ——
    /// 执行过一次计划之后选择集里可能留着指向已消失文件的 id。
    var cleanupSelectedItems: [MediaItem] {
        let ids = cleanupSelection
        return items.filter { $0.kind.isVisualMedia && ids.contains($0.id) }
    }

    var cleanupSelectedCount: Int { cleanupSelectedItems.count }
    var cleanupSelectedBytes: Int64 { cleanupSelectedItems.reduce(0) { $0 + $1.fileSize } }
    var cleanupSelectedBytesLabel: String {
        ByteCountFormatter.string(fromByteCount: cleanupSelectedBytes, countStyle: .file)
    }
    var canGenerateCleanupPlan: Bool { !cleanupSelectedItems.isEmpty }

    /// 每个文件在重复组里的角色，供「所有媒体」页标注角标。
    /// 一次算好整份字典再交给视图 —— 让每张卡片各自去遍历 `groups` 会变成 O(卡片数 × 分组数)。
    struct DuplicateRole {
        var kind: DuplicateKind
        var isRedundant: Bool
        var disposition: GroupDisposition
    }

    var duplicateRoleByItemID: [UUID: DuplicateRole] {
        var map: [UUID: DuplicateRole] = [:]
        for group in groups {
            let redundant = group.redundantMemberIDs
            for member in group.memberIDs {
                map[member] = DuplicateRole(kind: group.kind,
                                            isRedundant: redundant.contains(member),
                                            disposition: group.disposition)
            }
        }
        return map
    }

    // MARK: - 来源目录树

    /// 来源目录及其子目录树。
    ///
    /// 从**扫描结果反推**而不是去枚举磁盘：扫描只读是硬约束，
    /// 而且用户关心的正是「扫到了哪些文件在哪个目录」，磁盘上存在但没被扫到的
    /// 空目录出现在这里反而会让人以为里面有东西。
    ///
    /// 中间层级会补齐 —— 某层目录本身没有直接文件（文件都在更深的子目录里）时，
    /// 少了它树就断成两截，层级缩进也会算错。
    var sourceFolderGroups: [SourceFolderGroup] {
        var rootOrder: [String] = []
        var dirsByRoot: [String: Set<String>] = [:]
        var directCount: [String: Int] = [:]
        var directBytes: [String: Int64] = [:]

        for item in items where item.kind.isVisualMedia {
            if dirsByRoot[item.sourceRoot] == nil { rootOrder.append(item.sourceRoot) }
            let parent = PathTools.normalized(item.parentPath)
            dirsByRoot[item.sourceRoot, default: []].insert(parent)
            directCount[parent, default: 0] += 1
            directBytes[parent, default: 0] += item.fileSize
        }

        return rootOrder.sorted().map { rawRoot in
            let root = PathTools.normalized(rawRoot)
            var dirs = Set<String>([root])
            for dir in dirsByRoot[rawRoot] ?? [] where dir != root {
                var current = dir
                while current.count > root.count, current.hasPrefix(root) {
                    dirs.insert(current)
                    let parent = PathTools.normalized((current as NSString).deletingLastPathComponent)
                    if parent == current { break }
                    current = parent
                }
            }
            let sorted = dirs.sorted()

            // 自底向上累计「含子目录」的文件数。字典序下子目录必然排在父目录之后，
            // 所以倒序遍历时每个节点被累加之前，它的子节点都已经算好了。
            var totals: [String: Int] = [:]
            for dir in sorted { totals[dir] = directCount[dir] ?? 0 }
            for dir in sorted.reversed() where dir != root {
                let parent = PathTools.normalized((dir as NSString).deletingLastPathComponent)
                guard totals[parent] != nil else { continue }
                totals[parent, default: 0] += totals[dir] ?? 0
            }

            let folders = sorted.map { dir in
                SourceSubfolder(path: dir,
                                name: (dir as NSString).lastPathComponent,
                                depth: Self.depth(of: dir, under: root),
                                fileCount: directCount[dir] ?? 0,
                                bytes: directBytes[dir] ?? 0,
                                totalFileCount: totals[dir] ?? 0,
                                isExcluded: excludedFromOrganizing.contains(dir),
                                isInherited: dir != root
                                    && excludedFromOrganizing.contains(dir) == false
                                    && hasExcludedAncestor(dir, root: root))
            }
            return SourceFolderGroup(root: root,
                                     name: (root as NSString).lastPathComponent,
                                     folders: folders,
                                     totalFileCount: totals[root] ?? 0,
                                     totalBytes: folders.reduce(Int64(0)) { $0 + $1.bytes })
        }
    }

    private static func depth(of path: String, under root: String) -> Int {
        guard path != root else { return 0 }
        let relative = path.dropFirst(root.count).drop(while: { $0 == "/" })
        return relative.split(separator: "/").count
    }

    /// 自身之外的任一上级（直到来源根）是否被排除
    private func hasExcludedAncestor(_ path: String, root: String) -> Bool {
        var current = PathTools.normalized((path as NSString).deletingLastPathComponent)
        while current.count >= root.count {
            if excludedFromOrganizing.contains(current) { return true }
            if current == root { return false }
            let parent = PathTools.normalized((current as NSString).deletingLastPathComponent)
            if parent == current { return false }
            current = parent
        }
        return false
    }

    /// 某个目录是否因自身或上级被排除而不参与整理
    func isExcludedFromOrganizing(_ path: String) -> Bool {
        let normalized = PathTools.normalized(path)
        if excludedFromOrganizing.contains(normalized) { return true }
        var current = normalized
        while true {
            let parent = PathTools.normalized((current as NSString).deletingLastPathComponent)
            if parent == current { return false }
            if excludedFromOrganizing.contains(parent) { return true }
            current = parent
        }
    }

    /// 勾选 / 取消某个目录的「不参与整理」。
    ///
    /// 取消上级的排除时，下级那些「随上级」的目录会自动恢复参与 ——
    /// 因为它们从来没有被单独勾选过，状态只在上级那一处存着。
    func toggleOrganizingExclusion(_ path: String) {
        let normalized = PathTools.normalized(path)
        if excludedFromOrganizing.contains(normalized) {
            excludedFromOrganizing.remove(normalized)
        } else {
            // 勾选一个目录时顺手清掉它下面那些已被单独标记的项：
            // 留着它们不会改变结果（上级已经排除了），但界面上会出现
            // 「上级没勾、下级勾着」的矛盾观感，取消上级时又会冒出一堆意外生效的排除。
            let prefix = normalized.hasSuffix("/") ? normalized : normalized + "/"
            excludedFromOrganizing = excludedFromOrganizing.filter { !$0.hasPrefix(prefix) }
            excludedFromOrganizing.insert(normalized)
        }
        persistPreferences()
    }

    var selectedOperationCount: Int {
        operations.filter { $0.selected && $0.kind.isMutating }.count
    }

    var hasExecutableWork: Bool { selectedOperationCount > 0 }
    var hasPlan: Bool { !operations.isEmpty }

    /// 计划里会被真正改动的文件数量上限，用于确认对话框
    var destructiveCount: Int {
        operations.filter { $0.selected && $0.kind == .trash }.count
    }

    // MARK: - 生命周期

    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        cache.load()
        sessions = JournalStore.loadSessions()
        loadPreferences()
    }

    private enum PrefKey {
        static let settings = "scanSettings"
        static let rule = "organizeRule"
        static let filter = "planFilter"
        static let excludedFolders = "excludedFromOrganizing"
    }

    private func loadPreferences() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = UserDefaults.standard.data(forKey: PrefKey.settings),
           let value = try? decoder.decode(ScanSettings.self, from: data) {
            settings = value
        }
        if let data = UserDefaults.standard.data(forKey: PrefKey.rule),
           let value = try? decoder.decode(OrganizeRule.self, from: data) {
            rule = value
        }
        if let data = UserDefaults.standard.data(forKey: PrefKey.filter),
           let value = try? decoder.decode(PlanFilter.self, from: data) {
            filter = value
        }
        // 「不参与整理」是用户对某个照片库的一次性判断，属于偏好而不是扫描结果，
        // 所以跟偏好一起持久化：重启、重新扫描之后依然生效。
        if let paths = UserDefaults.standard.array(forKey: PrefKey.excludedFolders) as? [String] {
            excludedFromOrganizing = Set(paths.map { PathTools.normalized($0) })
        }
    }

    func persistPreferences() {
        // 自检会驱动真实的 `AppState`，而不少动作（改设置、勾选排除目录…）都会顺手持久化。
        // 让它们写进用户的偏好，跑一次自检就等于悄悄改掉了用户自己的配置 ——
        // 与 `JournalStore.overrideDirectory` 是同一个道理。
        guard !Self.suppressPreferenceWrites else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(settings) {
            UserDefaults.standard.set(data, forKey: PrefKey.settings)
        }
        if let data = try? encoder.encode(rule) {
            UserDefaults.standard.set(data, forKey: PrefKey.rule)
        }
        if let data = try? encoder.encode(filter) {
            UserDefaults.standard.set(data, forKey: PrefKey.filter)
        }
        UserDefaults.standard.set(Array(excludedFromOrganizing), forKey: PrefKey.excludedFolders)
    }

    // MARK: - 源目录

    func addSourceFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "选择要扫描的照片 / 视频目录"
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            if !settings.sourceFolders.contains(path) {
                settings.sourceFolders.append(path)
            }
        }
        persistPreferences()
    }

    func removeSourceFolder(_ path: String) {
        settings.sourceFolders.removeAll { $0 == path }
        persistPreferences()
    }

    func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "选择整理后的输出目录"
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.urls.first {
            rule.destinationRoot = url.standardizedFileURL.path
            persistPreferences()
        }
    }

    // MARK: - 扫描

    func startScan() {
        guard !settings.sourceFolders.isEmpty else {
            notice = AppNotice(level: .warning, title: "还没有选择目录",
                               message: "请先添加至少要扫描的文件夹。")
            return
        }
        persistPreferences()
        scanTask?.cancel()
        operations = []
        planSummary = PlanSummary()
        planWarnings = []
        folderCounts = [:]
        cleanupSelection.removeAll()

        scanTask = Task { [weak self] in
            await self?.performScan()
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    // 供界面自检直接驱动，跳过 UserDefaults 与确认弹窗
    func performScan() async {
        let started = Date()
        cachedHitCount = 0
        progress = ScanProgress(phase: .enumerating, total: 0, processed: 0, startedAt: started)

        let outcome = await MediaIndexer.index(
            settings: settings,
            cache: cache,
            onProgress: { [weak self] update in
                self?.progress = update
            })

        if outcome.wasCancelled {
            progress.phase = .cancelled
            notice = AppNotice(level: .warning, title: "扫描已取消",
                              message: "已完成的部分已经保留，可以继续操作或重新扫描。")
        }

        items = outcome.items
        failures = outcome.failures
        cachedHitCount = outcome.cachedHits
        lastScanElapsed = outcome.elapsed
        scannedOnce = true
        // 换了一批文件，旧的勾选 id 全部失效 —— 留着只会让「已勾选 N 个」
        // 与网格里能看到的勾选数对不上。
        cleanupSelection.removeAll()

        await recomputeDuplicates()

        if !outcome.wasCancelled {
            notice = AppNotice(level: .success, title: "扫描完成",
                               message: "共处理 \(outcome.items.count) 个文件，发现 "
                                   + "\(dedupSummary.totalGroupCount) 组重复 / 相似，"
                                   + "可释放 \(dedupSummary.reclaimableLabel)。")
        }
    }

    func recomputeDuplicates() async {
        guard !items.isEmpty else {
            groups = []              // 属性观察器会把摘要一并清空
            return
        }
        isDedupRunning = true
        progress.phase = .analyzing
        let dedup = await DuplicateDetector.detect(items: items,
                                                  settings: settings,
                                                  onStatus: { _ in })
        items = dedup.items
        // 摘要不在这里赋值：它由 `groups` 的观察器重算，
        // 检测阶段与界面改选共用 `DedupSummary.compute` 这一个算法，
        // 分别赋值等于承认两者可能算出不同结果。
        groups = dedup.groups
        isDedupRunning = false
        if progress.phase == .analyzing {
            progress.phase = .finished
        }
    }

    /// 阈值变化后重算相似度。已有精确重复结果不变，只需要重新聚簇。
    func scheduleThresholdRecompute() {
        Task { [weak self] in
            await self?.recomputeDuplicates()
        }
    }

    // MARK: - 重复项决策

    /// 切换某个成员的「保留」勾选。**支持多选** —— 同组里想留几张就留几张。
    ///
    /// 不允许取消最后一个勾选：那样整组都会被当成冗余副本，清理计划会把原件也移进回收站。
    /// 模型层 `effectiveKeepIDs` 还有一道兜底，这里只是不让用户走进那个状态。
    ///
    /// 「整组都不保留」不经过这里 —— 它是用户显式选择的整组决定（`discardAll`），
    /// 与「勾选被清空」这种误操作状态区分开。
    func toggleKeep(groupID: UUID, memberID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }),
              groups[index].memberIDs.contains(memberID) else { return }
        var group = groups[index]
        // 整组决定生效时逐张勾选没有意义，先回到「按勾选」再切换
        group.disposition = .bySelection
        if group.keepIDs.contains(memberID) {
            guard group.keepIDs.count > 1 else { return }   // 至少保留一个
            group.keepIDs.remove(memberID)
        } else {
            group.keepIDs.insert(memberID)
        }
        group.keepReason = .manual
        groups[index] = group
    }

    /// 该成员是否是本组最后一个保留项 —— 是的话界面上要禁用取消勾选
    func isLastKeep(_ itemID: UUID, in group: DuplicateGroup) -> Bool {
        group.keepIDs.contains(itemID) && group.keepIDs.count <= 1
    }

    func isKeep(_ itemID: UUID, in group: DuplicateGroup) -> Bool {
        group.keepIDs.contains(itemID)
    }

    /// 设置整组决定。同一个值再点一次表示取消，回到「按勾选」——
    /// 这样「保留整组 / 都不保留」两个按钮各自都能再次点击撤销。
    ///
    /// 两种整组决定都只影响清理，不影响归档：除非被清掉，
    /// 文件仍会按整理规则被移动到目标目录。
    func toggleDisposition(groupID: UUID, disposition: GroupDisposition) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].disposition = groups[index].disposition == disposition
            ? .bySelection
            : disposition
    }

    /// 分组上的人工决定改完之后必须重算摘要，
    /// 否则「冗余 N 个 / 可释放 X」会和实际生成的计划对不上。
    ///
    /// 正常情况下由 `groups` 的属性观察器自动调用；这里保留这个方法
    /// 是给「只改了 items（文件体积）而分组没变」的场景兜底。
    func refreshDedupSummary() {
        let sizes = Dictionary(items.map { ($0.id, $0.fileSize) },
                               uniquingKeysWith: { first, _ in first })
        dedupSummary = DedupSummary.compute(groups: groups, sizes: sizes)
    }

    /// 清除所有人工决定（改选的保留项 + 整组决定），恢复成程序推荐
    func resetKeepRecommendations() {
        // 先整份算好再一次性写回：`groups` 的属性观察器会在赋值时重算摘要，
        // 逐个下标改会让摘要被重算 O(组数) 次，分组多时纯属浪费。
        var updated = groups
        for index in updated.indices {
            let members = updated[index].memberIDs
            let absolute = items.indices.filter { members.contains(items[$0].id) }
            guard absolute.count > 1 else { continue }
            let treatAsIdentical = updated[index].kind == .exact
            let decision = DuplicateDetector.recommendKeep(indices: Array(absolute),
                                                          items: items,
                                                          treatAsIdentical: treatAsIdentical)
            updated[index].disposition = .bySelection
            updated[index].keepIDs = [items[decision.index].id]
            updated[index].keepReason = decision.reason
            if let memberIndex = members.firstIndex(of: items[decision.index].id), memberIndex != 0 {
                var copy = updated[index]
                copy.memberIDs.remove(at: memberIndex)
                copy.memberIDs.insert(items[decision.index].id, at: 0)
                updated[index] = copy
            }
        }
        groups = updated
    }

    // MARK: - 生成计划

    /// 跳过重复项，只按整理规则归档。
    ///
    /// 对应「重复副本我暂时不想动，先把目录结构整理好」这种用法。
    /// 与重复项页的主按钮正好相反：主按钮走纯清理模式（只清副本、不归档），
    /// 这里则把「清理重复副本」关掉、「按规则归档」打开 —— 两条路都显式写出来，
    /// 让用户在重复项页就能选择「处理重复」还是「先不管重复」。
    func generateArchiveOnlyPlan() {
        filter.cleanRedundantDuplicates = false
        filter.onlyRedundantDuplicates = false
        filter.archiveFiles = true
        generatePlan(skippingDuplicates: true)
    }

    func generatePlan(skippingDuplicates: Bool = false) {
        guard filter.doesAnyWork else {
            notice = AppNotice(level: .warning, title: "没有勾选任何要做的操作",
                               message: "请在「整理规则」页至少打开「按规则归档」或「清理重复副本」。")
            return
        }
        guard !items.isEmpty else {
            notice = AppNotice(level: .warning, title: "还没有扫描结果",
                               message: "请先在「扫描」页完成一次扫描。")
            return
        }
        if rule.transferMode == .move, !rule.isInPlace, rule.destinationRoot.isEmpty {
            notice = AppNotice(level: .warning, title: "需要指定输出目录",
                               message: "选择了「输出到新目录」，但目标目录还是空的。")
            return
        }
        persistPreferences()

        let built = PlanBuilder.build(items: items,
                                     groups: groups,
                                     rule: rule,
                                     filter: filter,
                                     excludedFromOrganizing: excludedFromOrganizing)
        operations = built.operations
        planSummary = built.summary
        planWarnings = built.warnings
        folderCounts = built.folderCounts

        if built.operations.isEmpty {
            notice = AppNotice(level: .info, title: "没有需要处理的内容",
                               message: "当前规则下所有文件都已就位。")
        } else {
            let suffix = skippingDuplicates
                ? "，本次不处理重复副本（\(dedupSummary.totalGroupCount) 组重复项保持原样）"
                : ""
            notice = AppNotice(level: .success, title: "计划已生成",
                               message: "共 \(built.operations.count) 行，"
                                   + "其中待执行 \(built.summary.totalSelected) 项" + suffix + "。")
            page = .plan
        }
    }

    // MARK: - 「所有媒体」页：手动勾选清理

    func toggleCleanupSelection(_ itemID: UUID) {
        if cleanupSelection.contains(itemID) {
            cleanupSelection.remove(itemID)
        } else {
            cleanupSelection.insert(itemID)
        }
    }

    func isCleanupSelected(_ itemID: UUID) -> Bool { cleanupSelection.contains(itemID) }

    /// 把一批文件整体设为勾选 / 取消勾选。用于「全选当前结果」「取消当前结果」。
    func setCleanupSelection(_ selected: Bool, itemIDs: [UUID]) {
        if selected {
            cleanupSelection.formUnion(itemIDs)
        } else {
            cleanupSelection.subtract(itemIDs)
        }
    }

    func clearCleanupSelection() {
        cleanupSelection.removeAll()
    }

    /// 为「所有媒体」页勾选的文件生成清理计划。
    ///
    /// 范围完全由用户点名：不读 `PlanFilter`，也不含任何归档操作 ——
    /// 所以「整理规则」页的模板怎么改都不会影响这里的结果，
    /// 用户看到的勾选就是计划里会出现的行。
    func generateCleanupPlan() {
        let selected = cleanupSelectedItems
        guard !selected.isEmpty else {
            notice = AppNotice(level: .warning, title: "还没有勾选任何文件",
                               message: items.isEmpty
                                   ? "请先在「扫描」页完成一次扫描。"
                                   : "点击缩略图右上角的圆圈，勾选要清理的文件。")
            return
        }

        let built = PlanBuilder.buildTrashOnly(items: items,
                                               selectedIDs: Set(selected.map { $0.id }),
                                               groups: groups)
        operations = built.operations
        planSummary = built.summary
        planWarnings = built.warnings
        folderCounts = built.folderCounts

        if built.operations.isEmpty {
            notice = AppNotice(level: .info, title: "没有需要处理的内容",
                               message: "勾选的文件都不在可清理的媒体类型里。")
        } else {
            // 手动清理绕开了重复项的推荐逻辑，勾中整组或勾中保留项都是可能的。
            // 有风险提示时用 warning 而不是 success —— 页头的提示条是最先被看到的地方。
            let level: AppNotice.Level = built.warnings.count > 1 ? .warning : .success
            notice = AppNotice(level: level, title: "清理计划已生成",
                               message: "共 \(built.operations.count) 个文件待移入回收站，"
                                   + "预计释放 \(built.summary.reclaimableLabel)。"
                                   + (built.warnings.count > 1 ? "已列出 \(built.warnings.count - 1) 条风险提示。" : ""))
            page = .plan
        }
    }

    func selectAllOperations(_ selected: Bool) {
        for index in operations.indices where operations[index].kind.isMutating {
            operations[index].selected = selected
        }
        planSummary = PlanSummary.compute(from: operations)
    }

    func selectOperations(kind: OperationKind, selected: Bool) {
        for index in operations.indices where operations[index].kind == kind {
            operations[index].selected = selected
        }
        planSummary = PlanSummary.compute(from: operations)
    }

    func setSelection(operationID: UUID, selected: Bool) {
        guard let index = operations.firstIndex(where: { $0.id == operationID }) else { return }
        guard operations[index].kind.isMutating else { return }
        operations[index].selected = selected
        planSummary = PlanSummary.compute(from: operations)
    }

    // MARK: - 执行

    func executePlan() async {
        let selected = operations.filter { $0.selected && $0.kind.isMutating }
        guard !selected.isEmpty else { return }

        executionProgress = ExecutionProgress(total: selected.count)
        let report = await PlanExecutor.execute(operations: operations) { [weak self] update in
            self?.executionProgress = update
        }
        executionProgress = nil
        lastExecution = report
        sessions = JournalStore.loadSessions()

        // 已经不在原位的文件从扫描结果里摘掉，避免界面继续显示失效路径
        applyExecutionToItems(report)

        let level: AppNotice.Level = report.failed == 0 ? .success : .warning
        notice = AppNotice(level: level, title: "执行完成", message: report.summaryLine)

        // 计划已经落地，重新生成一份以反映现状
        let rebuilt = PlanBuilder.build(items: items, groups: groups, rule: rule, filter: filter,
                                        excludedFromOrganizing: excludedFromOrganizing)
        operations = rebuilt.operations
        planSummary = rebuilt.summary
        planWarnings = rebuilt.warnings
        folderCounts = rebuilt.folderCounts
    }

    private func applyExecutionToItems(_ report: ExecutionReport) {
        var moved: [String: String] = [:]
        var trashed = Set<String>()
        for entry in report.session.entries where entry.result == .success {
            switch entry.kind {
            case .trash:
                trashed.insert(entry.sourcePath)
            case .move, .rename:
                if let destination = entry.destinationPath { moved[entry.sourcePath] = destination }
            case .copy, .alreadyPlaced, .skipped:
                break
            }
        }

        var updated: [MediaItem] = []
        updated.reserveCapacity(items.count)
        for var item in items {
            if trashed.contains(item.path) { continue }
            if let destination = moved[item.path] {
                let url = URL(fileURLWithPath: destination)
                item.path = destination
                item.fileName = url.lastPathComponent
                item.parentPath = url.deletingLastPathComponent().path
            }
            updated.append(item)
        }
        items = updated

        // 引用了已消失文件的分组要一并剔除
        let liveIDs = Set(updated.map { $0.id })
        // 勾选集合同样只保留还存在的文件，否则「已勾选 N 个」会包含看不见的行
        cleanupSelection = cleanupSelection.intersection(liveIDs)
        groups = groups.compactMap { group in
            var copy = group
            copy.memberIDs = copy.memberIDs.filter { liveIDs.contains($0) }
            // 已消失的文件可能正好在保留集合里，剔除后若空了就回落成首个成员
            // （模型层的 effectiveKeepIDs 也会兜底，这里显式修一下让状态本身干净）
            copy.keepIDs = copy.keepIDs.filter { liveIDs.contains($0) }
            if copy.keepIDs.isEmpty, let first = copy.memberIDs.first {
                copy.keepIDs = [first]
            }
            guard copy.memberIDs.count > 1 else { return nil }
            return copy
        }
    }

    func undo(_ session: JournalSession) async {
        let report = await PlanExecutor.undo(session: session)
        sessions = JournalStore.loadSessions()
        lastExecution = nil
        // 文件回到了原处，扫描结果里的路径全部失效，必须重新扫描才能继续操作
        items = []
        groups = []            // 摘要随分组一并归零，见 `groups` 的观察器
        operations = []
        planSummary = PlanSummary()
        planWarnings = []
        folderCounts = [:]
        cleanupSelection.removeAll()
        scannedOnce = false
        let level: AppNotice.Level = report.failed == 0 ? .success : .warning
        notice = AppNotice(level: level, title: "撤销完成",
                           message: "\(report.summaryLine)。文件已回到原位置，请重新扫描以继续。")
    }

    // MARK: - 导出

    func exportPlan(format: PlanExportFormat) {
        guard !operations.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "影像整理计划-\(DateFormat.fileStamp(Date())).\(format.fileExtension)"
        panel.message = "导出本次生成的整理计划"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let content = PlanExporter.serialize(operations: operations,
                                            summary: planSummary,
                                            warnings: planWarnings,
                                            format: format)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            notice = AppNotice(level: .success, title: "已导出",
                               message: url.lastPathComponent)
        } catch {
            notice = AppNotice(level: .failure, title: "导出失败",
                               message: error.localizedDescription)
        }
    }

    // MARK: - 维护

    func clearFingerprintCache() {
        cache.clear()
        cachedHitCount = 0
        notice = AppNotice(level: .info, title: "指纹缓存已清空",
                           message: "下次扫描会重新计算全部文件的指纹。")
    }

    var cacheEntryCount: Int { cache.count }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openInDefaultApp(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - 应用启动时的偏好清理

    func handleCacheClearNotification() {
        clearFingerprintCache()
    }
}

// MARK: - 计划导出

enum PlanExportFormat: String, CaseIterable, Identifiable {
    case csv
    case json

    var id: String { rawValue }

    var displayName: String { self == .csv ? "CSV 表格" : "JSON" }

    var fileExtension: String { rawValue }
}

enum PlanExporter {

    static func serialize(operations: [PlanOperation],
                          summary: PlanSummary,
                          warnings: [String],
                          format: PlanExportFormat) -> String {
        switch format {
        case .csv:
            return csv(operations: operations)
        case .json:
            return json(operations: operations, summary: summary, warnings: warnings)
        }
    }

    private static func csv(operations: [PlanOperation]) -> String {
        var lines = ["执行,类型,文件名,源路径,目标路径,原因,体积"]
        for op in operations {
            let fields = [
                op.selected ? "是" : "否",
                op.kind.displayName,
                op.fileName,
                op.sourcePath,
                op.destinationPath ?? "",
                op.reason,
                String(op.fileSize)
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        // 加 BOM，Excel 打开中文 CSV 才不会乱码
        return "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
    }

    private static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private static func json(operations: [PlanOperation],
                             summary: PlanSummary,
                             warnings: [String]) -> String {
        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "summary": [
                "move": summary.moveCount,
                "rename": summary.renameCount,
                "copy": summary.copyCount,
                "trash": summary.trashCount,
                "alreadyPlaced": summary.alreadyPlacedCount,
                "skipped": summary.skippedCount,
                "moveBytes": summary.moveBytes,
                "reclaimableBytes": summary.reclaimableBytes
            ],
            "warnings": warnings,
            "operations": operations.map { op -> [String: Any] in
                var entry: [String: Any] = [
                    "kind": op.kind.rawValue,
                    "selected": op.selected,
                    "source": op.sourcePath,
                    "reason": op.reason,
                    "fileSize": op.fileSize
                ]
                if let destination = op.destinationPath { entry["destination"] = destination }
                return entry
            }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                    options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
