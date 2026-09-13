import Foundation

struct PlanBuildResult {
    var operations: [PlanOperation] = []
    var summary: PlanSummary = PlanSummary()
    var warnings: [String] = []
    /// 目标目录 → 落入文件数，用于结构预览
    var folderCounts: [String: Int] = [:]
    var consideredCount: Int = 0
    var filteredOutCount: Int = 0
    /// 因所在目录被勾选「不参与整理」而没有进入归档的文件数。
    /// 与 `filteredOutCount` 分开计：那个是「不符合条件」，这个是「用户点名不要动」，
    /// 界面上要能分别说清楚，否则用户只看到总数对不上却找不到原因。
    var excludedCount: Int = 0

    var hasMutatingWork: Bool {
        operations.contains { $0.selected && $0.kind.isMutating }
    }
}

/// 把「一堆媒体文件」翻译成「一串具体要做的文件操作」。
///
/// 这个阶段**完全不碰文件系统**（除了 `fileExists` 这类只读探测），
/// 所有结果都以计划项的形式呈现给用户确认，执行由 `PlanExecutor` 负责。
enum PlanBuilder {

    private struct Prepared {
        var item: MediaItem
        /// 不含 {seq} 影响的目录，用于分组的稳定键
        var stableDir: String
        var folderComponents: [String]
        var sequence: Int = 0
        var redundantGroup: DuplicateGroup?
    }

    static func build(items: [MediaItem],
                      groups: [DuplicateGroup],
                      rule: OrganizeRule,
                      filter: PlanFilter,
                      excludedFromOrganizing: Set<String> = []) -> PlanBuildResult {
        var result = PlanBuildResult()
        guard filter.doesAnyWork, !items.isEmpty else { return result }

        // 标准化一次，后面每个文件都要比 —— 逐次去调用 `standardizedFileURL`
        // 在几万个文件上是明显的浪费。
        let excludedFolders = excludedFromOrganizing.map { PathTools.normalized($0) }

        // 冗余副本索引。哪些成员算冗余只有一个来源：`DuplicateGroup.redundantMemberIDs`。
        // 「整组保留」的组它返回空集（这几张只是长得像，用户已确认每张都要留），
        // 「都不保留」的组返回全部成员（用户显式要求一份都不留）。
        // 这里不再自己拼条件判断整组决定 —— 界面显示的份数与计划实际清掉的份数
        // 必须由同一个表达式算出来。
        var redundant: [UUID: DuplicateGroup] = [:]
        var keepNameByGroup: [UUID: String] = [:]
        let nameByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.fileName) })
        for group in groups {
            let redundantIDs = group.redundantMemberIDs
            guard !redundantIDs.isEmpty else { continue }
            // 保留项可以多选，理由文案里只列第一个并标出总数，避免把一长串文件名塞进一行
            let keptNames = group.memberIDs
                .filter { !redundantIDs.contains($0) }
                .compactMap { nameByID[$0] }
            if let first = keptNames.first {
                keepNameByGroup[group.id] = keptNames.count > 1
                    ? "\(first) 等 \(keptNames.count) 份"
                    : first
            }
            for member in redundantIDs {
                redundant[member] = group
            }
        }

        // ---------- 第一遍：筛选 + 计算目标目录 ----------
        var prepared: [Prepared] = []
        for item in items {
            guard item.kind == .image || item.kind == .video else { continue }
            if item.kind == .image && !filter.includeImages { result.filteredOutCount += 1; continue }
            if item.kind == .video && !filter.includeVideos { result.filteredOutCount += 1; continue }
            if filter.minimumPixelCount > 0, item.kind == .image,
               item.pixelCount < filter.minimumPixelCount {
                result.filteredOutCount += 1; continue
            }
            if let from = rule.dateFrom {
                guard let date = item.capturedAt, date >= from else { result.filteredOutCount += 1; continue }
            }
            if let to = rule.dateTo {
                guard let date = item.capturedAt, date <= to else { result.filteredOutCount += 1; continue }
            }
            if rule.minimumTimeSourceConfidence > 0,
               item.timeSource.confidence < rule.minimumTimeSourceConfidence {
                result.filteredOutCount += 1; continue
            }
            if !rule.deviceFilter.isEmpty {
                guard rule.deviceFilter.contains(item.cameraLabel) else { result.filteredOutCount += 1; continue }
            }

            let group = redundant[item.id]
            if filter.onlyRedundantDuplicates && group == nil {
                result.filteredOutCount += 1; continue
            }

            // 「不参与整理」只作用于**归档**。这个文件若同时被判为冗余副本、
            // 且本次开启了清理，它仍旧会进清理列表 —— 清理针对的是「同一批素材里的多余副本」，
            // 和「这个目录要不要按模板重排」是两件事。
            let isExcluded = !excludedFolders.isEmpty
                && isUnder(PathTools.normalized(item.parentPath), anyOf: excludedFolders)
            if isExcluded {
                result.excludedCount += 1
                if group == nil || !filter.cleanRedundantDuplicates { continue }
            }

            let components: [String]
            if item.capturedAt != nil {
                let vars = TemplateRenderer.variables(for: item,
                                                      sequence: 0,
                                                      padding: rule.sequencePadding,
                                                      unknownDatePlaceholder: "未识别")
                components = TemplateRenderer.renderFolderPath(rule.folderTemplate, variables: vars)
            } else {
                // 时间未知就不套模板了 —— 否则会渲染出「未识别/未识别/未识别」这种层级
                components = [PathTools.sanitizeComponent(rule.unknownDateFolder)]
            }

            let base = rule.isInPlace ? item.sourceRoot : rule.destinationRoot
            let stableDir = ([base] + components).joined(separator: "/")

            prepared.append(Prepared(item: item,
                                     stableDir: stableDir,
                                     folderComponents: components,
                                     redundantGroup: group))
        }

        result.consideredCount = prepared.count
        guard !prepared.isEmpty else { return result }

        // ---------- 第二遍：按目标目录分配 {seq} 编号 ----------
        assignSequences(&prepared, rule: rule)

        // ---------- 第三遍：确定最终文件名并解决冲突 ----------
        var reserved = Set<String>()
        var operations: [PlanOperation] = []

        // 本批次要处理的文件**当前所在**的路径集合。
        //
        // 用来挡住一种会搬错文件的情况：覆盖策略下，如果某条操作的目标位置正是
        // 本批次另一个文件现在的路径（典型是甲乙互换文件名这类环），执行器会先把这个
        // 「同名文件」移进回收站 —— 可它其实是后面那条操作要搬走的源文件。
        // 于是后一条执行时路径还在、内容已经换成了前一条放进去的那份：
        // 结果是其中一个文件被静默送进回收站、交换根本没发生。
        // 这种情形下退回「加序号」——两份都保住，只是名字不再互换。
        //
        // 同时记一份**文件同一性**：字符串可能因为符号链接而拼法不同（见 `pointsToSameFile`）。
        let claimedSourcePaths = Set(prepared.map { $0.item.path })
        let claimedSourceIdentities = Set(prepared.compactMap { fileIdentity(of: $0.item.path) })
        func isClaimedByBatch(_ path: String) -> Bool {
            if claimedSourcePaths.contains(path) { return true }
            guard let identity = fileIdentity(of: path) else { return false }
            return claimedSourceIdentities.contains(identity)
        }

        for entry in prepared {
            let item = entry.item
            let group = entry.redundantGroup

            // 冗余副本 + 开启清理 → 直接移入回收站，不再归档
            if let group, filter.cleanRedundantDuplicates {
                // 「都不保留」的组没有保留项，理由必须显式说明是整组决定，
                // 否则会退化成「同组保留『组内保留项』」这种读不通的文案
                let reason = group.disposition == .discardAll
                    ? "\(group.kind.displayName) · 已设为整组都不保留"
                    : "\(group.kind.displayName)冗余副本 · 同组保留「\(keepNameByGroup[group.id] ?? "组内保留项")」"
                operations.append(PlanOperation(
                    kind: .trash,
                    itemID: item.id,
                    sourcePath: item.path,
                    destinationPath: nil,
                    reason: reason,
                    groupID: group.id,
                    fileSize: item.fileSize,
                    kindOfMedia: item.kind,
                    fileName: item.fileName))
                continue
            }

            if !filter.archiveFiles { continue }

            // 重新渲染目录（模板里可能含 {seq}）
            let vars = TemplateRenderer.variables(for: item,
                                                  sequence: entry.sequence,
                                                  padding: rule.sequencePadding,
                                                  unknownDatePlaceholder: item.capturedAt == nil
                                                      ? rule.unknownDateFolder : "未识别")
            let components = item.capturedAt == nil
                ? [PathTools.sanitizeComponent(rule.unknownDateFolder)]
                : TemplateRenderer.renderFolderPath(rule.folderTemplate, variables: vars)
            let base = rule.isInPlace ? item.sourceRoot : rule.destinationRoot
            let targetDir = ([base] + components).joined(separator: "/")

            let ext = item.url.pathExtension
            let stem: String
            if rule.renameTemplate.trimmingCharacters(in: .whitespaces).isEmpty {
                stem = item.url.deletingPathExtension().lastPathComponent
            } else {
                stem = TemplateRenderer.renderFileName(rule.renameTemplate, variables: vars)
            }
            let fileName = ext.isEmpty ? stem : "\(stem).\(ext)"
            var desired = targetDir + "/" + fileName

            // ---------- 判断结果 ----------
            // 用**文件同一性**而不是字符串比较，见 `pointsToSameFile` 的说明。
            if pointsToSameFile(desired, item.path) {
                // 已经在它该在的位置：不产生任何操作
                operations.append(PlanOperation(
                    kind: .alreadyPlaced,
                    itemID: item.id,
                    sourcePath: item.path,
                    destinationPath: item.path,
                    reason: "已在目标位置，无需处理",
                    fileSize: item.fileSize,
                    kindOfMedia: item.kind,
                    fileName: item.fileName,
                    selected: false))
                reserved.insert(desired)
                continue
            }

            // 目标被占用：既可能是磁盘上已存在，也可能是本次计划里前面的文件已经占位
            let onDisk = FileManager.default.fileExists(atPath: desired)
            let inBatch = reserved.contains(desired)
            let taken = onDisk || inBatch

            var finalPath = desired
            var reasonSuffix = ""
            var overwrites = false

            if taken {
                switch rule.conflictPolicy {
                case .autoNumber:
                    finalPath = numberedAlternative(desired, reserved: reserved)
                    reasonSuffix = onDisk ? "（目标已存在，自动加序号）" : "（与本次计划内其他文件重名，自动加序号）"
                case .skip:
                    operations.append(PlanOperation(
                        kind: .skipped,
                        itemID: item.id,
                        sourcePath: item.path,
                        destinationPath: desired,
                        reason: "目标已存在，按策略跳过",
                        fileSize: item.fileSize,
                        kindOfMedia: item.kind,
                        fileName: item.fileName,
                        selected: false))
                    reserved.insert(desired)
                    continue
                case .overwrite:
                    if onDisk && !inBatch && !isClaimedByBatch(desired) {
                        // 覆盖磁盘上已存在的同名文件。执行时先把原文件移入回收站再落位，
                        // 所以文案不能写成「不可恢复」。
                        overwrites = true
                        reasonSuffix = "（同名文件将先移入回收站，再落位）"
                    } else {
                        // 两种情况都退回加序号：
                        // 1. 与本批次内其它文件的目标重名 —— 两个都要落位，互相覆盖没有意义；
                        // 2. 目标位置上那个文件本身也在本批次里（见 `claimedSourcePaths` 的说明）
                        //    —— 先覆盖掉它会让后一条操作搬错文件。
                        finalPath = numberedAlternative(desired, reserved: reserved)
                        reasonSuffix = inBatch
                            ? "（与本次计划内其他文件重名，自动加序号）"
                            : "（目标位置的文件本次也要移动，自动加序号）"
                    }
                }
            }

            reserved.insert(finalPath)

            // 同目录判定也要按同一性来：两边拼法不同时（见 `pointsToSameFile`），
            // 字符串比较会把「同目录改名」误判成「跨目录移动」，摘要里
            // 「移动 / 重命名」两个数字就跟着错。
            let sameDirectory = pointsToSameDirectory(
                (finalPath as NSString).deletingLastPathComponent,
                (item.path as NSString).deletingLastPathComponent)
            // 复制模式下同目录改名也走复制，保持与用户所选模式语义一致
            let kind: OperationKind = (rule.transferMode == .copy)
                ? .copy
                : (sameDirectory ? .rename : .move)

            operations.append(PlanOperation(
                kind: kind,
                itemID: item.id,
                sourcePath: item.path,
                destinationPath: finalPath,
                reason: buildReason(item: item, rule: rule, extra: reasonSuffix),
                fileSize: item.fileSize,
                kindOfMedia: item.kind,
                fileName: item.fileName,
                overwritesExisting: overwrites))

            result.folderCounts[targetDir, default: 0] += 1
        }

        result.operations = operations
        result.summary = PlanSummary.compute(from: operations)
        result.warnings = buildWarnings(items: items, groups: groups, rule: rule,
                                        filter: filter, result: result,
                                        excludedFolders: excludedFolders)
        return result
    }

    // MARK: - 「所有媒体」页：手动点名的纯清理计划

    /// 把用户在「所有媒体」页勾选的文件翻译成一组移入回收站的操作。
    ///
    /// 单独一个入口，而不是复用 `build(items:groups:rule:filter:)`：那个函数的语义是
    /// 「按规则处理」—— 它会读目录模板、算目标路径、按 `onlyRedundantDuplicates`
    /// 之类的开关过滤，用户点名的文件可能被这些规则**悄悄排除或改变**。
    /// 这里的语义是「用户点了这几个，就清理这几个」，范围必须逐字对应；
    /// 也正因如此，它不看 `PlanFilter`、不产生任何归档操作。
    ///
    /// 仍然不碰文件系统（只做只读探测），执行交给 `PlanExecutor`。
    static func buildTrashOnly(items: [MediaItem],
                               selectedIDs: Set<UUID>,
                               groups: [DuplicateGroup]) -> PlanBuildResult {
        var result = PlanBuildResult()

        // 按 `items` 的既有顺序取，保证同一份勾选每次生成的操作行顺序一致，
        // 界面上不会出现「重新生成一次，行序全变了」。
        let picked = items.filter { $0.kind.isVisualMedia && selectedIDs.contains($0.id) }
        result.consideredCount = items.filter { $0.kind.isVisualMedia }.count
        result.filteredOutCount = result.consideredCount - picked.count
        guard !picked.isEmpty else { return result }

        result.operations = picked.map { item in
            PlanOperation(kind: .trash,
                          itemID: item.id,
                          sourcePath: item.path,
                          destinationPath: nil,
                          reason: "在「所有媒体」页勾选清理",
                          fileSize: item.fileSize,
                          kindOfMedia: item.kind,
                          fileName: item.fileName)
        }
        result.summary = PlanSummary.compute(from: result.operations)
        result.warnings = trashOnlyWarnings(picked: picked, groups: groups)
        return result
    }

    /// 手动勾选清理的风险提示。
    ///
    /// 这条路径绕开了重复项的推荐逻辑 —— 用户可以直接勾中某个组的原件，
    /// 而程序完全不会拦。所以宁可多提示几句：清掉原件之后，那一组就只剩副本了，
    /// 虽然还能从回收站找回，但用户很可能没意识到自己做了这件事。
    private static func trashOnlyWarnings(picked: [MediaItem],
                                          groups: [DuplicateGroup]) -> [String] {
        var warnings: [String] = []
        let chosen = Set(picked.map { $0.id })
        let bytes = picked.reduce(Int64(0)) { $0 + $1.fileSize }
        let sizeLabel = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)

        warnings.append("勾选的 \(picked.count) 个文件将移入系统回收站，预计释放 \(sizeLabel)。"
                        + "文件不会直接消失，可在操作日志里撤销找回。")

        // 整组都被点名 —— 这一组将一份不剩。与「都不保留」是同一个后果，
        // 但那是显式选择，这里很可能是顺手全选出来的，更需要点名。
        var fullyPickedGroups: [DuplicateGroup] = []
        var pickedKeepers = 0
        for group in groups {
            let overlap = chosen.intersection(group.memberIDs)
            guard !overlap.isEmpty else { continue }
            if overlap.count == group.memberIDs.count {
                fullyPickedGroups.append(group)
            }
            pickedKeepers += overlap.filter { member in
                group.keepWholeGroup || group.effectiveKeepIDs.contains(member)
            }.count
        }

        if !fullyPickedGroups.isEmpty {
            let total = fullyPickedGroups.reduce(0) { $0 + $1.memberCount }
            let kinds = Set(fullyPickedGroups.map { $0.kind.displayName }).sorted().joined(separator: "、")
            warnings.append("勾选覆盖了 \(fullyPickedGroups.count) 个重复组的全部成员"
                            + "（\(kinds)，共 \(total) 个文件）：这些组不会留下任何一份。")
        }

        if pickedKeepers > 0 {
            warnings.append("其中 \(pickedKeepers) 个文件正是所在重复组里被判定为「保留」的那几个 ——"
                            + "重复项页的保留决定**不会**阻止这里的清理，清掉后该组就只剩冗余副本了。")
        }

        return warnings
    }

    // MARK: - 序号分配

    /// `{seq}` 按目标目录独立计数，并按拍摄时间先后排序 —— 这样编号顺序
    /// 与照片实际的时间顺序一致，方便人工核对。
    private static func assignSequences(_ prepared: inout [Prepared], rule: OrganizeRule) {
        var groups: [String: [Int]] = [:]
        for (index, entry) in prepared.enumerated() {
            groups[entry.stableDir, default: []].append(index)
        }
        for (_, indices) in groups {
            let ordered = indices.sorted { lhs, rhs in
                let l = prepared[lhs].item, r = prepared[rhs].item
                let ld = l.capturedAt ?? Date.distantFuture
                let rd = r.capturedAt ?? Date.distantFuture
                if ld != rd { return ld < rd }
                if l.fileName != r.fileName { return l.fileName < r.fileName }
                return l.path < r.path
            }
            for (offset, index) in ordered.enumerated() {
                prepared[index].sequence = rule.sequenceStart + offset
            }
        }
    }

    // MARK: - 冲突候选名

    /// 在扩展名前插入 `_n`，逐个试到不冲突为止
    static func numberedAlternative(_ desired: String, reserved: Set<String>) -> String {
        let url = URL(fileURLWithPath: desired)
        let dir = url.deletingLastPathComponent().path
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        var index = 1
        while index < 100_000 {
            let name = ext.isEmpty ? "\(base)_\(index)" : "\(base)_\(index).\(ext)"
            let candidate = dir + "/" + name
            if !reserved.contains(candidate), !FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            index += 1
        }
        let fallback = "\(base)_\(UUID().uuidString.prefix(6))" + (ext.isEmpty ? "" : ".\(ext)")
        return dir + "/" + fallback
    }

    // MARK: - 原因描述

    /// `path` 是否位于 `folders` 里任意一个之内（含目录自身）。
    ///
    /// 用「精确相等或前缀 + 斜杠」而不是裸 `hasPrefix`：否则 `/照片/2023` 会被判为
    /// 命中 `/照片/2023-备份`，把一整个不相关的目录排除掉，而界面上完全看不出来。
    static func isUnder(_ path: String, anyOf folders: [String]) -> Bool {
        for folder in folders {
            if path == folder { return true }
            if path.hasPrefix(folder), path.dropFirst(folder.count).first == "/" { return true }
        }
        return false
    }

    private static func buildReason(item: MediaItem, rule: OrganizeRule, extra: String) -> String {
        var parts: [String] = []

        let template = rule.folderTemplate
        if template.contains("{camera}") || template.contains("{make}") || template.contains("{model}") {
            parts.append("按设备归档：\(item.cameraLabel)")
        } else if item.capturedAt != nil {
            parts.append("拍摄时间 \(item.capturedAtLabel)（来源：\(item.timeSource.displayName)）")
        } else {
            parts.append("拍摄时间未识别")
        }

        if !rule.renameTemplate.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("按命名规则重命名")
        }
        if item.latitude != nil {
            parts.append("含 GPS")
        }
        if !extra.isEmpty { parts.append(extra) }

        return parts.joined(separator: " · ")
    }

    // MARK: - 路径同一性

    /// 文件的唯一标识：`设备号:inode`。取不到（文件不存在 / 无权限）时返回 nil。
    private static func fileIdentity(of path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber else { return nil }
        return "\(device):\(inode)"
    }

    /// 两个路径是否指向同一个文件。
    ///
    /// 不能只比字符串：`item.path` 来自文件系统枚举（**符号链接已被解析**，
    /// 得到 `/private/var/...`），而模板拼出来的 `desired` 用的是用户配置里的源目录
    /// （可能还是 `/var/...`）。同一份文件两种拼法，字符串必然不等 ——
    /// 于是「已经在目标位置」判断失效，继续往下走还会撞上「目标已存在」：
    /// 在覆盖策略下，执行器会先把**这个文件自己**移进回收站，再移动一个已经不在原处的源，
    /// 结果文件进了回收站、计划报告失败。`/tmp`、`/var`、`/etc` 以及任何用户自建的
    /// 软链接都属于这种情况（自检的临时目录正在 `/var/folders` 下，所以这一条一直没被覆盖到）。
    private static func pointsToSameFile(_ lhs: String, _ rhs: String) -> Bool {
        if PathTools.normalized(lhs) == PathTools.normalized(rhs) { return true }
        guard let a = fileIdentity(of: lhs), let b = fileIdentity(of: rhs) else { return false }
        return a == b
    }

    /// 两个目录是否为同一个目录（同样要考虑符号链接）。
    private static func pointsToSameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        pointsToSameFile(lhs, rhs)
    }

    // MARK: - 风险提示

    private static func buildWarnings(items: [MediaItem],
                                      groups: [DuplicateGroup],
                                      rule: OrganizeRule,
                                      filter: PlanFilter,
                                      result: PlanBuildResult,
                                      excludedFolders: [String]) -> [String] {
        var warnings: [String] = []

        // 排除了目录就必须说清楚「影响什么、不影响什么」——
        // 用户勾选时的本意多半是「这些别动」，而这里清理冗余副本仍然是生效的，
        // 不写明白会出现「我明明排除了它，怎么还是被清了」。
        if !excludedFolders.isEmpty {
            warnings.append("有 \(excludedFolders.count) 个目录被勾选「不参与整理」："
                            + "其中的 \(result.excludedCount) 个文件不会按模板移动或重命名，"
                            + "但**重复副本的清理不受影响**。可在「所有媒体」页的来源目录里调整。")
        }

        let unknown = items.filter { $0.capturedAt == nil || $0.timeSource == .none }.count
        if unknown > 0 {
            warnings.append("有 \(unknown) 个文件无法确定拍摄时间，将被归入「\(rule.unknownDateFolder)」目录。")
        }

        let fromFileSystem = items.filter { $0.timeSource == .fileSystem }.count
        if fromFileSystem > 0 {
            warnings.append("有 \(fromFileSystem) 个文件的拍摄时间只能取文件系统时间，可能与真实拍摄时间不符。")
        }

        if !rule.isInPlace {
            for root in items.map({ $0.sourceRoot }) where PathTools.isInside(rule.destinationRoot, parent: root) {
                warnings.append("目标目录位于源目录内部，建议下次扫描时排除该目录，否则会重复处理输出结果。")
                break
            }
        }

        for (label, template) in [("目录模板", rule.folderTemplate), ("命名模板", rule.renameTemplate)] {
            let unknownVars = TemplateRenderer.unknownVariables(in: template)
            if !unknownVars.isEmpty {
                warnings.append("\(label)包含无法识别的变量：\(unknownVars.joined(separator: "、"))。")
            }
        }

        if rule.conflictPolicy == .overwrite {
            warnings.append("冲突策略为「覆盖同名文件」：目标位置的同名文件会被**移入回收站**后由新文件顶替，"
                            + "可在操作日志里撤销找回，但请确认这确实是你想要的结果。")
        }

        if rule.transferMode == .move && result.summary.moveCount > 0 {
            warnings.append("将移动 \(result.summary.moveCount) 个文件，涉及 \(result.summary.moveBytesLabel) 数据。")
        }

        if filter.cleanRedundantDuplicates && result.summary.trashCount > 0 {
            warnings.append("将把 \(result.summary.trashCount) 个重复副本移入回收站，预计释放 \(result.summary.reclaimableLabel)。")
        }

        // 「都不保留」是一条**整组**都不留的决定，风险等级高于普通冗余清理：
        // 普通清理至少有保留项兜底，这里一份都不留，所以必须单独点名，
        // 免得用户以为还有原件在而直接执行。
        let discarded = groups.filter { $0.disposition == .discardAll }
        if filter.cleanRedundantDuplicates, !discarded.isEmpty {
            let count = discarded.reduce(0) { $0 + $1.memberCount }
            warnings.append("有 \(discarded.count) 组被设为「都不保留」：这 \(count) 个文件会**全部**移入回收站，"
                            + "该组不保留任何一份。可在操作日志里撤销找回。")
        }

        // 关闭清理时，重复组的「保留 / 都不保留」决定都不起作用，
        // 冗余副本会和其它文件一样按规则归档 —— 不说清楚很容易被误读成「已经清掉了」。
        if !filter.cleanRedundantDuplicates, !groups.isEmpty {
            warnings.append("本次没有开启「清理重复副本」：\(groups.count) 组重复项一律保持原样，"
                            + "组内文件会和其它文件一样按规则归档，不会被移入回收站。")
        }

        return warnings
    }
}
