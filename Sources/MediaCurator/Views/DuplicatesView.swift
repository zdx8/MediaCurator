import SwiftUI
import AppKit

struct DuplicatesView: View {
    @ObservedObject var state: AppState
    @State private var visibleCount = 60

    /// 放大预览：记录当前所在分组与组内下标。
    /// 用分组 id 而不是直接持有成员数组 —— 预览期间用户可能改选保留项，
    /// 重新按 id 解析才能拿到最新状态。
    @State private var previewGroupID: UUID?
    @State private var previewIndex = 0

    private var groups: [DuplicateGroup] { state.filteredGroups }

    private var previewGroup: DuplicateGroup? {
        guard let id = previewGroupID else { return nil }
        return state.groups.first { $0.id == id }
    }

    var body: some View {
        // `itemsByID` 是一次 O(文件数) 的字典构建，而下面每张分组卡片都要用它。
        // 放在 `resolvedMembers` 里按卡片各建一次，60 张可见卡片就是 60 遍全量遍历 ——
        // 几万个文件的库上，每次重绘都会卡一下。这里算一次，往下传。
        let byID = state.itemsByID

        VStack(alignment: .leading, spacing: 0) {
            // 页头右侧只放**一个**主动作。页头右侧分到的是标题与副标题剩下的宽度
            // （最小窗口下约 420pt），按钮一多就必然被压缩 —— 这是「生成清理计划
            // 显示不完全」的成因。其余控件统一走下面整宽的 `toolRow`。
            PageHeader(title: "重复项", subtitle: "逐组确认保留哪一份；默认保留分辨率最高、时间最可信的那个", step: 2) {
                AnyView(planButton)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if state.groups.isEmpty {
                EmptyState(symbol: "square.on.square.dashed",
                           title: emptyTitle,
                           message: emptyMessage,
                           actionTitle: emptyNeedsScanPage ? "去扫描页" : nil,
                           action: emptyNeedsScanPage ? { state.page = .scan } : nil)
            } else {
                toolRow
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)

                summaryBar
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)

                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(groups.prefix(visibleCount)) { group in
                            DuplicateGroupCard(
                                group: group,
                                items: resolvedMembers(group, byID: byID),
                                isKeep: { state.isKeep($0, in: group) },
                                isLastKeep: { state.isLastKeep($0, in: group) },
                                onToggleKeep: { state.toggleKeep(groupID: group.id, memberID: $0) },
                                onPreview: { itemID in
                                    previewIndex = resolvedMembers(group, byID: byID)
                                        .firstIndex { $0.id == itemID } ?? 0
                                    previewGroupID = group.id
                                },
                                onSetDisposition: { disposition in
                                    state.toggleDisposition(groupID: group.id, disposition: disposition)
                                },
                                onReveal: { state.revealInFinder($0) },
                                onOpen: { state.openInDefaultApp($0) })
                        }
                        if groups.count > visibleCount {
                            Button {
                                visibleCount += 60
                            } label: {
                                Label("继续加载（还有 \(groups.count - visibleCount) 组）",
                                      systemImage: "ellipsis.circle")
                            }
                            .controlSize(.regular)
                            .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 26)
                }
            }
        }
        .onChange(of: state.duplicateFilter) { _, _ in visibleCount = 60 }
        .overlay {
            if let group = previewGroup {
                MediaPreviewOverlay(
                    items: resolvedMembers(group, byID: byID),
                    index: $previewIndex,
                    keepIDs: group.keepIDs,
                    disposition: group.disposition,
                    onToggleKeep: { state.toggleKeep(groupID: group.id, memberID: $0) },
                    onReveal: { state.revealInFinder($0) },
                    onOpen: { state.openInDefaultApp($0) },
                    onClose: { previewGroupID = nil })
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: previewGroupID)
    }

    /// 把分组的成员 id 解析成条目。`byID` 由调用方在 `body` 里算一次传进来 ——
    /// 这里自己再建一遍字典就会变成「每张卡片各遍历一次全量文件」。
    private func resolvedMembers(_ group: DuplicateGroup,
                                 byID: [UUID: MediaItem]) -> [MediaItem] {
        group.memberIDs.compactMap { byID[$0] }
    }

    // MARK: - 空状态

    /// 空状态有**三种**成因，混成一句会误导人：
    /// 没扫过、扫了但关了查重、查了但确实没有重复。
    /// 中间那种最容易被当成「这个工具什么也没找出来」，所以要明确让人回扫描页打开开关。
    private var emptyTitle: String {
        if state.items.isEmpty { return "还没有扫描结果" }
        if !state.settings.checkDuplicates { return "本次扫描没有检查重复" }
        return "没有发现重复或相似的文件"
    }

    private var emptyMessage: String {
        if state.items.isEmpty {
            return "先在「扫描」页选择目录并完成一次扫描。"
        }
        if !state.settings.checkDuplicates {
            return "扫描页的「检查重复媒体」是关闭状态 —— 文件已经扫进来了，"
                + "但没有做重复与相似比对。打开它、重新扫描一次即可。"
        }
        return "当前阈值下没有判定出重复项。可以回到扫描页把「相似判定阈值」调大一些再试。"
    }

    private var emptyNeedsScanPage: Bool {
        state.items.isEmpty || !state.settings.checkDuplicates
    }

    // MARK: - 顶部操作

    /// 筛选、整组决定的计数，以及两个次要动作。
    ///
    /// 这一行占满整页宽度，所以「放不放得下」是可以算清的：
    /// 分段控件 340 + 两个状态标签最多约 210 + 两个按钮约 250 + 间距 ≈ 840，
    /// 比最小窗口下内容区的 876 略有余量。`ViewThatFits` 只是兜底 ——
    /// 万一将来再加控件，它会整体换行，而不是把某个按钮压到只剩半截。
    private var toolRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                filterPicker.frame(width: 340)
                statusChips
                Spacer(minLength: 8)
                resetButton
                archiveOnlyButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    filterPicker.frame(width: 300)
                    statusChips
                }
                HStack(spacing: 10) {
                    resetButton
                    archiveOnlyButton
                }
            }
        }
    }

    private var filterPicker: some View {
        Picker("", selection: $state.duplicateFilter) {
            Text("全部 \(state.groups.count)").tag(DuplicateKind?.none)
            Text("精确 \(state.dedupSummary.exactGroupCount)").tag(DuplicateKind?.some(.exact))
            Text("相似图片 \(state.dedupSummary.similarImageGroupCount)")
                .tag(DuplicateKind?.some(.similarImage))
            Text("相似视频 \(state.dedupSummary.similarVideoGroupCount)")
                .tag(DuplicateKind?.some(.similarVideo))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// 整组决定的计数。
    ///
    /// 数字直接来自 `dedupSummary`，而摘要在 `groups` 一变就重算（见 `AppState.groups`
    /// 的观察器）—— 所以不会出现「卡片上明明写着都不保留、这里却没算上」这种自相矛盾。
    /// 之前这里是读一份手动维护的缓存，有一条路径（执行计划后剔除失效分组）忘了刷新，
    /// 计数就会和卡片对不上。
    @ViewBuilder
    private var statusChips: some View {
        HStack(spacing: 6) {
            if state.dedupSummary.keptWholeGroupCount > 0 {
                TagChip(text: "保留整组 \(state.dedupSummary.keptWholeGroupCount) 组",
                        tint: Palette.positive, filled: false)
                    .fixedSize()
                    .help("这些组不产生任何清理操作，文件仍会按整理规则归档")
            }
            if state.dedupSummary.discardedWholeGroupCount > 0 {
                TagChip(text: "都不保留 \(state.dedupSummary.discardedWholeGroupCount) 组",
                        tint: Palette.danger, filled: false)
                    .fixedSize()
                    .help("这些组的所有文件都会移入系统回收站，可通过操作日志撤销找回")
            }
        }
    }

    private var resetButton: some View {
        Button("恢复推荐") { state.resetKeepRecommendations() }
            .controlSize(.regular)
            .fixedSize()
            .disabled(state.groups.isEmpty)
            .help("清除所有人工决定（改选的保留项与整组决定），恢复成程序推荐结果")
    }

    /// 跳过重复项，只按整理规则归档。
    ///
    /// 与主按钮互补：主按钮走纯清理模式（只清冗余副本、不归档），
    /// 这个按钮则完全不碰重复项，只把目录结构整理好。
    /// 之前重复项页只有前者，不想处理重复副本的用户会被迫先离开这一页。
    private var archiveOnlyButton: some View {
        Button {
            state.generateArchiveOnlyPlan()
        } label: {
            Label("跳过重复项，只做归档", systemImage: "folder.badge.gearshape")
        }
        .controlSize(.regular)
        .fixedSize()
        .disabled(state.items.isEmpty)
        .help("不清理任何重复副本，只按「整理规则」页的模板把文件归档到目标目录。")
    }

    private var planButton: some View {
        Button {
            state.filter.cleanRedundantDuplicates = true
            state.filter.onlyRedundantDuplicates = true
            state.generatePlan()
        } label: {
            Label("生成清理计划", systemImage: "wand.and.stars")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .fixedSize()
        .disabled(state.groups.isEmpty)
        .help("只生成「把冗余副本移入回收站」的操作，不包含归档。"
              + "想先整理目录结构，请用「跳过重复项，只做归档」。")
    }

    /// 摘要卡。用自适应栅格而不是固定一行 —— 窄窗口下它会自动折成两行，
    /// 而不是把每张卡都压到放不下文字。
    private var summaryBar: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 12)],
                  alignment: .leading, spacing: 12) {
            StatCard(title: "重复组", value: "\(state.dedupSummary.totalGroupCount)",
                     subtitle: "冗余 \(state.dedupSummary.redundantFileCount) 个文件",
                     symbol: "square.on.square", tint: Palette.caution)
            StatCard(title: "可释放空间", value: state.dedupSummary.reclaimableLabel,
                     subtitle: "移入回收站后回收", symbol: "arrow.down.circle", tint: Palette.danger)
            StatCard(title: "精确重复", value: "\(state.dedupSummary.exactGroupCount)",
                     subtitle: "字节完全一致", symbol: "equal.circle")
            StatCard(title: "相似图片", value: "\(state.dedupSummary.similarImageGroupCount)",
                     subtitle: "像素指纹接近", symbol: "photo.on.rectangle.angled",
                     tint: Palette.caution)
            StatCard(title: "相似视频", value: "\(state.dedupSummary.similarVideoGroupCount)",
                     subtitle: "抽帧序列接近", symbol: "film.stack",
                     tint: Palette.violet)
        }
    }
}

// MARK: - 分组卡片

struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    let items: [MediaItem]
    let isKeep: (UUID) -> Bool
    /// 该成员是否已是本组唯一的保留项（取消勾选会被禁用，避免整组没人保留）
    let isLastKeep: (UUID) -> Bool
    let onToggleKeep: (UUID) -> Void
    let onPreview: (UUID) -> Void
    /// 设置整组决定。传当前已生效的那个表示取消，回到「按勾选」。
    let onSetDisposition: (GroupDisposition) -> Void
    let onReveal: (String) -> Void
    let onOpen: (String) -> Void

    private var reclaimable: Int64 {
        group.reclaimableBytes(sizes: Dictionary(items.map { ($0.id, $0.fileSize) },
                                                 uniquingKeysWith: { first, _ in first }))
    }

    /// 整组决定的卡片描边。整组保留用绿、都不保留用红 ——
    /// 「这一组被我动过」在扫视时应当一眼可见，不能只靠底部一行小字。
    private var borderColor: Color {
        switch group.disposition {
        case .keepAll: return Palette.positive.opacity(0.45)
        case .discardAll: return Palette.danger.opacity(0.5)
        case .bySelection: return Palette.tint(for: group.kind).opacity(0.28)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 152), spacing: 10)], spacing: 10) {
                ForEach(items) { item in
                    MemberTile(item: item,
                               mode: tileMode(for: item),
                               kept: isKeep(item.id),
                               canUncheck: !isLastKeep(item.id),
                               onToggleKeep: { onToggleKeep(item.id) },
                               onPreview: { onPreview(item.id) },
                               onReveal: { onReveal(item.path) },
                               onOpen: { onOpen(item.path) })
                }
            }
            footer
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(borderColor,
                          lineWidth: group.disposition == .bySelection ? 1 : 1.5))
    }

    private func tileMode(for item: MediaItem) -> MemberTile.Mode {
        // 整组决定生效时不再区分保留/冗余，所有成员一律按整组的语义呈现：
        // 整组保留 = 都留下，都不保留 = 都会被清理，逐张勾选在这一层已经没有意义。
        switch group.disposition {
        case .keepAll: return .neutral
        case .discardAll: return .discard
        case .bySelection: return isKeep(item.id) ? .keep : .redundant
        }
    }

    // MARK: - 底部提示

    /// 一行提示统一走这里，避免各处再写出容易被压扁的裸 Text 组合。
    ///
    /// 标题与尾部结论用 `fixedSize()` 声明不可压缩，说明文字用
    /// `fixedSize(horizontal: false, vertical: true)` 允许换行 ——
    /// 原来的写法是裸 HStack，窄窗口下说明会被压成一条很窄的竖条，
    /// 看起来像是显示坏了。
    private func hintLine(icon: String,
                          tint: Color,
                          title: String,
                          detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize()
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch group.disposition {
        case .keepAll:
            hintLine(icon: "checkmark.shield.fill",
                     tint: Palette.positive,
                     title: "保留整组",
                     detail: "本组 \(group.memberCount) 个文件都不会被清理，仍会按整理规则归档")
        case .discardAll:
            // 这是唯一一条「本组一份都不留」的路径，文案必须说清可恢复性，
            // 否则用户会以为文件直接消失了。
            hintLine(icon: "trash.fill",
                     tint: Palette.danger,
                     title: "都不保留",
                     detail: "本组 \(group.memberCount) 个文件会全部移入系统回收站"
                         + "（可在操作日志里撤销找回）")
        case .bySelection:
            if group.allMembersKept {
                hintLine(icon: "checkmark.circle.fill",
                         tint: Palette.positive,
                         title: "全部 \(group.memberCount) 份都已勾选保留",
                         detail: "本组不产生清理操作")
            } else {
                keptFooter
            }
        }
    }

    /// 部分保留：说清「留下几份、清理几份、留下的是哪几个」
    private var keptFooter: some View {
        // 「清理几份」与计划生成读的是同一个属性（`redundantMemberIDs`），
        // 所以这里显示的数字和最终生成的操作数一定一致。
        let redundant = group.redundantMemberIDs
        let keptNames = items.filter { !redundant.contains($0.id) }.map(\.fileName)
        let removableCount = redundant.count
        // 只有当用户的选择恰好等于程序推荐时，理由才有意义
        let matchesRecommendation = keptNames.count == 1
            && items.first.map { !redundant.contains($0.id) } == true

        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 11))
                .foregroundStyle(Palette.positive)
            Text("保留 \(keptNames.count) 份")
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize()
            Text("：" + keptNames.joined(separator: "、"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(keptNames.joined(separator: "\n"))
            Text("· 将清理 \(removableCount) 份")
                .font(.system(size: 11))
                .foregroundStyle(removableCount > 0 ? Palette.danger : Color.secondary)
                .fixedSize()
            if matchesRecommendation {
                Text("· " + group.keepReason.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: group.kind.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.tint(for: group.kind))
            TagChip(text: group.kind.displayName, tint: Palette.tint(for: group.kind))
                .fixedSize()
            Text("\(group.memberCount) 个成员")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize()
            if group.kind != .exact {
                Text("· 最大距离 \(group.maxDistance)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            Spacer(minLength: 8)

            if reclaimable > 0 {
                Text("可释放 " + ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.danger)
                    .fixedSize()
            }

            KeepWholeToggle(disposition: group.disposition,
                            memberCount: group.memberCount,
                            action: onSetDisposition)
                .fixedSize()
        }
    }
}

// MARK: - 整组决定开关

/// 分组卡片右上角的两个整组决定：「都不保留」/「保留整组」。
///
/// 两者互斥，同时点选一个就等于取消（回到「按勾选」）。做成一对并排的按钮
/// 而不是一个下拉或单选组，是因为这一页的主线操作就是「逐组扫一遍」：
/// 一眼看到两个选项、一次点击做出决定，比展开菜单再选要快得多。
///
/// 语义边界（文案必须写清，否则最容易被误解）：
/// - 「保留整组」= 这几张其实都有价值，只是长得像 → 只取消清理，不影响归档
/// - 「都不保留」= 这一组我一张都不要了 → 全部移入系统回收站，可撤销找回
private struct KeepWholeToggle: View {
    let disposition: GroupDisposition
    let memberCount: Int
    let action: (GroupDisposition) -> Void

    var body: some View {
        HStack(spacing: 6) {
            DispositionChip(target: .discardAll, current: disposition,
                            onLabel: "已都不保留", offLabel: "都不保留",
                            onSymbol: "trash.fill", offSymbol: "trash",
                            tint: Palette.danger,
                            help: help(for: .discardAll),
                            action: action)
            DispositionChip(target: .keepAll, current: disposition,
                            onLabel: "已整组保留", offLabel: "保留整组",
                            onSymbol: "checkmark.shield.fill", offSymbol: "checkmark.shield",
                            tint: Palette.positive,
                            help: help(for: .keepAll),
                            action: action)
        }
    }

    private func help(for target: GroupDisposition) -> String {
        switch target {
        case .discardAll:
            return disposition == .discardAll
                ? "本组 \(memberCount) 个文件全部都会被清理。点击关闭后，本组恢复为按勾选清理。"
                : "这一组一张都不要：\(memberCount) 个文件全部移入系统回收站（可在操作日志里撤销找回）。"
        case .keepAll:
            return disposition == .keepAll
                ? "本组 \(memberCount) 个文件都不会被清理。点击关闭后，本组恢复为按勾选清理。"
                : "这 \(memberCount) 个文件都要留下 —— 本组不产生任何清理操作，"
                    + "但仍会按整理规则归档到目标目录。"
        case .bySelection:
            return "按组内勾选决定保留哪些"
        }
    }
}

/// 单个整组决定胶囊。独立成类型是为了能各自持有悬停状态 ——
/// 悬停变色是「这个胶囊可以点」的唯一提示，用函数生成视图就拿不到 `@State`。
private struct DispositionChip: View {
    let target: GroupDisposition
    let current: GroupDisposition
    let onLabel: String
    let offLabel: String
    let onSymbol: String
    let offSymbol: String
    let tint: Color
    let help: String
    let action: (GroupDisposition) -> Void

    @State private var hovering = false

    private var isOn: Bool { current == target }

    var body: some View {
        Button { action(target) } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? onSymbol : offSymbol)
                    .font(.system(size: 10.5, weight: .medium))
                Text(isOn ? onLabel : offLabel)
                    .font(.system(size: 11, weight: isOn ? .semibold : .regular))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .foregroundStyle(isOn ? Color.white : tint)
            .background(Capsule().fill(isOn ? tint : tint.opacity(hovering ? 0.16 : 0.08)))
            .overlay(Capsule().strokeBorder(isOn ? .clear : tint.opacity(0.35),
                                            lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - 成员卡片

struct MemberTile: View {

    /// 成员在组内的呈现方式。
    /// 两种整组决定下都不再区分保留与冗余，统一按整组语义呈现。
    enum Mode {
        case keep       // 被勾选为保留项
        case redundant  // 会被清理的冗余副本
        case neutral    // 整组保留，不参与清理
        case discard    // 整组都不保留，会被移入回收站
    }

    let item: MediaItem
    let mode: Mode
    /// 是否被勾选为保留。**可多选**，所以和 `mode` 分开传：
    /// `mode` 描述整体呈现，`kept` 描述这一份的选择状态。
    let kept: Bool
    /// 是否允许取消勾选（本组唯一的保留项不允许取消）
    let canUncheck: Bool
    let onToggleKeep: () -> Void
    let onPreview: () -> Void
    let onReveal: () -> Void
    let onOpen: () -> Void

    @State private var hovering = false

    private var neutral: Bool { mode == .neutral }
    private var discarded: Bool { mode == .discard }
    /// 整组决定生效时逐张勾选无效，勾选框直接隐藏（而不是留一个禁用态），
    /// 免得用户以为还能在这一层改结果。
    private var selectionLocked: Bool { neutral || discarded }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Button(action: onPreview) {
                    ThumbnailView(url: item.url, kind: item.kind, size: 112,
                                  highlighted: kept && !selectionLocked,
                                  dimmed: mode == .redundant || discarded)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            // 悬停时给出「可点击放大」的提示，否则纯缩略图看不出能点
                            if hovering {
                                ZStack {
                                    Color.black.opacity(0.34)
                                    Image(systemName: "plus.magnifyingglass")
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundStyle(.white)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                }
                .buttonStyle(.plain)
                .help("点击放大预览")

                if kept && !selectionLocked {
                    Text("保留")
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(Palette.positive))
                        .padding(5)
                        .allowsHitTesting(false)
                } else if discarded {
                    Text("将清理")
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(Palette.danger))
                        .padding(5)
                        .allowsHitTesting(false)
                }
            }

            Text(item.fileName)
                .font(.system(size: 11, weight: kept ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.resolutionLabel)
                        .font(.system(size: 10, design: .rounded))
                    if let duration = item.durationLabel {
                        Text(duration).font(.system(size: 10, design: .rounded))
                    }
                }
                .foregroundStyle(.secondary)

                Text(item.fileSizeLabel + " · " + item.capturedAtLabel)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Text("时间来源 " + item.timeSource.displayName)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)

                PathLabel(path: item.parentPath, font: .system(size: 9.5), color: Palette.tertiaryText)
            }

            HStack(spacing: 6) {
                Button {
                    onReveal()
                } label: {
                    Image(systemName: "folder").font(.system(size: 10))
                }
                .controlSize(.mini)
                .help("在访达中显示")
                Button {
                    onOpen()
                } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 10))
                }
                .controlSize(.mini)
                .help("用默认程序打开")

                Spacer(minLength: 4)

                // 整组决定生效时「保留哪一份」已经没有意义，隐藏勾选避免误解
                if !selectionLocked {
                    KeepCheckbox(isOn: kept,
                                 enabled: !(kept && !canUncheck),
                                 action: onToggleKeep)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(tileBackground))
        .onHover { hovering = $0 }
    }

    private var tileBackground: Color {
        if discarded { return Palette.danger.opacity(hovering ? 0.16 : 0.09) }
        if kept && !selectionLocked { return Palette.positive.opacity(0.08) }
        return Color(nsColor: .quaternaryLabelColor).opacity(hovering ? 0.14 : 0.07)
    }
}

// MARK: - 保留勾选

/// 成员卡片右下角的「保留」勾选。
///
/// 做成复选框而不是「设为保留」按钮，是因为保留**支持多选**：
/// 按钮的语义是「把保留项换成这一张」，会让人以为选了它就会取消上一张。
/// 复选框则天然表达「这一张要不要留」，可以随便勾几个。
private struct KeepCheckbox: View {
    let isOn: Bool
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 5, style: .continuous) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11, weight: .medium))
                Text("保留")
                    .font(.system(size: 10.5, weight: isOn ? .semibold : .regular))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .foregroundStyle(isOn ? Palette.positive : Palette.tertiaryText)
            .background(shape.fill(isOn
                                   ? Palette.positive.opacity(0.12)
                                   : Color(nsColor: .quaternaryLabelColor)
                                       .opacity(hovering && enabled ? 0.18 : 0.07)))
            .overlay(shape.strokeBorder(isOn ? Palette.positive.opacity(0.5)
                                             : Palette.tertiaryText.opacity(0.3),
                                        lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(isOn
              ? (enabled ? "已勾选保留（可多选）。点击取消这一份。"
                         : "本组至少要保留一份，先勾上另一份再取消这一份")
              : "勾选保留（可多选）")
    }
}
