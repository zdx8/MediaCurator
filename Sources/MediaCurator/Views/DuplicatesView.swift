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
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "重复项", subtitle: "逐组确认保留哪一份；默认保留分辨率最高、时间最可信的那个", step: 2) {
                AnyView(headerActions)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if state.groups.isEmpty {
                EmptyState(symbol: "square.on.square.dashed",
                           title: state.items.isEmpty ? "还没有扫描结果" : "没有发现重复或相似的文件",
                           message: state.items.isEmpty
                               ? "先在「扫描」页选择目录并完成一次扫描。"
                               : "当前阈值下没有判定出重复项。可以回到扫描页把「相似判定阈值」调大一些再试。",
                           actionTitle: state.items.isEmpty ? "去扫描" : nil,
                           action: state.items.isEmpty ? { state.page = .scan } : nil)
            } else {
                summaryBar
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)

                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(groups.prefix(visibleCount)) { group in
                            DuplicateGroupCard(
                                group: group,
                                items: resolvedMembers(group),
                                isKeep: { state.isKeep($0, in: group) },
                                isLastKeep: { state.isLastKeep($0, in: group) },
                                onToggleKeep: { state.toggleKeep(groupID: group.id, memberID: $0) },
                                onPreview: { itemID in
                                    previewIndex = resolvedMembers(group)
                                        .firstIndex { $0.id == itemID } ?? 0
                                    previewGroupID = group.id
                                },
                                onToggleKeepWhole: {
                                    state.setKeepWholeGroup(groupID: group.id,
                                                            value: !group.keepWholeGroup)
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
                    items: resolvedMembers(group),
                    index: $previewIndex,
                    keepIDs: group.keepIDs,
                    keepWhole: group.keepWholeGroup,
                    onToggleKeep: { state.toggleKeep(groupID: group.id, memberID: $0) },
                    onReveal: { state.revealInFinder($0) },
                    onOpen: { state.openInDefaultApp($0) },
                    onClose: { previewGroupID = nil })
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: previewGroupID)
    }

    private func resolvedMembers(_ group: DuplicateGroup) -> [MediaItem] {
        let byID = state.itemsByID
        return group.memberIDs.compactMap { byID[$0] }
    }

    // MARK: - 顶部操作

    /// 窄窗口下操作拆成两行。
    ///
    /// 原来是一整条 HStack：分段控件（固定 340）+ 汇总标签 + 两个按钮。
    /// 总宽度超过可用宽度时 SwiftUI 会去压其中的子视图，最右边的
    /// 「生成清理计划」被压到只显示半截 —— 而它是这一页最主要的动作。
    /// 这里用 `ViewThatFits` 让它在放不下时整体换行，按钮再加 `fixedSize`
    /// 声明「我不接受压缩」，宁可换行也不裁字。
    private var headerActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                filterPicker.frame(width: 340)
                wholeGroupChip
                resetButton
                planButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    filterPicker.frame(width: 300)
                    wholeGroupChip
                }
                HStack(spacing: 10) {
                    resetButton
                    planButton
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

    @ViewBuilder
    private var wholeGroupChip: some View {
        if state.dedupSummary.keptWholeGroupCount > 0 {
            TagChip(text: "整组保留 \(state.dedupSummary.keptWholeGroupCount) 组",
                    tint: Palette.positive, filled: false)
                .fixedSize()
        }
    }

    private var resetButton: some View {
        Button("恢复推荐") { state.resetKeepRecommendations() }
            .controlSize(.regular)
            .fixedSize()
            .disabled(state.groups.isEmpty)
            .help("清除所有人工决定（改选的保留项与整组保留），恢复成程序推荐结果")
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
    let onToggleKeepWhole: () -> Void
    let onReveal: (String) -> Void
    let onOpen: (String) -> Void

    private var reclaimable: Int64 {
        group.reclaimableBytes(sizes: Dictionary(items.map { ($0.id, $0.fileSize) },
                                                 uniquingKeysWith: { first, _ in first }))
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
            .strokeBorder(group.keepWholeGroup
                          ? Palette.positive.opacity(0.45)
                          : Palette.tint(for: group.kind).opacity(0.28),
                          lineWidth: group.keepWholeGroup ? 1.5 : 1))
    }

    private func tileMode(for item: MediaItem) -> MemberTile.Mode {
        // 整组保留时不再区分保留/冗余，所有成员一律中性呈现
        if group.keepWholeGroup { return .neutral }
        return isKeep(item.id) ? .keep : .redundant
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
        if group.keepWholeGroup {
            hintLine(icon: "checkmark.shield.fill",
                     tint: Palette.positive,
                     title: "整组保留",
                     detail: "本组 \(group.memberCount) 个文件都不会被清理，仍会按整理规则归档")
        } else if group.allMembersKept {
            hintLine(icon: "checkmark.circle.fill",
                     tint: Palette.positive,
                     title: "全部 \(group.memberCount) 份都已勾选保留",
                     detail: "本组不产生清理操作")
        } else {
            keptFooter
        }
    }

    /// 部分保留：说清「留下几份、清理几份、留下的是哪几个」
    private var keptFooter: some View {
        let keep = group.effectiveKeepIDs
        let keptNames = items.filter { keep.contains($0.id) }.map(\.fileName)
        let removableCount = max(0, items.count - keptNames.count)
        // 只有当用户的选择恰好等于程序推荐时，理由才有意义
        let matchesRecommendation = keptNames.count == 1 && items.first.map { keep.contains($0.id) } == true

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

            KeepWholeToggle(isOn: group.keepWholeGroup,
                            memberCount: group.memberCount,
                            action: onToggleKeepWhole)
                .fixedSize()
        }
    }
}

// MARK: - 保留整组开关

/// 分组卡片右上角的「保留整组」。
///
/// 语义是「这几张其实都有价值，只是长得像」—— 只取消清理，不影响归档，
/// 所以提示文字要写清楚，否则用户会以为连归档也一并跳过了。
private struct KeepWholeToggle: View {
    let isOn: Bool
    let memberCount: Int
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.shield.fill" : "checkmark.shield")
                    .font(.system(size: 10.5, weight: .medium))
                Text(isOn ? "已整组保留" : "保留整组")
                    .font(.system(size: 11, weight: isOn ? .semibold : .regular))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .foregroundStyle(isOn ? Color.white : Palette.positive)
            .background(Capsule().fill(isOn
                                       ? Palette.positive
                                       : Palette.positive.opacity(hovering ? 0.16 : 0.08)))
            .overlay(Capsule().strokeBorder(isOn ? .clear : Palette.positive.opacity(0.35),
                                            lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // 提示文案随多选语义一起更新 ——
        // 原来写的是「点击可恢复为只保留其中一个」，支持多选后这个说法就不成立了。
        .help(isOn
              ? "本组 \(memberCount) 个文件都不会被清理。点击关闭后，本组恢复为按勾选清理。"
              : "这 \(memberCount) 个文件都要留下 —— 本组不产生任何清理操作，"
                + "但仍会按整理规则归档到目标目录。")
    }
}

// MARK: - 成员卡片

struct MemberTile: View {

    /// 成员在组内的呈现方式。
    /// 整组保留时不再区分保留与冗余，统一走 `neutral`。
    enum Mode {
        case keep       // 被勾选为保留项
        case redundant  // 会被清理的冗余副本
        case neutral    // 整组保留，不参与清理
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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Button(action: onPreview) {
                    ThumbnailView(url: item.url, kind: item.kind, size: 112,
                                  highlighted: kept,
                                  dimmed: mode == .redundant)
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

                if kept && !neutral {
                    Text("保留")
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(Palette.positive))
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

                // 整组保留时「保留哪一份」已经没有意义，隐藏勾选避免误解
                if !neutral {
                    KeepCheckbox(isOn: kept,
                                 enabled: !(kept && !canUncheck),
                                 action: onToggleKeep)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(kept && !neutral
                  ? Palette.positive.opacity(0.08)
                  : Color(nsColor: .quaternaryLabelColor).opacity(hovering ? 0.14 : 0.07)))
        .onHover { hovering = $0 }
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
