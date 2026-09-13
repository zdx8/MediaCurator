import Foundation
import SwiftUI
import AppKit

// MARK: - 页面

enum AppPage: String, CaseIterable, Identifiable {
    case scan
    case duplicates
    case organize
    case plan
    case journal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: return "扫描"
        case .duplicates: return "重复项"
        case .organize: return "整理规则"
        case .plan: return "执行计划"
        case .journal: return "操作日志"
        }
    }

    var subtitle: String {
        switch self {
        case .scan: return "选择目录、读取拍摄信息"
        case .duplicates: return "审阅并决定保留哪一份"
        case .organize: return "目录结构与命名规则"
        case .plan: return "确认每一项改动"
        case .journal: return "执行记录与撤销"
        }
    }

    var symbolName: String {
        switch self {
        case .scan: return "magnifyingglass.circle"
        case .duplicates: return "square.on.square.dashed"
        case .organize: return "folder.badge.gearshape"
        case .plan: return "list.bullet.rectangle"
        case .journal: return "clock.arrow.circlepath"
        }
    }

    var step: Int {
        switch self {
        case .scan: return 1
        case .duplicates: return 2
        case .organize: return 3
        case .plan: return 4
        case .journal: return 5
        }
    }
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
    @Published var groups: [DuplicateGroup] = []
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

    let cache = FingerprintCache()

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
    }

    func persistPreferences() {
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
            groups = []
            dedupSummary = DedupSummary()
            return
        }
        isDedupRunning = true
        progress.phase = .analyzing
        let dedup = await DuplicateDetector.detect(items: items,
                                                  settings: settings,
                                                  onStatus: { _ in })
        items = dedup.items
        groups = dedup.groups
        dedupSummary = dedup.summary
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
    func toggleKeep(groupID: UUID, memberID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }),
              groups[index].memberIDs.contains(memberID) else { return }
        var group = groups[index]
        if group.keepIDs.contains(memberID) {
            guard group.keepIDs.count > 1 else { return }   // 至少保留一个
            group.keepIDs.remove(memberID)
        } else {
            group.keepIDs.insert(memberID)
        }
        group.keepReason = .manual
        groups[index] = group
        refreshDedupSummary()
    }

    /// 该成员是否是本组最后一个保留项 —— 是的话界面上要禁用取消勾选
    func isLastKeep(_ itemID: UUID, in group: DuplicateGroup) -> Bool {
        group.keepIDs.contains(itemID) && group.keepIDs.count <= 1
    }

    func isKeep(_ itemID: UUID, in group: DuplicateGroup) -> Bool {
        group.keepIDs.contains(itemID)
    }

    /// 整组保留：本组不做任何清理，组内成员全部留下。
    /// 只影响清理，不影响归档 —— 文件仍会按整理规则被移动到目标目录。
    func setKeepWholeGroup(groupID: UUID, value: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].keepWholeGroup = value
        refreshDedupSummary()
    }

    /// 分组上的人工决定改完之后必须重算摘要，
    /// 否则「冗余 N 个 / 可释放 X」会和实际生成的计划对不上。
    func refreshDedupSummary() {
        let sizes = Dictionary(items.map { ($0.id, $0.fileSize) },
                               uniquingKeysWith: { first, _ in first })
        dedupSummary = DedupSummary.compute(groups: groups, sizes: sizes)
    }

    /// 清除所有人工决定（改选的保留项 + 整组保留），恢复成程序推荐
    func resetKeepRecommendations() {
        for index in groups.indices {
            let members = groups[index].memberIDs
            let absolute = items.indices.filter { members.contains(items[$0].id) }
            guard absolute.count > 1 else { continue }
            let treatAsIdentical = groups[index].kind == .exact
            let decision = DuplicateDetector.recommendKeep(indices: Array(absolute),
                                                          items: items,
                                                          treatAsIdentical: treatAsIdentical)
            groups[index].keepWholeGroup = false
            groups[index].keepIDs = [items[decision.index].id]
            groups[index].keepReason = decision.reason
            if let memberIndex = members.firstIndex(of: items[decision.index].id), memberIndex != 0 {
                var copy = groups[index]
                copy.memberIDs.remove(at: memberIndex)
                copy.memberIDs.insert(items[decision.index].id, at: 0)
                groups[index] = copy
            }
        }
        refreshDedupSummary()
    }

    // MARK: - 生成计划

    func generatePlan() {
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
                                     filter: filter)
        operations = built.operations
        planSummary = built.summary
        planWarnings = built.warnings
        folderCounts = built.folderCounts

        if built.operations.isEmpty {
            notice = AppNotice(level: .info, title: "没有需要处理的内容",
                               message: "当前规则下所有文件都已就位。")
        } else {
            notice = AppNotice(level: .success, title: "计划已生成",
                               message: "共 \(built.operations.count) 行，"
                                   + "其中待执行 \(built.summary.totalSelected) 项。")
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
        let rebuilt = PlanBuilder.build(items: items, groups: groups, rule: rule, filter: filter)
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
        groups = []
        dedupSummary = DedupSummary()
        operations = []
        planSummary = PlanSummary()
        planWarnings = []
        folderCounts = [:]
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
