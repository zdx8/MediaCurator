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
                                onSetKeep: { state.setKeep(groupID: group.id, memberID: $0) },
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
                    keepID: group.keepID,
                    keepWhole: group.keepWholeGroup,
                    onSetKeep: { state.setKeep(groupID: group.id, memberID: $0) },
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

    private var headerActions: some View {
        HStack(spacing: 10) {
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
            .frame(width: 340)

            if state.dedupSummary.keptWholeGroupCount > 0 {
                TagChip(text: "整组保留 \(state.dedupSummary.keptWholeGroupCount) 组",
                        tint: Palette.positive, filled: false)
            }

            Button("恢复推荐") { state.resetKeepRecommendations() }
                .controlSize(.regular)
                .disabled(state.groups.isEmpty)
                .help("清除所有人工决定（改选的保留项与整组保留），恢复成程序推荐结果")

            Button {
                state.filter.cleanRedundantDuplicates = true
                state.filter.onlyRedundantDuplicates = true
                state.generatePlan()
            } label: {
                Label("生成清理计划", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(state.groups.isEmpty)
        }
    }

    private var summaryBar: some View {
        HStack(spacing: 12) {
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
    let onSetKeep: (UUID) -> Void
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
                ForEach(items) { item in
                    MemberTile(item: item,
                               mode: tileMode(for: item),
                               onSetKeep: { onSetKeep(item.id) },
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

    @ViewBuilder
    private var footer: some View {
        if group.keepWholeGroup {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.positive)
                Text("整组保留")
                    .font(.system(size: 11.5, weight: .medium))
                Text("· 本组 \(group.memberCount) 个文件都不会被清理，仍会按整理规则归档")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        } else if let keepID = group.keepID,
                  let keepItem = items.first(where: { $0.id == keepID }) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.positive)
                Text("保留「\(keepItem.fileName)」")
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Text("· \(group.keepReason.displayName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: group.kind.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.tint(for: group.kind))
            TagChip(text: group.kind.displayName, tint: Palette.tint(for: group.kind))
            Text("\(group.memberCount) 个成员")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if group.kind != .exact {
                Text("· 最大距离 \(group.maxDistance)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)

            if reclaimable > 0 {
                Text("可释放 " + ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.danger)
            }

            KeepWholeToggle(isOn: group.keepWholeGroup,
                            memberCount: group.memberCount,
                            action: onToggleKeepWhole)
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
        .help(isOn
              ? "本组 \(memberCount) 个文件都不会被清理。点击可恢复为只保留其中一个。"
              : "这 \(memberCount) 个文件都要留下 —— 本组不产生任何清理操作，"
                + "但仍会按整理规则归档到目标目录。")
    }
}

// MARK: - 成员卡片

struct MemberTile: View {

    /// 成员在组内的呈现方式。
    /// 整组保留时不再区分保留与冗余，统一走 `neutral`。
    enum Mode {
        case keep       // 被选为保留项
        case redundant  // 会被清理的冗余副本
        case neutral    // 整组保留，不参与清理
    }

    let item: MediaItem
    let mode: Mode
    let onSetKeep: () -> Void
    let onPreview: () -> Void
    let onReveal: () -> Void
    let onOpen: () -> Void

    @State private var hovering = false

    private var kept: Bool { mode == .keep }
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

                if kept {
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
                // 整组保留时「保留哪一份」已经没有意义，隐藏该按钮避免误解
                if !neutral {
                    Button(kept ? "已保留" : "设为保留", action: onSetKeep)
                        .controlSize(.mini)
                        .disabled(kept)
                }
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
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(kept
                  ? Palette.positive.opacity(0.08)
                  : Color(nsColor: .quaternaryLabelColor).opacity(hovering ? 0.14 : 0.07)))
        .onHover { hovering = $0 }
    }
}
