import SwiftUI
import AppKit

/// 侧栏里的来源目录树。
///
/// 为什么放在侧栏而不是「所有媒体」页的内容区：它是**全局的排除设置** ——
/// 影响的是整轮归档，不是某一页的浏览筛选。挂在侧栏上，在任何页面都能看到、随时能改，
/// 也把内容区让给缩略图网格。
///
/// 侧栏只有 200 多 pt 宽，所以这里比内容区里那版紧凑得多：缩进 9pt/层、11pt 字号、
/// 只显示末级目录名（完整路径进 tooltip）、勾选用原生**小方框**而不是开关 ——
/// 方框本来就表示「多选几项」，而且比开关省地方。
struct SourceFolderTreeView: View {
    @ObservedObject var state: AppState

    /// 仅供离屏渲染注入折叠集合，跳过「默认收起第一层以下」那一步。
    /// 作用与 `AllMediaView.injectedCollapsed` 相同：让「默认折叠有没有真的画出来」
    /// 能在离屏渲染里被比对出来 —— 少几行在多目录的树上肉眼分辨不出。
    var injectedCollapsed: Set<String>? = nil

    /// 整块面板是否展开（区别于单个目录的折叠）
    @State private var expanded = true
    @State private var collapsed: Set<String> = []
    @State private var didApplyDefault = false

    var body: some View {
        let groups = state.sourceFolderGroups

        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header(groups)
                if expanded {
                    ForEach(groups) { group in
                        groupRows(group)
                    }
                    footnote
                }
            }
            // 用 `task(id:)` 而不是 `onAppear`：用户多半是先扫描、再切页面，
            // 而侧栏一直在那儿 —— 只挂 onAppear 会漏掉「出现时还没有数据」那种顺序，
            // 表现成「默认折叠时灵时不灵」。
            .task(id: state.items.count) {
                if let injected = injectedCollapsed {
                    collapsed = injected
                    didApplyDefault = true
                    return
                }
                guard !didApplyDefault else { return }
                didApplyDefault = true
                collapsed = groups.reduce(into: Set<String>()) {
                    $0.formUnion($1.defaultCollapsed)
                }
            }
        }
    }

    // MARK: - 头部

    private func header(_ groups: [SourceFolderGroup]) -> some View {
        let parents = groups.reduce(into: Set<String>()) { $0.formUnion($1.foldersWithChildren) }
        let allCollapsed = !parents.isEmpty && collapsed.isSuperset(of: parents)
        let excludedCount = state.excludedFromOrganizing.count

        return HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 9)
                    Image(systemName: "folder.on.circle")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                    Text("来源目录")
                        .font(.system(size: 11, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "收起来源目录" : "展开来源目录")

            Spacer(minLength: 4)

            // 侧栏太窄放不下文字按钮，两个动作用图标 + tooltip
            if expanded && !parents.isEmpty {
                iconButton(allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                           help: allCollapsed ? "展开所有子目录" : "收起所有子目录") {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        if allCollapsed {
                            collapsed.subtract(parents)
                        } else {
                            collapsed.formUnion(parents)
                        }
                    }
                }
            }
            if excludedCount > 0 {
                iconButton("arrow.uturn.backward",
                           help: "全部恢复：清掉 \(excludedCount) 个「不参与整理」的勾选") {
                    state.excludedFromOrganizing.removeAll()
                    state.persistPreferences()
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.top, 6)
        .padding(.bottom, 3)
    }

    private func iconButton(_ symbol: String,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .frame(width: 17, height: 17)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var footnote: some View {
        Text("勾选 = 该目录（含子目录）不参与按规则归档；重复副本与本页手动勾选的清理不受影响。")
            .font(.system(size: 9.5))
            .foregroundStyle(Palette.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.top, 5)
            .padding(.bottom, 8)
    }

    // MARK: - 目录行

    @ViewBuilder
    private func groupRows(_ group: SourceFolderGroup) -> some View {
        let withChildren = group.foldersWithChildren
        let rows = group.visibleFolders(collapsed: collapsed)
        let rootCollapsed = collapsed.contains(group.root)
        let rootExcluded = state.excludedFromOrganizing.contains(PathTools.normalized(group.root))

        HStack(spacing: 4) {
            Spacer(minLength: 0).frame(width: 12)
            chevron(group.root,
                    hasChildren: withChildren.contains(group.root),
                    isCollapsed: rootCollapsed)
            Image(systemName: "externaldrive")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Text(group.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(group.root)
            Spacer(minLength: 4)
            countLabel("\(group.totalFileCount)", collapsedHint: rootCollapsed && group.folders.count > 1)
            exclusionCheckbox(path: group.root, isOn: rootExcluded, inherited: false)
        }
        .padding(.trailing, 12)
        .padding(.vertical, 2)

        ForEach(rows.filter { $0.depth > 0 }) { folder in
            folderRow(folder, hasChildren: withChildren.contains(folder.path))
        }
    }

    private func folderRow(_ folder: SourceSubfolder, hasChildren: Bool) -> some View {
        let excluded = folder.isExcluded || folder.isInherited
        let isCollapsed = collapsed.contains(folder.path)
        return HStack(spacing: 4) {
            // 与来源根行对齐：12 + 每层 9pt 缩进
            Spacer(minLength: 0).frame(width: 12 + CGFloat(max(0, folder.depth - 1)) * 9)
            chevron(folder.path, hasChildren: hasChildren, isCollapsed: isCollapsed)
            Image(systemName: excluded ? "folder.badge.minus" : "folder")
                .font(.system(size: 10))
                .foregroundStyle(folder.isExcluded ? Palette.caution : .secondary)
                .frame(width: 12)
            Text(folder.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(excluded ? .secondary : .primary)
                .help(folder.path)
            Spacer(minLength: 4)
            // 收起时显示「含子目录的总数」，展开时显示「直接文件数」—— 两种状态下
            // 那个数字的含义不同，不区分的话会让人以为数字算错了。
            countLabel(isCollapsed ? "\(folder.totalFileCount)" : "\(folder.fileCount)",
                       collapsedHint: isCollapsed && folder.totalFileCount > folder.fileCount)
            exclusionCheckbox(path: folder.path, isOn: excluded, inherited: folder.isInherited)
        }
        .padding(.trailing, 12)
        .padding(.vertical, 1.5)
    }

    @ViewBuilder
    private func countLabel(_ text: String, collapsedHint: Bool) -> some View {
        if text != "0" {
            Text(collapsedHint ? "(\(text))" : text)
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(.tertiary)
                .help(collapsedHint ? "含子目录在内的文件总数" : "直接放在这个目录里的文件数")
        }
    }

    @ViewBuilder
    private func chevron(_ path: String, hasChildren: Bool, isCollapsed: Bool) -> some View {
        if hasChildren {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { toggleCollapse(path) }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "展开子目录" : "收起子目录")
        } else {
            // 叶子目录留等宽占位，否则有没有下级的行会左右错开，看起来像缩进错了
            Color.clear.frame(width: 12, height: 12)
        }
    }

    /// 「不参与整理」的勾选框。
    ///
    /// 用原生方框而不是开关：侧栏空间紧，而且方框本就是「逐项多选」的语义。
    /// 因上级被排除时显示为已勾但不可点 —— 用户若分不清「自己勾的」和「继承来的」，
    /// 会对着一个点不动的东西反复点。
    private func exclusionCheckbox(path: String, isOn: Bool, inherited: Bool) -> some View {
        Toggle("", isOn: Binding(
            get: { isOn },
            set: { _ in state.toggleOrganizingExclusion(path) }))
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(inherited)
            .help(inherited
                  ? "随上级目录一起排除；取消上级的勾选即可恢复"
                  : (isOn
                     ? "已排除：这个目录（含子目录）不参与按规则归档"
                     : "勾选后：这个目录（含子目录）不参与按规则归档（清理不受影响）"))
    }

    private func toggleCollapse(_ path: String) {
        if collapsed.contains(path) {
            collapsed.remove(path)
        } else {
            collapsed.insert(path)
        }
    }
}
