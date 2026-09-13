import SwiftUI
import AppKit

/// 「所有媒体」页：把扫描到的全部文件摊开，由用户直接点名要清理哪些。
///
/// 与「重复项」页的分工是这一页存在的理由：那边是**程序判定**哪几份算冗余、
/// 用户逐组确认或否决；这里是**用户点名**，程序完全不参与判断。
/// 两条路最终都只产生「移入系统回收站」的操作，但范围来源不同 ——
/// 所以是两个页面，而不是一个页面上再加一排按钮：混在一起会让用户分不清
/// 「这个勾是程序推荐要清的」还是「我自己挑的」。
struct AllMediaView: View {
    @ObservedObject var state: AppState
    /// 仅供离屏渲染注入：指定初始的折叠集合，跳过「默认收起第一层以下」那一步。
    ///
    /// 传 nil（正常运行）走默认逻辑。存在的意义是让「默认折叠到底有没有生效」
    /// 能在离屏渲染里被验证 —— 目录树少几行、多几行，看截图根本分辨不出来，
    /// 而它恰恰是个很容易「代码写了但没接上」的地方。
    var injectedCollapsed: Set<String>? = nil

    @State private var visibleCount = 120
    @State private var previewIndex: Int?
    /// 来源目录树默认展开：这是「这一页能看到哪些目录、哪些目录不参与整理」的唯一入口，
    /// 折叠着的话用户根本不知道有这回事。嫌占地方再收起来。
    @State private var showFolderTree = true
    /// 被收起子目录的路径。
    ///
    /// 存路径而不是下标或 id：重新扫描后目录树会重建，只有路径在两次之间是稳定的。
    /// 这也是临时浏览状态，不持久化 —— 下次打开重新按默认收起，比记住一堆状态更符合预期。
    @State private var collapsedFolders: Set<String> = []
    /// 「首次进入默认收起第一层以下」是否已经应用过。
    /// 只应用一次：之后再怎么刷新数据，都不能覆盖用户自己折叠／展开的结果。
    @State private var didApplyDefaultCollapse = false

    var body: some View {
        // 筛选结果、重复角色、目录树各算一次就够。它们都是 O(文件数) 甚至 O(n log n)
        // 的计算属性，直接在各个子视图里反复取会在每次重绘时重复排序上万条记录。
        let visible = state.visibleMediaItems
        let roles = state.duplicateRoleByItemID
        let sourceGroups = state.sourceFolderGroups

        VStack(alignment: .leading, spacing: 0) {
            // 页头右侧只留一个主动作，其余控件走下面占满整宽的操作行 ——
            // 页头右侧拿到的是标题与副标题**剩下**的宽度，控件一多必然被压缩。
            PageHeader(title: "所有媒体",
                       subtitle: "扫描到的全部图片与视频；勾选的文件会由计划移入系统回收站",
                       step: AppPage.allMedia.step) {
                AnyView(planButton)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if state.items.isEmpty {
                EmptyState(symbol: "square.grid.2x2",
                           title: "还没有扫描结果",
                           message: "先在「扫描」页选择目录并完成一次扫描，这里会列出全部媒体文件。",
                           actionTitle: "去扫描",
                           action: { state.page = .scan })
            } else {
                toolRow(visible: visible)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)

                summaryRow
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)

                gridArea(visible: visible, roles: roles, sourceGroups: sourceGroups)
            }
        }
        .overlay { previewOverlay(visible: visible) }
        .animation(.easeInOut(duration: 0.16), value: previewIndex)
        .onChange(of: state.mediaFilter) { _, _ in visibleCount = 120 }
        // 目录树就绪时应用一次「默认收起第一层以下」。
        //
        // 用 `task(id:)` 而不是 `onAppear`：用户很可能是**先扫描、再切到这一页**，
        // 而这一页在侧栏里是随时可点的 —— 挂 onAppear 会漏掉「进来时还没有数据」这种顺序。
        // `didApplyDefaultCollapse` 保证只生效一次，之后不再干扰用户自己的折叠状态。
        .task(id: state.items.count) {
            if let injected = injectedCollapsed {
                collapsedFolders = injected
                didApplyDefaultCollapse = true
                return
            }
            applyDefaultCollapseIfNeeded(sourceGroups)
        }
    }

    private func applyDefaultCollapseIfNeeded(_ groups: [SourceFolderGroup]) {
        guard !didApplyDefaultCollapse, !groups.isEmpty else { return }
        didApplyDefaultCollapse = true
        // 不加动画：首次进入时整块目录树收一下，看起来更像卡顿而不是过渡。
        collapsedFolders = groups.reduce(into: Set<String>()) {
            $0.formUnion($1.defaultCollapsed)
        }
    }

    // MARK: - 页头主动作

    private var planButton: some View {
        let count = state.cleanupSelectedCount
        return Button {
            state.generateCleanupPlan()
        } label: {
            Label(count > 0 ? "清理 \(count) 个文件" : "生成清理计划", systemImage: "trash")
                .frame(minWidth: 104)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .fixedSize()
        .disabled(!state.canGenerateCleanupPlan)
        .help(count > 0
              ? "把这 \(count) 个勾选的文件移入回收站的计划；此时还没有碰过任何文件"
              : "先在网格里勾选要清理的文件")
    }

    // MARK: - 操作行

    /// 横向排不下时整体换成两行，而不是把某个控件压到只剩半截。
    private func toolRow(visible: [MediaItem]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                kindPicker.frame(width: 212)
                searchField
                sortPicker.frame(width: 148)
                Spacer(minLength: 8)
                selectionActions(visible: visible)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    kindPicker.frame(width: 212)
                    sortPicker.frame(width: 148)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    searchField
                    Spacer(minLength: 8)
                    selectionActions(visible: visible)
                }
            }
        }
    }

    private var kindPicker: some View {
        Picker("", selection: $state.mediaFilter.kind) {
            Text("全部 \(state.items.filter { $0.kind.isVisualMedia }.count)")
                .tag(MediaFilter.Kind.all)
            Text("图片 \(state.imageCount)").tag(MediaFilter.Kind.image)
            Text("视频 \(state.videoCount)").tag(MediaFilter.Kind.video)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索文件名 / 目录 / 设备", text: $state.mediaFilter.keyword)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !state.mediaFilter.keyword.isEmpty {
                Button {
                    state.mediaFilter.keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 208)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private var sortPicker: some View {
        Picker("", selection: $state.mediaFilter.sort) {
            ForEach(MediaFilter.Sort.allCases) { option in
                Text(option.displayName).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private func selectionActions(visible: [MediaItem]) -> some View {
        let allSelected = !visible.isEmpty && visible.allSatisfy { state.isCleanupSelected($0.id) }
        return HStack(spacing: 8) {
            Button(allSelected ? "取消选择" : "全选结果") {
                state.setCleanupSelection(!allSelected, itemIDs: visible.map { $0.id })
            }
            .controlSize(.regular)
            .disabled(visible.isEmpty)
            .help(allSelected
                  ? "取消当前筛选结果里所有文件的勾选"
                  : "勾选当前筛选结果里的 \(visible.count) 个文件")

            if state.cleanupSelectedCount > 0 {
                Button("清空勾选") { state.clearCleanupSelection() }
                    .controlSize(.regular)
            }
        }
        .fixedSize()
    }

    // MARK: - 摘要

    private var summaryRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 12)],
                  alignment: .leading, spacing: 12) {
            StatCard(title: "媒体总数",
                     value: "\(state.items.filter { $0.kind.isVisualMedia }.count)",
                     subtitle: "图片 \(state.imageCount) · 视频 \(state.videoCount)",
                     symbol: "photo.stack")
            StatCard(title: "已勾选清理",
                     value: "\(state.cleanupSelectedCount)",
                     subtitle: state.cleanupSelectedCount > 0
                         ? "预计释放 \(state.cleanupSelectedBytesLabel)"
                         : "点击缩略图右上角勾选",
                     symbol: "trash",
                     tint: state.cleanupSelectedCount > 0 ? Palette.danger : Palette.neutral)
            StatCard(title: "总体积",
                     value: ByteCountFormatter.string(fromByteCount: state.totalBytes, countStyle: .file),
                     subtitle: "全部扫描结果",
                     symbol: "internaldrive")
            StatCard(title: "重复项",
                     value: "\(state.dedupSummary.totalGroupCount)",
                     subtitle: "冗余 \(state.dedupSummary.redundantFileCount) 个文件",
                     symbol: "square.on.square",
                     tint: Palette.caution)
        }
    }

    // MARK: - 网格与来源目录

    private func gridArea(visible: [MediaItem],
                          roles: [UUID: AppState.DuplicateRole],
                          sourceGroups: [SourceFolderGroup]) -> some View {
        GeometryReader { geo in
            // 页边距左右各 22，先扣掉再算列数，否则最后一列会被挤出画布
            let layout = GridLayout(available: geo.size.width - 44)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 目录树与网格共用这一个滚动容器：再套一层 ScrollView 会出现
                    // 「滚到一半卡住、指针在哪个区域决定了滚谁」的混乱手感。
                    sourceFolderPanel(sourceGroups)

                    if visible.isEmpty {
                        emptyFilterState
                    } else {
                        LazyVGrid(columns: layout.columns, alignment: .leading, spacing: 14) {
                            ForEach(visible.prefix(visibleCount)) { item in
                                MediaTile(item: item,
                                          side: layout.side,
                                          isSelected: state.isCleanupSelected(item.id),
                                          role: roles[item.id],
                                          isExcludedFromOrganizing: state.isExcludedFromOrganizing(item.parentPath),
                                          onToggle: { state.toggleCleanupSelection(item.id) },
                                          onPreview: { openPreview(item, in: visible) },
                                          onReveal: { state.revealInFinder($0) },
                                          onOpen: { state.openInDefaultApp($0) })
                            }
                        }

                        if visible.count > visibleCount {
                            Button {
                                visibleCount += 120
                            } label: {
                                Label("继续加载（还有 \(visible.count - visibleCount) 个）",
                                      systemImage: "ellipsis.circle")
                            }
                            .controlSize(.regular)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 26)
            }
        }
    }

    // MARK: - 来源目录面板

    @ViewBuilder
    private func sourceFolderPanel(_ groups: [SourceFolderGroup]) -> some View {
        let subfolderCount = groups.reduce(0) { $0 + max(0, $1.folders.count - 1) }
        let excludedCount = state.excludedFromOrganizing.count
        // 折叠只对「有下级的目录」有意义；一个都没有时那两个按钮不该出现
        let parentsWithChildren = groups.reduce(into: Set<String>()) {
            $0.formUnion($1.foldersWithChildren)
        }
        let allCollapsed = !parentsWithChildren.isEmpty
            && collapsedFolders.isSuperset(of: parentsWithChildren)

        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // 头部刻意**不是**一个大 Button 里嵌几个小按钮 —— 那样嵌套的按钮
                // 点击会串到外层（点「全部恢复」可能连带把整块折起来）。
                // 这里拆成：左侧标题区一个按钮，右侧动作各自独立。
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) { showFolderTree.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: showFolderTree ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 10)
                            Image(systemName: "folder.on.circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.accent)
                            Text("来源目录")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("\(groups.count) 个来源 · \(subfolderCount) 个子目录")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showFolderTree ? "收起目录树" : "展开目录树")

                    Spacer(minLength: 8)

                    if showFolderTree && !parentsWithChildren.isEmpty {
                        Button(allCollapsed ? "全部展开" : "全部折叠") {
                            withAnimation(.easeInOut(duration: 0.12)) {
                                if allCollapsed {
                                    collapsedFolders.subtract(parentsWithChildren)
                                } else {
                                    collapsedFolders.formUnion(parentsWithChildren)
                                }
                            }
                        }
                        .controlSize(.small)
                        .help(allCollapsed ? "展开所有子目录" : "只留下每个目录的第一层")
                    }

                    if excludedCount > 0 {
                        TagChip(text: "已排除 \(excludedCount) 个不参与整理",
                                tint: Palette.caution, filled: false)
                            .fixedSize()
                        Button("全部恢复") {
                            state.excludedFromOrganizing.removeAll()
                            state.persistPreferences()
                        }
                        .controlSize(.small)
                        .help("清除所有「不参与整理」的勾选，全部目录重新参与归档")
                    }
                }

                if showFolderTree {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            folderGroupRows(group)
                        }
                    }
                    .padding(.top, 10)

                    Text("「不参与整理」只影响**归档**：这些目录里的文件不会按模板被移动或重命名；"
                         + "重复副本的清理、以及在这一页手动勾选的清理都不受影响。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
        }
    }

    @ViewBuilder
    private func folderGroupRows(_ group: SourceFolderGroup) -> some View {
        let withChildren = group.foldersWithChildren
        let childCounts = group.directChildCounts
        // 折叠后要显示的行由数据层的纯函数算（自检直接断言同一套逻辑）
        let rows = group.visibleFolders(collapsed: collapsedFolders)
        let rootCollapsed = collapsedFolders.contains(group.root)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                collapseChevron(path: group.root,
                                hasChildren: withChildren.contains(group.root),
                                isCollapsed: rootCollapsed)
                Image(systemName: "externaldrive")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(group.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text(displayPath(group.root))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(group.root)
                Spacer(minLength: 8)
                if rootCollapsed, group.folders.count > 1 {
                    Text("已收起 \(group.folders.count - 1) 个子目录")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Text("\(group.totalFileCount) 个文件")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)

            ForEach(rows.filter { $0.depth > 0 }) { folder in
                folderRow(folder,
                          hasChildren: withChildren.contains(folder.path),
                          childCount: childCounts[folder.path] ?? 0)
            }
        }
        .padding(.bottom, 4)
    }

    /// 折叠箭头。
    ///
    /// 叶子目录也画一个**等宽的透明占位**：不占位的话，有下级和没下级的行会左右错开一格，
    /// 看起来像缩进算错了，而缩进在这棵树里是有含义的（它表示层级）。
    @ViewBuilder
    private func collapseChevron(path: String, hasChildren: Bool, isCollapsed: Bool) -> some View {
        if hasChildren {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { toggleCollapse(path) }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "展开子目录" : "收起子目录")
        } else {
            Color.clear.frame(width: 14, height: 14)
        }
    }

    private func toggleCollapse(_ path: String) {
        if collapsedFolders.contains(path) {
            collapsedFolders.remove(path)
        } else {
            collapsedFolders.insert(path)
        }
    }

    private func folderRow(_ folder: SourceSubfolder,
                           hasChildren: Bool,
                           childCount: Int) -> some View {
        // 「自己勾的」与「随上级被排除」是两种状态：前者能取消，后者要先去取消上级。
        // 界面上必须分开呈现，否则用户会对着一个点不动的开关反复点。
        let excluded = folder.isExcluded || folder.isInherited
        let isCollapsed = collapsedFolders.contains(folder.path)
        return HStack(spacing: 8) {
            Spacer(minLength: 0).frame(width: CGFloat(max(0, folder.depth - 1)) * 14)
            collapseChevron(path: folder.path, hasChildren: hasChildren, isCollapsed: isCollapsed)
            Image(systemName: excluded ? "folder.badge.minus" : "folder")
                .font(.system(size: 11))
                .foregroundStyle(folder.isExcluded ? Palette.caution : .secondary)
                .frame(width: 14)
            Text(folder.name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(excluded ? .secondary : .primary)
                .help(folder.path)
            if isCollapsed, childCount > 0 {
                // 收起之后光看名字不知道里面有多少，给个数
                Text("已收起 \(childCount) 个子目录")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)

            if folder.fileCount > 0 {
                Text("\(folder.fileCount)")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.secondary)
                    .help("直接放在这个目录里的文件数")
            }
            if folder.totalFileCount > folder.fileCount {
                Text("(共 \(folder.totalFileCount))")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .help("含子目录在内的文件总数")
            }

            if folder.isInherited {
                TagChip(text: "随上级", tint: Palette.caution, filled: false)
                    .fixedSize()
                    .help("上级目录已被排除，这个目录一并生效；取消上级的勾选即可恢复")
            }

            Toggle("", isOn: Binding(
                get: { excluded },
                set: { _ in state.toggleOrganizingExclusion(folder.path) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(folder.isInherited)
                .help(excluded
                      ? "已排除：这个目录（含子目录）不参与按规则归档"
                      : "打开后：这个目录（含子目录）不参与按规则归档")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private var emptyFilterState: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Palette.accent.opacity(0.55))
            Text("当前筛选下没有文件")
                .font(.system(size: 14, weight: .semibold))
            Button("清除筛选条件") {
                state.mediaFilter = MediaFilter()
            }
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - 放大预览

    /// 传入的是**当前筛选后的整份列表**，所以在浮层里可以用方向键一路翻下去，
    /// 连着判断几十张照片时不必退回网格再点开下一张。
    @ViewBuilder
    private func previewOverlay(visible: [MediaItem]) -> some View {
        if previewIndex != nil, !visible.isEmpty {
            MediaPreviewOverlay(
                items: visible,
                index: Binding(get: { previewIndex ?? 0 },
                               set: { previewIndex = $0 }),
                keepIDs: state.cleanupSelection,
                marking: .cleanup,
                onToggleKeep: { state.toggleCleanupSelection($0) },
                onReveal: { state.revealInFinder($0) },
                onOpen: { state.openInDefaultApp($0) },
                onClose: { previewIndex = nil })
            .transition(.opacity)
        }
    }

    private func openPreview(_ item: MediaItem, in visible: [MediaItem]) {
        previewIndex = visible.firstIndex { $0.id == item.id } ?? 0
    }
}

// MARK: - 网格尺寸

/// 缩略图网格的列数与边长。
///
/// 不用 `GridItem(.adaptive)`：它算出的列宽会在 min 与 max 之间浮动，
/// 而缩略图是**固定边长的正方形** —— 两者对不上时，每列右侧都会留一条
/// 宽度不等（且随窗口变化）的缝，看上去像是排布坏了。
/// 这里先按可用宽度定出整数列数，再反推精确边长，让格子刚好铺满一行。
private struct GridLayout {
    var columns: [GridItem]
    var side: CGFloat

    init(available: CGFloat, minSide: CGFloat = 132, spacing: CGFloat = 12) {
        let safeWidth = max(minSide, available)
        let count = max(2, Int((safeWidth + spacing) / (minSide + spacing)))
        let side = floor((safeWidth - CGFloat(count - 1) * spacing) / CGFloat(count))
        self.side = side
        self.columns = Array(repeating: GridItem(.fixed(side), spacing: spacing), count: count)
    }
}

// MARK: - 单个文件格

private struct MediaTile: View {
    var item: MediaItem
    var side: CGFloat
    var isSelected: Bool
    var role: AppState.DuplicateRole?
    /// 所在目录被勾选「不参与整理」。放在缩略图上当角标，而不是占掉下方那行 ——
    /// 那行要留给重复角色，两者是不同维度的信息，缺哪个都会让人做错判断。
    var isExcludedFromOrganizing: Bool
    var onToggle: () -> Void
    var onPreview: () -> Void
    var onReveal: (String) -> Void
    var onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topTrailing) {
                ThumbnailView(url: item.url,
                              kind: item.kind,
                              size: side,
                              // 勾选表示「要清理」，用红色描边；绿色在重复项页表示「保留」，
                              // 同一个动作的相反含义不能共用同一种颜色。
                              borderTint: isSelected ? Palette.danger : nil)
                selectBadge.padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                if isExcludedFromOrganizing { excludedBadge.padding(6) }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .onTapGesture { onPreview() }
            .contextMenu {
                Button(isSelected ? "取消勾选" : "勾选清理") { onToggle() }
                Divider()
                Button("放大预览") { onPreview() }
                Button("在访达中显示") { onReveal(item.path) }
                Button("用默认程序打开") { onOpen(item.path) }
            }

            Text(item.fileName)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.path)

            Text("\(item.resolutionLabel) · \(item.fileSizeLabel)")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            roleLine
        }
        .frame(width: side, alignment: .leading)
    }

    private var excludedBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "folder.badge.minus")
                .font(.system(size: 9, weight: .semibold))
            Text("不整理")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Palette.caution.opacity(0.92)))
        .help("所在目录已勾选「不参与整理」：不会按模板被移动或重命名（清理不受影响）")
    }

    /// 右上角的勾选按钮。
    ///
    /// 底色固定用半透明黑而不是系统色：缩略图可能是任意亮度，
    /// 只有自带底色圈才能在任何画面上都看得清。
    private var selectBadge: some View {
        Button(action: onToggle) {
            ZStack {
                Circle()
                    .fill(isSelected ? Palette.danger : Color.black.opacity(0.34))
                Circle()
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 21, height: 21)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isSelected ? "取消勾选" : "勾选后生成计划时会移入系统回收站")
    }

    /// 第三行固定存在（要么是重复角色，要么是拍摄日期）——
    /// 时有时无会让网格里每一格高度不同，排出来参差不齐。
    @ViewBuilder
    private var roleLine: some View {
        if let role {
            TagChip(text: roleLabel(role),
                    tint: role.isRedundant || role.disposition == .discardAll
                        ? Palette.danger : Palette.positive,
                    filled: false)
                .fixedSize()
                .help(roleHelp(role))
        } else {
            Text(captureStamp)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    private var captureStamp: String {
        guard let date = item.capturedAt ?? item.fileModified else { return "时间未识别" }
        return DateFormat.displayShort(date)
    }

    private func roleLabel(_ role: AppState.DuplicateRole) -> String {
        switch role.disposition {
        case .discardAll: return "整组清理"
        case .keepAll: return "整组保留"
        case .bySelection: return role.isRedundant ? "冗余副本" : "保留项"
        }
    }

    private func roleHelp(_ role: AppState.DuplicateRole) -> String {
        switch role.disposition {
        case .discardAll:
            return "所在重复组被设为「都不保留」：生成重复项清理计划时，该组全部成员都会移入回收站"
        case .keepAll:
            return "所在重复组被设为「保留整组」：该组不产生任何清理操作"
        case .bySelection:
            return role.isRedundant
                ? "在重复项页被判为冗余副本；这里的勾选是独立的，不会改变那边的决定"
                : "在重复项页被标记为保留项；这里的勾选是独立的，不会改变那边的决定"
        }
    }
}
