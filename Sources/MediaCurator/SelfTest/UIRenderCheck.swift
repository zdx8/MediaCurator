import Foundation
import AppKit
import SwiftUI
import CryptoKit

/// 显式把工作放到**真正的**主线程上执行。
///
/// 实测在「命令行进程 + dispatchMain()」这种启动方式下，`@MainActor` 标注与
/// `MainActor.run` 都不保证落在主线程上（诊断输出里 `Thread.isMainThread` 恒为 false），
/// 而 AppKit 的 `NSWindow` 有硬性检查。所以这里不依赖 MainActor 的执行器映射，
/// 直接用 `DispatchQueue.main.sync` 把闭包交给主队列执行。
enum MainThread {
    @discardableResult
    static func run<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }
}

/// 界面层自检。
///
/// 无法依赖屏幕截图（需要「屏幕录制」权限，且截到的是屏幕而不是应用自身状态），
/// 因此走两条可程序化判定的路径：
/// 1. **离屏渲染** —— 用 NSHostingView 把真实视图画进位图，统计墨迹比例并比对哈希。
///    同一视图换个数据渲染两次若字节完全相同，说明内容根本没画出来。
/// 2. **直接调用缩略图管线** —— 确认解码链路真的能产出图像，而不是永远停在占位状态。
@MainActor
enum UIRenderCheck {

    struct RenderResult {
        var name: String
        var width: Int
        var height: Int
        var luminance: Double
        var inkRatio: Double
        var digest: String
        /// 画面中属于「强调色族」（蓝 > 绿 > 红且够亮）的采样点数量 ——
        /// 用来证明强调色真的被画到了画面上，而不是只存在于常量里
        var accentLikeCount: Int = 0
        /// 顶部区域最左/最右若干像素列上的墨迹比例。
        ///
        /// 存在的理由：SwiftUI 遇到放不下的内容只会**默默压缩或越界绘制**，
        /// 不报错、不崩溃，界面上就是某个按钮缺了半截（「生成清理计划」出过这个问题）。
        /// 页面本身有 22pt 横向留白，所以正常的顶部区域在最边缘几列应当是纯背景；
        /// 一旦边缘出现墨迹，就说明有控件被挤到了画布外面。
        var leadingEdgeInk: Double = 0
        var trailingEdgeInk: Double = 0
        /// 画面里出现过的色相桶数（12 等分）。用来判定「照片有没有真的画上去」——
        /// 空占位符也有墨迹，光看墨迹比例区分不出「画了内容」和「画了照片」。
        var hueBucketCount: Int = 0
        /// 整幅高度的左右边缘墨迹（`leadingEdgeInk` 只量顶部那条带）。
        ///
        /// 滚动区**内部的**内容一旦比卡片宽，结果是被 ScrollView 裁在边界上，
        /// 而不是画到画布外面 —— 顶部那条带量不到它，只能整幅量。
        var fullLeadingEdgeInk: Double = 0
        var fullTrailingEdgeInk: Double = 0
    }

    /// 把主色解析成具体分量。显式指定 sRGB —— SwiftUI 的 `Color(red:green:blue:)`
    /// 就按 sRGB 解释，若用 `deviceRGB` 会跟随显示器描述文件变化，断言就不稳定了。
    static let accentComponents: (r: Double, g: Double, b: Double) = components(of: Palette.accent)

    /// Logo 品牌色。它与界面强调色是两套令牌，各有各的回归断言。
    static let brandComponents: (r: Double, g: Double, b: Double) = components(of: Palette.brand)

    private static func components(of color: Color) -> (r: Double, g: Double, b: Double) {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return (0, 0, 0) }
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    private final class Checker {
        var passed = 0
        var failed = 0
        var failures: [String] = []

        func check(_ condition: Bool, _ label: String) {
            if condition {
                passed += 1
                print("  ✓ \(label)")
            } else {
                failed += 1
                failures.append(label)
                print("  ✗ \(label)")
            }
        }

        /// 相等断言。失败时把两个值都打出来 —— 只写「不一致」的断言
        /// 在真的坏掉时帮不上忙，还得回去加打印重跑一遍。
        func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
            check(actual == expected, actual == expected
                  ? label
                  : "\(label)（实际 \(actual)，期望 \(expected)）")
        }
    }

    static func run(fixtureRoot: URL, shotsDirectory: URL? = nil) async -> Int32 {
        print("影像管家 · 界面自检")
        print(String(repeating: "─", count: 64))

        let checker = Checker()
        // 与闭环自检同理：把日志目录隔离开。否则「操作日志」页会列出用户真实的历史记录，
        // 渲染结果随用户数据变化，自检就不再可重复，也会把测试数据混进真实数据里。
        JournalStore.overrideDirectory = fixtureRoot.appendingPathComponent("journals",
                                                                           isDirectory: true)
        // 与日志目录同理：自检驱动的动作会顺手持久化偏好，不能让它写进用户的真实配置
        AppState.suppressPreferenceWrites = true
        defer { AppState.suppressPreferenceWrites = false }
        // 渲染必须落在真正的主线程上，AppKit 对此有硬性检查。
        // 这条断言同时守住了 HeadlessRunner 的启动方式（不能用 dispatchMain()）。
        checker.check(probeMainThread(), "离屏渲染在主线程上执行")

        // ---------- 准备真实数据 ----------
        let state = AppState()
        state.settings.sourceFolders = [fixtureRoot.path]
        state.settings.useHashCache = false
        state.settings.minimumFileSize = 0
        await state.performScan()

        checker.check(!state.items.isEmpty, "扫描得到 \(state.items.count) 个文件")
        checker.check(!state.groups.isEmpty, "发现 \(state.groups.count) 组重复")
        checker.check(state.dedupSummary.reclaimableBytes > 0, "统计出可释放空间")

        // 生成一份计划，让「执行计划」「整理规则」页有内容可渲染
        state.rule.destinationRoot = fixtureRoot.deletingLastPathComponent()
            .appendingPathComponent("organized").path
        state.rule.folderTemplate = "{yyyy}/{MM}/{MM-dd}/{camera}"
        state.rule.renameTemplate = "{datetime}_{orig}"
        state.filter.cleanRedundantDuplicates = false
        let built = PlanBuilder.build(items: state.items,
                                      groups: state.groups,
                                      rule: state.rule,
                                      filter: state.filter)
        state.operations = built.operations
        state.planSummary = built.summary
        state.planWarnings = built.warnings
        state.folderCounts = built.folderCounts

        checker.check(!state.operations.isEmpty, "计划包含 \(state.operations.count) 行")
        checker.check(!state.planWarnings.isEmpty, "计划给出了 \(state.planWarnings.count) 条提示")

        // 「操作日志」页在有记录时才画得出内容。这里塞一份内存里的会话记录，
        // 避免它渲染空状态、被误判成「页面没画东西」。
        state.sessions = [makeSyntheticSession(from: state)]

        // ---------- 离屏渲染各页面 ----------
        print("\n▸ 页面渲染")
        let canvas = CGSize(width: 1120, height: 740)
        var results: [RenderResult] = []

        for page in AppPage.allCases {
            state.page = page
            guard let result = await render(name: page.title, size: canvas,
                                      saveTo: shotsDirectory?.appendingPathComponent("\(page.step)-\(page.title).png"),
                                      content: {
                AnyView(pageView(for: page, state: state))
            }) else {
                checker.check(false, "渲染「\(page.title)」页")
                continue
            }
            results.append(result)
            print(String(format: "  · %@：%d×%d  亮度 %.3f  墨迹 %.4f  指纹 %@",
                         result.name, result.width, result.height,
                         result.luminance, result.inkRatio,
                         String(result.digest.prefix(12))))
            checker.check(result.inkRatio > 0.01,
                          "「\(page.title)」页有实际绘制内容（墨迹 \(String(format: "%.4f", result.inkRatio))）")
        }

        // 各页内容必须不同 —— 否则说明导航没有真正切换视图
        let digests = Set(results.map { $0.digest })
        checker.check(digests.count == results.count,
                      "\(AppPage.allCases.count) 个页面渲染结果互不相同（\(digests.count)/\(results.count)）")

        // 色相桶数在这里只打印、**不做断言**。
        //
        // 自检素材是多频正弦图案，本身颜色就单调，网格页与纯控件页的桶数都落在 3–4 之间，
        // 比不出稳定差异 —— 拿噪声当判据只会让自检红绿随机，比没有更糟
        // （第一版就是这么翻的：加了折叠箭头之后 4 vs 3 直接翻转）。
        //
        // 真正的把关在出图环节：那边用的是照片素材，实测网格页 10/12 桶、控件页 1–4 桶，
        // 阈值定在 6 桶，差距足够大，判据才立得住。
        if let grid = results.first(where: { $0.name == AppPage.allMedia.title }),
           let form = results.first(where: { $0.name == AppPage.scan.title }) {
            print("  · 色相桶数（仅诊断）：所有媒体 \(grid.hueBucketCount)/12 ｜ 扫描 \(form.hueBucketCount)/12")
        }

        // ---------- 「所有媒体」页：筛选、排序与勾选 ----------
        // 这一页把「看什么」和「清什么」拆成了两件事，断言也分两组：
        // 筛选只影响显示、勾选只影响计划范围，两者不能互相串味 ——
        // 串了就会出现「为了找一张照片改了筛选，结果生成计划时范围也变了」。
        print("\n▸ 「所有媒体」页的筛选与勾选")
        let mediaTotal = state.items.filter { $0.kind.isVisualMedia }.count
        checker.equal(state.visibleMediaItems.count, mediaTotal,
                      "默认筛选下显示全部 \(mediaTotal) 个媒体文件")

        state.mediaFilter.kind = .video
        checker.check(state.visibleMediaItems.allSatisfy { $0.kind == .video },
                      "切到「视频」后结果里只剩视频")
        checker.equal(state.visibleMediaItems.count, state.videoCount,
                      "视频筛选的条数与统计一致")
        state.mediaFilter.kind = .image
        checker.check(state.visibleMediaItems.allSatisfy { $0.kind == .image },
                      "切到「图片」后结果里只剩图片")

        state.mediaFilter = MediaFilter()
        if let sample = state.visibleMediaItems.first {
            state.mediaFilter.keyword = sample.fileName
            checker.equal(state.visibleMediaItems.count, 1,
                          "用完整文件名搜索只命中一条")
            checker.check(state.visibleMediaItems.first?.id == sample.id,
                          "命中的正是那个文件")
        }
        state.mediaFilter = MediaFilter()

        // 排序必须**稳定**：连拍的拍摄时间完全相同，只按时间排的话顺序由底层数组决定，
        // 界面每次重算都会换位置 —— 网格自己跳动。两次取样必须逐项相同。
        checker.equal(state.visibleMediaItems.map { $0.id },
                      state.visibleMediaItems.map { $0.id },
                      "排序稳定（连续两次取样逐项相同）")

        // 勾选只影响计划范围：不改文件、也不改变任何重复组的决定。
        // 用字符串指纹而不是元组数组比较 —— Swift 的元组不自动遵循 `Equatable` 协议，
        // 而断言辅助函数要求 `T: Equatable`。
        let groupsBefore = state.groups.map {
            "\($0.id)/\($0.disposition.rawValue)/\($0.keepIDs.count)"
        }
        let pickTwo = Array(state.visibleMediaItems.prefix(2))
        state.setCleanupSelection(true, itemIDs: pickTwo.map { $0.id })
        checker.equal(state.cleanupSelectedCount, 2, "勾选两个后计数为 2")
        checker.equal(state.cleanupSelectedBytes,
                      pickTwo.reduce(Int64(0)) { $0 + $1.fileSize },
                      "勾选体积等于这两个文件之和")
        checker.equal(state.groups.map {
            "\($0.id)/\($0.disposition.rawValue)/\($0.keepIDs.count)"
        }, groupsBefore,
                      "「所有媒体」页的勾选不改变任何重复组的决定")

        state.generateCleanupPlan()
        checker.equal(state.operations.count, 2, "生成的计划行数等于勾选数")
        checker.check(state.operations.allSatisfy { $0.kind == .trash },
                      "手动清理计划里只有「移入回收站」操作")
        checker.equal(Set(state.operations.map { $0.sourcePath }),
                      Set(pickTwo.map { $0.path }),
                      "计划覆盖的路径集合正是勾选的那些")

        state.toggleCleanupSelection(pickTwo[0].id)
        checker.equal(state.cleanupSelectedCount, 1, "再点一次即取消勾选")
        state.clearCleanupSelection()
        checker.equal(state.cleanupSelectedCount, 0, "清空勾选后计数归零")
        checker.check(state.cleanupSelectedItems.isEmpty, "待清理集合随之为空")

        // ---------- 来源目录树与「不参与整理」 ----------
        print("\n▸ 来源目录树与「不参与整理」")

        // 路径边界是这条功能最容易出错的地方：裸 `hasPrefix` 会把 /照片备份
        // 当成 /照片 的子目录，一整个不相关的目录就被静默排除，而界面上完全看不出来。
        state.excludedFromOrganizing = ["/tmp/MediaCuratorTreeProbe/照片"]
        checker.check(state.isExcludedFromOrganizing("/tmp/MediaCuratorTreeProbe/照片/2023"),
                      "子目录继承上级的排除")
        checker.check(state.isExcludedFromOrganizing("/tmp/MediaCuratorTreeProbe/照片"),
                      "目录自身的排除命中自己")
        checker.check(!state.isExcludedFromOrganizing("/tmp/MediaCuratorTreeProbe/照片备份"),
                      "前缀相似但不同级的目录不受影响（照片 vs 照片备份）")
        checker.check(!state.isExcludedFromOrganizing("/tmp/MediaCuratorTreeProbe"),
                      "上级目录不受下级排除影响")
        checker.check(PlanBuilder.isUnder("/a/b/c", anyOf: ["/a/b"]), "isUnder 认定子路径")
        checker.check(!PlanBuilder.isUnder("/a/bc", anyOf: ["/a/b"]),
                      "isUnder 不把 /a/bc 当成 /a/b 的子路径")
        state.excludedFromOrganizing = []

        // 目录树结构。自检素材是平铺的，这里临时造一份带层级的 items 来验证 ——
        // 只改内存里的 parentPath，文件路径本身保持真实，后续计划生成仍跑得通。
        let probeRoot = "/tmp/MediaCuratorTreeProbe/照片库"
        let probeDirs = [probeRoot + "/2023/2023-05", probeRoot + "/2023/2023-05",
                         probeRoot + "/备份", probeRoot]
        var probeItems = Array(state.items.prefix(4))
        for index in probeItems.indices {
            probeItems[index].sourceRoot = probeRoot
            probeItems[index].parentPath = probeDirs[index]
        }
        let savedItemsForTree = state.items
        state.items = probeItems
        let tree = state.sourceFolderGroups
        checker.equal(tree.count, 1, "一名来源目录产出一棵树")
        if let node = tree.first {
            checker.equal(node.folders.count, 4,
                          "目录数含补齐的中间层（根 / 2023 / 2023-05 / 备份）")
            let byName = Dictionary(uniqueKeysWithValues: node.folders.map { ($0.name, $0) })
            checker.equal(byName["2023"]?.depth, 1, "中间层 2023 的层级为 1")
            checker.equal(byName["2023-05"]?.depth, 2, "深层目录 2023-05 的层级为 2")
            checker.equal(byName["2023"]?.fileCount, 0, "中间层本身没有直接文件")
            checker.equal(byName["2023"]?.totalFileCount, 2, "中间层的总数把子目录算进来")
            checker.equal(byName["备份"]?.totalFileCount, 1, "叶子目录的总数等于它的直接文件数")
            checker.equal(node.totalFileCount, 4, "来源根的总数等于全部探针文件数")
            checker.equal(node.folders.reduce(0) { $0 + $1.fileCount }, 4,
                          "各目录直接文件数之和等于文件总数（不重不漏）")

            // 层级必须连续：中间层没补齐的话缩进会算错，父目录也找不到
            let paths = Set(node.folders.map { $0.path })
            let broken = node.folders.filter { folder in
                guard folder.depth > 0 else { return false }
                return !paths.contains((folder.path as NSString).deletingLastPathComponent)
            }
            checker.check(broken.isEmpty,
                          broken.isEmpty ? "每个目录的上级都在树里（层级连续）"
                                         : "有 \(broken.count) 个目录找不到上级")

            // 继承：排除 2023 之后，2023-05 要显示成「随上级」而不是「自己勾的」——
            // 两者在界面上一个能点、一个点不动，分不清用户会反复点那个开关
            state.excludedFromOrganizing = [probeRoot + "/2023"]
            let inherited = state.sourceFolderGroups.first?
                .folders.first { $0.name == "2023-05" }
            checker.check(inherited?.isInherited == true, "子目录标记为「随上级」")
            checker.check(inherited?.isExcluded == false, "子目录本身没有被单独勾选")

            // 勾选上级要清掉下级的单独勾选，否则会出现「上级没勾、下级还勾着」的矛盾状态
            state.excludedFromOrganizing = [probeRoot + "/2023/2023-05"]
            state.toggleOrganizingExclusion(probeRoot + "/2023")
            checker.equal(state.excludedFromOrganizing, [probeRoot + "/2023"],
                          "勾选上级时清理掉下级的单独勾选")
            state.toggleOrganizingExclusion(probeRoot + "/2023")
            checker.check(state.excludedFromOrganizing.isEmpty, "再点一次即取消排除")

            // 折叠：收起一个目录后它的后代全部消失，展开又原样回来。
            // 这条性质**靠看截图验不出来** —— 少几行和多几行在缩略图尺寸下很难分辨，
            // 所以折叠可见性算在数据层（`SourceFolderGroup.visibleFolders`），由自检直接断言。
            let allRows = node.visibleFolders(collapsed: [])
            checker.equal(allRows.count, node.folders.count, "不折叠时显示全部目录行")

            let midPath = probeRoot + "/2023"
            let sibling = probeRoot + "/备份"
            let midFolded = node.visibleFolders(collapsed: [midPath])
            checker.equal(midFolded.count, allRows.count - 1, "收起 2023 后正好少一行（2023-05）")
            checker.check(midFolded.contains { $0.path == midPath }, "被收起的目录本身仍然显示")
            checker.check(!midFolded.contains { $0.path.hasPrefix(midPath + "/") },
                          "收起后它的子目录不再出现")
            checker.check(midFolded.contains { $0.path == sibling },
                          "收起一个目录不影响它的兄弟目录")

            let rootFolded = node.visibleFolders(collapsed: [probeRoot])
            checker.equal(rootFolded.count, 1, "收起来源根后只剩根一行")
            checker.equal(rootFolded.first?.path, probeRoot, "剩下的那行正是来源根")

            let twoFolded = node.visibleFolders(collapsed: [midPath, sibling])
            checker.equal(twoFolded.count, 3,
                          "同时收起两个目录：根 / 2023 / 备份 三行，2023-05 被隐藏")

            checker.equal(node.visibleFolders(collapsed: []).count, allRows.count,
                          "折叠集合清空后又回到全部显示")

            // 有下级的判断必须准确：叶子目录上画折叠箭头，点下去毫无反应
            checker.check(node.foldersWithChildren.contains(probeRoot), "来源根被认为有下级")
            checker.check(node.foldersWithChildren.contains(midPath), "2023 被认为有下级")
            checker.check(!node.foldersWithChildren.contains(sibling), "备份是叶子，不应有折叠箭头")
            checker.equal(node.directChildCounts[probeRoot], 2, "来源根的直接下级是 2 个")
            checker.equal(node.directChildCounts[midPath], 1, "2023 的直接下级是 1 个")
            checker.equal(node.directChildCounts[sibling], nil, "叶子目录没有下级计数")

            // 侧栏目录树的**默认折叠必须真的画出来**。渲染两张（默认 vs 全展开），
            // 指纹相同就说明默认折叠没接上 —— 目录树少几行、多几行，人看截图分辨不出来，
            // 而它正是最容易「代码写了但没生效」的地方。
            // 必须用探针数据渲染：自检素材是平铺的，没有可折叠的层级，两张会必然相同。
            let treeSize = CGSize(width: 240, height: 460)
            if let treeDefault = await render(name: "目录树-默认", size: treeSize, content: {
                AnyView(SourceFolderTreeView(state: state))
            }), let treeExpanded = await render(name: "目录树-全展开", size: treeSize, content: {
                AnyView(SourceFolderTreeView(state: state, injectedCollapsed: []))
            }) {
                checker.check(treeDefault.digest != treeExpanded.digest,
                              "侧栏来源目录树的默认折叠真的生效（默认态与全展开态渲染不同）")
                checker.check(treeDefault.inkRatio > 0.01,
                              String(format: "侧栏目录树有实际绘制内容（墨迹 %.4f）",
                                     treeDefault.inkRatio))
            } else {
                checker.check(false, "侧栏来源目录树渲染失败")
            }

            // 侧栏最窄可以拖到 214pt，目录树在那里不能把内容挤到画布外 ——
            // SwiftUI 对「放不下」只会默默压缩或越界绘制，不报错也不崩溃，
            // 界面上就是某个名字被裁掉半截。用边缘墨迹判：页面有留白，最边上几列应当是背景。
            if let narrowTree = await render(name: "目录树-最窄",
                                             size: CGSize(width: 214, height: 460),
                                             content: {
                AnyView(SourceFolderTreeView(state: state))
            }) {
                print(String(format: "  · 最窄侧栏目录树的边缘墨迹：左 %.4f / 右 %.4f",
                             narrowTree.leadingEdgeInk, narrowTree.trailingEdgeInk))
                checker.check(narrowTree.leadingEdgeInk < 0.02 && narrowTree.trailingEdgeInk < 0.02,
                              "214pt 宽的侧栏里目录树没有越界绘制")
            } else {
                checker.check(false, "最窄宽度下的目录树渲染失败")
            }

            // 首次进入的默认折叠：只露到第一层。
            // 层级深 / 子目录多的时候，默认全展开会把目录树铺满整屏、把网格挤下去 ——
            // 但全收起又只剩一行，用户不知道里面有什么。所以只收「第一层及以下有下级」的。
            let defaults = node.defaultCollapsed
            checker.equal(defaults, [midPath], "默认收起第一层以下有下级的目录（这里只有 2023）")
            checker.check(!defaults.contains(probeRoot),
                          "来源根不在默认收起之列（否则进来只看得见一行）")
            checker.check(!defaults.contains(sibling), "叶子目录不会被列为收起")

            let defaultRows = node.visibleFolders(collapsed: defaults)
            checker.equal(defaultRows.count, 3, "默认状态下显示根 / 2023 / 备份 三行")
            checker.check(defaultRows.contains { $0.path == probeRoot }, "默认显示来源根")
            checker.check(defaultRows.contains { $0.path == sibling }, "默认显示第一层的子目录")
            checker.check(!defaultRows.contains { $0.path == probeRoot + "/2023/2023-05" },
                          "默认不显示第二层（随 2023 收起）")
        }
        state.excludedFromOrganizing = []
        state.items = savedItemsForTree

        // 排除只作用于**归档**。这条边界要钉死在断言里：以后有人「顺手」把排除接到
        // 清理路径上，用户就会在没被告知的情况下少清一批文件（或者反过来多清）。
        let savedFilterForExclusion = state.filter
        let savedGroupsForExclusion = state.groups
        state.filter.archiveFiles = true
        state.filter.onlyRedundantDuplicates = false
        state.filter.cleanRedundantDuplicates = true
        let baseline = PlanBuilder.build(items: state.items, groups: state.groups,
                                         rule: state.rule, filter: state.filter)
        let sourceRootForExclusion = state.items.first?.sourceRoot ?? ""
        let excludedPlan = PlanBuilder.build(items: state.items, groups: state.groups,
                                             rule: state.rule, filter: state.filter,
                                             excludedFromOrganizing: [sourceRootForExclusion])
        checker.equal(excludedPlan.summary.moveCount + excludedPlan.summary.renameCount, 0,
                      "整棵来源目录被排除后不产生任何归档操作")
        checker.equal(excludedPlan.summary.trashCount, baseline.summary.trashCount,
                      "排除目录不影响清理操作的数量（只作用于归档）")
        checker.check(excludedPlan.excludedCount > 0,
                      "记录了 \(excludedPlan.excludedCount) 个被排除的文件")
        checker.check(excludedPlan.warnings.contains { $0.contains("不参与整理") },
                      "计划提示了「不参与整理」的影响范围与边界")
        checker.check(excludedPlan.warnings.contains { $0.contains("清理不受影响") },
                      "提示里写明了清理仍会生效")
        state.filter = savedFilterForExclusion
        state.groups = savedGroupsForExclusion

        // ---------- 数据变化必须反映到画面上 ----------
        print("\n▸ 数据驱动的渲染差异")
        state.page = .duplicates
        guard let before = await render(name: "重复项-原始", size: canvas, content: {
            AnyView(DuplicatesView(state: state))
        }) else {
            checker.check(false, "重复项页首次渲染")
            return 1
        }

        // 造一个差异：把重复组全部隐藏（模拟没有重复项）
        let savedGroups = state.groups
        state.groups = []
        guard let after = await render(name: "重复项-空", size: canvas, content: {
            AnyView(DuplicatesView(state: state))
        }) else {
            checker.check(false, "重复项页空态渲染")
            return 1
        }
        state.groups = savedGroups

        checker.check(before.digest != after.digest,
                      "重复项页随数据变化而重绘（有数据 vs 无数据字节不同）")
        print(String(format: "  · 有数据：墨迹 %.4f / 空态：墨迹 %.4f", before.inkRatio, after.inkRatio))

        // 两种整组决定都必须有可见的视觉差异，否则用户点了之后看不出发生了什么。
        // 同时守住「顶部计数随分组变化」—— 那正是它出过问题的地方。
        state.groups = savedGroups
        if !state.groups.isEmpty {
            // 用有序数组而不是字典：下面要按下标断言计数序列，
            // 字典的遍历顺序不稳定，会让断言随机失败。
            let variants: [(label: String, disposition: GroupDisposition, shot: String?)] = [
                ("按勾选", .bySelection, nil),
                ("保留整组", .keepAll, "2-重复项-整组保留.png"),
                ("都不保留", .discardAll, "2-重复项-都不保留.png")
            ]
            var rendered: [String: RenderResult] = [:]
            var chipCounts: [Int] = []
            for variant in variants {
                state.groups[0].disposition = variant.disposition
                // 顶部计数读的就是界面上那枚标签用的字段
                chipCounts.append(variant.disposition == .discardAll
                                  ? state.dedupSummary.discardedWholeGroupCount
                                  : state.dedupSummary.keptWholeGroupCount)
                if let result = await render(name: "整组决定-\(variant.label)", size: canvas,
                                       saveTo: variant.shot.map {
                                           shotsDirectory?.appendingPathComponent($0)
                                       } ?? nil,
                                       content: {
                    AnyView(DuplicatesView(state: state))
                }) {
                    rendered[variant.label] = result
                } else {
                    checker.check(false, "「\(variant.label)」状态渲染")
                }
            }
            state.groups[0].disposition = .bySelection

            checker.equal(rendered.count, variants.count, "三种整组决定都能渲染")
            if let plain = rendered["按勾选"], let kept = rendered["保留整组"] {
                checker.check(plain.digest != kept.digest, "「保留整组」会改变分组卡片的呈现")
            }
            if let plain = rendered["按勾选"], let discarded = rendered["都不保留"] {
                checker.check(plain.digest != discarded.digest, "「都不保留」会改变分组卡片的呈现")
            }
            for (label, result) in rendered {
                checker.check(result.inkRatio > 0.01,
                              String(format: "「%@」状态可正常绘制（墨迹 %.4f）", label, result.inkRatio))
            }

            print("  · 顶部整组计数序列（按勾选/保留整组/都不保留）：\(chipCounts)")
            checker.equal(chipCounts, [0, 1, 1],
                          "顶部整组计数随决定切换即时更新，不读陈旧缓存")
            checker.equal(state.dedupSummary.keptWholeGroupCount, 0,
                          "切回按勾选后整组保留计数归零")
            checker.equal(state.dedupSummary.discardedWholeGroupCount, 0,
                          "切回按勾选后都不保留计数归零")
        }

        // ---------- 摘要与分组始终同步 ----------
        // 摘要曾经是手工维护的缓存：谁改了分组谁负责刷新。
        // 「执行计划后剔除失效分组」那条路径漏了刷新，顶部「整组保留 N 组」
        // 与摘要卡就会继续显示已经不存在（或已被清理）的分组 ——
        // 数字看着只是差一点，用户却无从判断该信哪个。
        // 现在由 `AppState.groups` 的属性观察器保证，这几条断言把该约束固定下来：
        // 一旦有人去掉观察器、或绕过它直接写摘要，这里会立刻变红。
        state.groups = savedGroups
        checker.equal(state.dedupSummary.totalGroupCount, savedGroups.count,
                      "赋值分组后摘要自动算出组数（\(savedGroups.count) 组）")
        if !state.groups.isEmpty {
            state.groups[0].disposition = .keepAll
            checker.equal(state.dedupSummary.keptWholeGroupCount, 1,
                          "改一个分组的整组决定，摘要立即跟上")
            state.groups[0].disposition = .discardAll
            checker.equal(state.dedupSummary.keptWholeGroupCount, 0,
                          "切换整组决定后旧计数被清掉")
            checker.equal(state.dedupSummary.discardedWholeGroupCount, 1,
                          "切换整组决定后新计数出现")

            // 执行计划后剔除失效分组：分组变少，摘要必须跟着变少
            let keptGroupCount = savedGroups.filter { $0.kind == .exact }.count
            state.groups = savedGroups.filter { $0.kind == .exact }
            checker.equal(state.dedupSummary.totalGroupCount, keptGroupCount,
                          "剔除分组后摘要不再引用已消失的分组")
            checker.equal(state.dedupSummary.discardedWholeGroupCount, 0,
                          "被剔除的组不再计入整组决定")
        }
        state.groups = []
        checker.equal(state.dedupSummary.totalGroupCount, 0, "清空分组后摘要归零")
        checker.equal(state.dedupSummary.discardedWholeGroupCount, 0,
                      "清空分组后整组决定的计数一并归零")
        // 复原：后面的放大预览 / 视频预览还要用这些分组
        state.groups = savedGroups
        state.groups[0].disposition = .bySelection

        // 放大预览浮层。同步渲染下异步解码来不及完成，所以注入一张已解好的图，
        // 否则导出的预览图只会是一个加载指示器，也验不出「图确实画上去了」。
        if let group = state.groups.first {
            let members = group.memberIDs.compactMap { state.itemsByID[$0] }
            if let first = members.first {
                let injected = MainThread.run { () -> NSImage? in
                    guard let cg = PerceptualHash.downsampledImage(url: first.url, maxPixel: 1200) else {
                        return nil
                    }
                    return ThumbnailProvider.nsImage(from: cg)
                }
                let overlay = await render(name: "放大预览", size: canvas,
                                     saveTo: shotsDirectory?.appendingPathComponent("6-放大预览.png"),
                                     content: {
                    AnyView(MediaPreviewOverlay(items: members,
                                                index: .constant(0),
                                                keepIDs: group.keepIDs,
                                                disposition: group.disposition,
                                                onToggleKeep: { _ in },
                                                onReveal: { _ in },
                                                onOpen: { _ in },
                                                onClose: {},
                                                injectedImage: injected))
                })
                if let overlay {
                    checker.check(overlay.inkRatio > 0.01,
                                  String(format: "放大预览有实际绘制内容（墨迹 %.4f）", overlay.inkRatio))
                    checker.check(overlay.luminance < 0.45,
                                  String(format: "放大预览使用深色遮罩（亮度 %.3f）", overlay.luminance))
                } else {
                    checker.check(false, "放大预览渲染")
                }
            }
        }

        // 视频预览。这里守的是一条曾经真实发生过的闪退：
        // SwiftUI 的 `VideoPlayer` 声明在私有框架 `_AVKit_SwiftUI` 里，编译器只会自动
        // 链接那个私有框架、不会链接 AVKit 本身；而它内部是 `AVPlayerView`（属 AVKit）
        // 的子类，于是运行时找不到父类，一点视频缩略图就 trap。
        // `AVPlayerView` 能否解析出来，就是「AVKit 到底有没有被链进来」的判据。
        checker.check(NSClassFromString("AVPlayerView") != nil,
                      "AVKit 已链接（AVPlayerView 类可解析）")
        checker.check(NSClassFromString("AVPlayer") != nil,
                      "AVFoundation 已链接（AVPlayer 类可解析）")

        if let videoGroup = state.groups.first(where: { $0.kind == .similarVideo }),
           let video = videoGroup.memberIDs.compactMap({ state.itemsByID[$0] }).first {
            let videoMembers = videoGroup.memberIDs.compactMap { state.itemsByID[$0] }
            let videoOverlay = await render(name: "视频预览", size: canvas,
                                      saveTo: shotsDirectory?.appendingPathComponent("7-视频预览.png"),
                                      content: {
                AnyView(MediaPreviewOverlay(items: videoMembers,
                                            index: .constant(0),
                                            keepIDs: videoGroup.keepIDs,
                                            disposition: videoGroup.disposition,
                                            onToggleKeep: { _ in },
                                            onReveal: { _ in },
                                            onOpen: { _ in },
                                            onClose: {}))
            })
            checker.check(videoOverlay != nil, "视频预览可以构造并渲染（不闪退）")
            if let videoOverlay {
                checker.check(videoOverlay.luminance < 0.45,
                              String(format: "视频预览使用深色遮罩（亮度 %.3f）", videoOverlay.luminance))
                print("  · 视频样本：\(video.fileName)")
            }
        } else {
            print("  · 本次素材没有视频组，跳过视频预览渲染")
        }

        // ---------- 主题 + 品牌配色 ----------
        // 侧栏 + 内容区的整体渲染：侧栏选中行是一大块实心主色，
        // 既能验主题亮度，也能稳定地证明主色确实被大面积画了出来。
        print("\n▸ 主题与品牌配色")
        var lightComposite: RenderResult?

        let schemes: [(scheme: ColorScheme, label: String, file: String)] = [
            (.light, "浅色", "0-总览-浅色.png"),
            (.dark, "深色", "0-总览-深色.png")
        ]
        for item in schemes {
            guard let result = await render(name: item.label,
                                      size: CGSize(width: 1360, height: 860),
                                      colorScheme: item.scheme,
                                      saveTo: shotsDirectory?.appendingPathComponent(item.file),
                                      content: {
                AnyView(HStack(spacing: 0) {
                    SidebarView(state: state)
                    DuplicatesView(state: state)
                })
            }) else {
                checker.check(false, "\(item.label)主题渲染")
                continue
            }
            if item.scheme == .light { lightComposite = result }

            let looksLight = result.luminance > 0.5
            checker.check((item.scheme == .light) == looksLight,
                          item.scheme == .light
                            ? String(format: "浅色主题整体偏亮（亮度 %.3f）", result.luminance)
                            : String(format: "深色主题整体偏暗（亮度 %.3f）", result.luminance))
        }

        let accent = accentComponents
        print(String(format: "  强调色 RGB(%.3f, %.3f, %.3f)", accent.r, accent.g, accent.b))
        checker.check(accent.b > accent.r + 0.30 && accent.b > accent.g + 0.15,
                      "强调色为蓝色（蓝通道显著高于红与绿）")
        // 「浅蓝」是两个字：既要是蓝，也要够亮，不能滑成深藏青
        checker.check(accent.b > 0.70 && accent.r > 0.10,
                      String(format: "强调色偏亮，是浅蓝而非深蓝（蓝 %.2f / 红 %.2f）",
                             accent.b, accent.r))

        let brand = brandComponents
        print(String(format: "  Logo 品牌色 RGB(%.3f, %.3f, %.3f)", brand.r, brand.g, brand.b))
        checker.check(brand.b > brand.r + 0.30 && brand.b > brand.g + 0.15 && brand.b > 0.70,
                      "Logo 底色为浅蓝（与强调色同族）")
        // 两者目前同色，但仍分属不同令牌；这条例行检查防止将来只改了一边
        checker.check(abs(brand.r - accent.r) < 0.001
                      && abs(brand.g - accent.g) < 0.001
                      && abs(brand.b - accent.b) < 0.001,
                      "Logo 底色与界面强调色一致")

        if let composite = lightComposite {
            print("  · 属于强调色族的采样点：\(composite.accentLikeCount)")
            checker.check(composite.accentLikeCount > 60,
                          "强调色被大面积使用（\(composite.accentLikeCount) 个采样点）")
        } else {
            checker.check(false, "取不到浅色主题的渲染结果")
        }

        // ---------- 缩略图管线 ----------
        print("\n▸ 缩略图管线")
        let sampleImages = state.items.filter { $0.kind == .image }.prefix(3)
        for item in sampleImages {
            let image = await ThumbnailProvider.shared.thumbnail(for: item.url, maxPixel: 160)
            checker.check(image != nil, "图片缩略图：\(item.fileName)")
        }
        if let video = state.items.first(where: { $0.kind == .video }) {
            let image = await ThumbnailProvider.shared.thumbnail(for: video.url, maxPixel: 160)
            checker.check(image != nil, "视频首帧缩略图：\(video.fileName)")
        }

        // 缓存命中路径要能复用同一个对象，而不是每次重新解码
        if let item = state.items.first(where: { $0.kind == .image }) {
            _ = await ThumbnailProvider.shared.thumbnail(for: item.url, maxPixel: 160)
            let start = Date()
            _ = await ThumbnailProvider.shared.thumbnail(for: item.url, maxPixel: 160)
            let elapsed = Date().timeIntervalSince(start)
            checker.check(elapsed < 0.05,
                          String(format: "缩略图缓存命中（第二次耗时 %.4f 秒）", elapsed))
        }

        // ---------- 「检查重复媒体」开关 ----------
        // 关掉它应该只跳过比对：文件照样入库、「所有媒体」页照常有内容，
        // 而分组与摘要必须一并清零 —— 每次扫描的 `MediaItem.id` 都是新的，
        // 留着上一轮的分组只会得到一堆点不开的卡片。
        // 放在所有断言的最后：重新扫描会让全部 id 换新，之前的断言都不能再用。
        print("\n▸ 检查重复媒体的开关")
        let savedCheckDuplicates = state.settings.checkDuplicates
        let itemsBefore = state.items.count
        state.settings.checkDuplicates = false
        await state.performScan()
        checker.equal(state.items.count, itemsBefore,
                      "关掉查重后文件照样全部入库（\(state.items.count) 个）")
        checker.check(state.groups.isEmpty, "关掉查重后不产生任何分组")
        checker.equal(state.dedupSummary.totalGroupCount, 0, "关掉查重后摘要里的组数归零")
        checker.equal(state.dedupSummary.reclaimableBytes, 0, "关掉查重后可释放空间归零")
        checker.check(!state.visibleMediaItems.isEmpty, "关掉查重后「所有媒体」页仍有内容")

        state.settings.checkDuplicates = savedCheckDuplicates
        await state.performScan()
        checker.check(!state.groups.isEmpty,
                      "重新打开查重并再扫一次后分组恢复（\(state.groups.count) 组）")
        checker.check(state.dedupSummary.reclaimableBytes > 0, "恢复查重后可释放空间重新统计出来")

        print("\n" + String(repeating: "─", count: 64))
        print("界面自检结论：\(checker.failed == 0 ? "全部通过（\(checker.passed) 项）" : "\(checker.passed) 项通过，\(checker.failed) 项失败")")
        if let shotsDirectory {
            print("页面渲染图已导出到：\(shotsDirectory.path)")
        }
        for failure in checker.failures { print("  · \(failure)") }
        return checker.failed == 0 ? 0 : 1
    }

    /// 不读 `Thread.isMainThread` 的 async 上下文警告：包一层同步函数即可。
    private static func probeMainThread() -> Bool {
        MainThread.run { Thread.isMainThread }
    }

    /// 造一份内存里的执行记录，让「操作日志」页有真实内容可渲染。
    /// 不写盘：这是一次纯界面验证，不应该往用户的日志目录里塞测试数据。
    private static func makeSyntheticSession(from state: AppState) -> JournalSession {        var entries: [JournalEntry] = []
        let samples = state.items.prefix(6)
        for (index, item) in samples.enumerated() {
            let destination = (state.rule.destinationRoot as NSString)
                .appendingPathComponent("2024/05/2024-05-10")
                .appending("/" + item.fileName)
            entries.append(JournalEntry(kind: index % 3 == 2 ? .trash : .move,
                                        sourcePath: item.path,
                                        destinationPath: index % 3 == 2 ? nil : destination,
                                        result: .success,
                                        message: index % 3 == 2 ? "重复项冗余副本" : "按拍摄时间归档",
                                        fileSize: item.fileSize,
                                        trashPath: index % 3 == 2 ? "/tmp/Trash/" + item.fileName : nil))
        }
        if let first = state.items.first {
            entries.append(JournalEntry(kind: .move,
                                        sourcePath: first.path,
                                        destinationPath: "/tmp/已存在/\(first.fileName)",
                                        result: .failed,
                                        message: "目标已存在同名文件，未执行",
                                        fileSize: first.fileSize))
        }

        let stamps = entries.map { $0.timestamp }
        return JournalSession(id: "ui-check-synthetic",
                              startedAt: stamps.min() ?? Date(),
                              finishedAt: stamps.max(),
                              entries: entries,
                              filePath: "/tmp/影像管家界面自检.jsonl")
    }

    // MARK: - 官网截图

    /// 渲染官网要用的成品截图。
    ///
    /// 与 `run` 的区别是**不做断言**：它只负责把画面导出来，素材也换成
    /// `DemoFixtureBuilder` 那一套。自检素材是多频正弦图案 —— 平滑、可缩放、
    /// 便于判定，但画面上就是抽象色块，摆进官网首屏等于告诉访客这是个测试程序。
    ///
    /// 输出是屏幕缩放比下的原始像素（本机 2x，即点数 × 2），
    /// 缩到网页尺寸由 `Scripts/make_site_shots.sh` 负责。
    static func renderDemoShots(fixtureRoot: URL, shotsDirectory: URL) async -> Int32 {
        print("影像管家 · 官网截图")
        print(String(repeating: "─", count: 64))

        JournalStore.overrideDirectory = fixtureRoot.appendingPathComponent("journals",
                                                                           isDirectory: true)
        AppState.suppressPreferenceWrites = true
        defer { AppState.suppressPreferenceWrites = false }

        let state = AppState()
        state.settings.sourceFolders = [fixtureRoot.path]
        state.settings.useHashCache = false
        state.settings.minimumFileSize = 0
        await state.performScan()

        guard !state.groups.isEmpty else {
            print("演示素材没有产生重复组，无法出图")
            return 1
        }
        print("素材：\(state.items.count) 个文件，\(state.groups.count) 组重复")
        for group in state.groups {
            let names = group.memberIDs.compactMap { state.itemsByID[$0]?.fileName }
            print("  · \(group.kind.displayName)（\(group.memberCount) 个）：\(names.joined(separator: " / "))")
        }

        try? FileManager.default.createDirectory(at: shotsDirectory, withIntermediateDirectories: true)

        // 先把缩略图挨个解一遍。
        //
        // 解码跑在 `ThumbnailProvider` 这个 actor 上，是**串行**的；视图里的 `.task`
        // 只能一张张排队。渲染的等待窗口内排不完，于是先画出来的页面里靠后的缩略图
        // 还是空的（视频那两张反而先出来）。先解一遍，渲染时就全是缓存命中。
        //
        // 缓存键是「路径 + 像素数」，所以**每个页面用到的尺寸都要预热** ——
        // 少预热一档，那个页面整片都是空占位符，而截图本身照样能导出，看不出错在哪。
        //   224 = `DuplicateGroupCard` 里 size 112 的缩略图
        //   280 = `AllMediaView` 网格在 1400 宽画布下的边长（约 140）的 2 倍
        let thumbPixelSizes: [CGFloat] = [224, 280]
        var warmed = 0
        for pixel in thumbPixelSizes {
            for item in state.items {
                if await ThumbnailProvider.shared.thumbnail(for: item.url, maxPixel: pixel) != nil {
                    warmed += 1
                }
            }
        }
        print("缩略图预热：\(warmed) 张（\(thumbPixelSizes.count) 档尺寸 × \(state.items.count) 个文件）")

        // 「整理规则」与「执行计划」两页要有内容可画
        state.rule.destinationRoot = fixtureRoot.deletingLastPathComponent()
            .appendingPathComponent("已整理").path
        state.rule.folderTemplate = "{yyyy}/{MM}/{yyyy-MM-dd}"
        state.rule.renameTemplate = "{datetime}_{orig}"
        state.filter.cleanRedundantDuplicates = false
        let built = PlanBuilder.build(items: state.items,
                                      groups: state.groups,
                                      rule: state.rule,
                                      filter: state.filter)
        state.operations = built.operations
        state.planSummary = built.summary
        state.planWarnings = built.warnings
        state.folderCounts = built.folderCounts
        state.sessions = [makeSyntheticSession(from: state)]

        var failures: [String] = []

        @discardableResult
        func save(_ file: String,
                  size: CGSize,
                  scheme: ColorScheme? = .light,
                  content: () -> AnyView) async -> RenderResult? {
            let result = await render(name: file,
                                      size: size,
                                      colorScheme: scheme,
                                      saveTo: shotsDirectory.appendingPathComponent("\(file).png"),
                                      settle: 0.6,
                                      content: content)
            if let result {
                // 带上色相桶数：出图时一眼能看出「这张图里到底有没有照片」——
                // 缩略图没解码出来的话，这个数会掉到 1–2，而文件大小、导出成功与否都正常。
                print(String(format: "  ✓ %@：%d×%d  色相 %d/12", file, result.width, result.height,
                             result.hueBucketCount))
            } else {
                failures.append(file)
                print("  ✗ \(file)")
            }
            return result
        }

        // 整机总览：侧栏 + 重复项页，官网首屏用
        let overview = CGSize(width: 1360, height: 860)
        await save("overview-light", size: overview, scheme: .light) {
            AnyView(HStack(spacing: 0) {
                SidebarView(state: state)
                DuplicatesView(state: state)
            })
        }
        await save("overview-dark", size: overview, scheme: .dark) {
            AnyView(HStack(spacing: 0) {
                SidebarView(state: state)
                DuplicatesView(state: state)
            })
        }

        // 各功能页。文件名用 `page.shotName`（不含序号）—— 序号会随导航插入新页面
        // 整体后移，截图名跟着漂移就会让 `make_site_shots.sh` 里那张对照表失配。
        let canvas = CGSize(width: 1400, height: 925)
        for page in AppPage.allCases {
            // 「所有媒体」页出一张**带勾选**的（见下），这里跳过默认态：
            // 两张图内容几乎一样，都留着只会让仓库和官网各多背半兆。
            if page == .allMedia { continue }
            state.page = page
            await save(page.shotName, size: canvas) {
                AnyView(pageView(for: page, state: state))
            }
        }

        // 「所有媒体」页的勾选态：官网需要能看出「勾上要清理的文件」是什么样。
        // 只勾前面几个，保留大片未勾选的格子 —— 全勾会让人误以为这页就是「一键全清」。
        //
        // 带上侧栏一起出图：来源目录树现在挂在侧栏上，不带侧栏就看不到这个能力，
        // 而它恰恰是这一页附近最需要展示的东西。尺寸与首屏总览保持一致。
        state.page = .allMedia
        let pickedForShot = state.visibleMediaItems.prefix(4).map { $0.id }
        state.setCleanupSelection(true, itemIDs: Array(pickedForShot))
        let allMediaShot = await save("all-media-selected", size: overview) {
            AnyView(HStack(spacing: 0) {
                SidebarView(state: state)
                AllMediaView(state: state)
            })
        }

        // 官网截图的验收标准只有一条：**画面里得真有照片**。
        // 缩略图没解码出来时截图照样导出成功、文件大小也正常，但整片网格是灰色占位符 ——
        // 这是后果最直接、又最难自己发现的一种失败（人得逐张点开看才会注意到）。
        // 用色相桶数兜住：相机照片的色相通常在 8 桶以上，纯灰占位符只有 1–2 桶。
        if let shot = allMediaShot, shot.hueBucketCount < 6 {
            failures.append("all-media-selected 只画出 \(shot.hueBucketCount)/12 个色相桶，疑似缩略图未解码")
        }
        state.clearCleanupSelection()

        // 重复项的两种整组决定：各出一张，官网要能看出区别
        state.page = .duplicates
        let dispositions: [(String, GroupDisposition)] = [
            ("duplicates-keep-whole", .keepAll),
            ("duplicates-discard-all", .discardAll)
        ]
        for (file, disposition) in dispositions {
            state.groups[0].disposition = disposition
            await save(file, size: canvas) {
                AnyView(DuplicatesView(state: state))
            }
        }
        state.groups[0].disposition = .bySelection

        // 放大预览（图片）
        if let group = state.groups.first(where: { $0.kind != .similarVideo }),
           let first = group.memberIDs.compactMap({ state.itemsByID[$0] }).first {
            let members = group.memberIDs.compactMap { state.itemsByID[$0] }
            let injected = MainThread.run { () -> NSImage? in
                guard let cg = PerceptualHash.downsampledImage(url: first.url, maxPixel: 1400) else {
                    return nil
                }
                return ThumbnailProvider.nsImage(from: cg)
            }
            await save("preview-image", size: canvas) {
                AnyView(MediaPreviewOverlay(items: members,
                                            index: .constant(0),
                                            keepIDs: group.keepIDs,
                                            disposition: group.disposition,
                                            onToggleKeep: { _ in },
                                            onReveal: { _ in },
                                            onOpen: { _ in },
                                            onClose: {},
                                            injectedImage: injected))
            }
        }

        // 放大预览（视频）
        if let videoGroup = state.groups.first(where: { $0.kind == .similarVideo }) {
            let members = videoGroup.memberIDs.compactMap { state.itemsByID[$0] }
            await save("preview-video", size: canvas) {
                AnyView(MediaPreviewOverlay(items: members,
                                            index: .constant(0),
                                            keepIDs: videoGroup.keepIDs,
                                            disposition: videoGroup.disposition,
                                            onToggleKeep: { _ in },
                                            onReveal: { _ in },
                                            onOpen: { _ in },
                                            onClose: {}))
            }
        }

        print(String(repeating: "─", count: 64))
        print(failures.isEmpty
              ? "截图导出完成：\(shotsDirectory.path)"
              : "有 \(failures.count) 张渲染失败：\(failures.joined(separator: "、"))")
        return failures.isEmpty ? 0 : 1
    }

    @ViewBuilder
    private static func pageView(for page: AppPage, state: AppState) -> some View {
        switch page {
        case .scan: ScanView(state: state)
        case .allMedia: AllMediaView(state: state)
        case .duplicates: DuplicatesView(state: state)
        case .organize: OrganizeView(state: state)
        case .plan: PlanView(state: state)
        case .journal: JournalView(state: state)
        }
    }

    // MARK: - 窄宽度渲染

    /// 窄窗口下的重复项页渲染。
    ///
    /// 存在的理由：「整组保留」这类提示文字曾经在缩窄窗口后被压扁 / 被裁掉，
    /// 而固定 1120 的画布永远复现不出来。窗口最小宽度 1180、侧栏占 260，
    /// 所以内容区实际最窄只有约 920 —— 这里就按真实可达的宽度逐档渲染导出，
    /// 让「窄窗口长什么样」变成可以复核的实物，而不是靠肉眼在运行时碰运气。
    static func runWidthSweep(fixtureRoot: URL, shotsDirectory: URL,
                              widths: [CGFloat]) async -> Int32 {
        print("影像管家 · 窄宽度渲染")
        print(String(repeating: "─", count: 64))
        JournalStore.overrideDirectory = fixtureRoot.appendingPathComponent("journals",
                                                                            isDirectory: true)
        // 自检会真的扫描并设置好源目录，若落进真实的 UserDefaults，
        // 用户下次打开就会发现自己的扫描目录被换成了临时素材目录。
        AppState.suppressPreferenceWrites = true
        defer { AppState.suppressPreferenceWrites = false }

        let state = AppState()
        state.settings.sourceFolders = [fixtureRoot.path]
        state.settings.useHashCache = false
        state.settings.minimumFileSize = 0
        await state.performScan()

        guard !state.groups.isEmpty else {
            print("没有重复组，无法渲染")
            return 1
        }
        print("样本：\(state.groups.count) 组重复")

        var failures = 0
        let variants: [(label: String, disposition: GroupDisposition)] = [
            ("按勾选", .bySelection),
            ("保留整组", .keepAll),
            ("都不保留", .discardAll)
        ]

        // 判据自证：先故意渲染一个宽度远超画布的画面，边缘检测**必须**报警。
        // 否则「没有越界」可能只是因为检测函数永远返回 0 —— 本项目已经吃过一次
        // 「防线完全失效却全绿」的亏（见离屏渲染的字节行宽问题）。
        if let overflow = await render(name: "越界对照",
                                 size: CGSize(width: 300, height: 200),
                                 content: {
            AnyView(Color.red.frame(width: 900, height: 120))
        }) {
            print(String(format: "  · 越界对照：顶部带 %.5f / %.5f，整幅 %.5f / %.5f",
                         overflow.leadingEdgeInk, overflow.trailingEdgeInk,
                         overflow.fullLeadingEdgeInk, overflow.fullTrailingEdgeInk))
            // 两条都要自证：整幅那个判据是「页面级」检查唯一的依据，
            // 它要是永远返回 0，下面的「没有顶到边界」就等于什么都没验。
            if overflow.trailingEdgeInk > 0.0005 && overflow.fullTrailingEdgeInk > 0.0005 {
                print("  ✓ 边缘检测有效（顶部带与整幅都抓到了构造的越界画面）")
            } else {
                print("  ✗ 边缘检测失效：构造的越界画面没被抓到，下面的「无越界」结论不可信")
                failures += 1
            }
        } else {
            print("  ✗ 越界对照渲染失败")
            failures += 1
        }

        for width in widths {
            for variant in variants {
                state.groups[0].disposition = variant.disposition
                let name = "w\(Int(width))-\(variant.label)"
                let result = await render(name: name,
                                    size: CGSize(width: width, height: 740),
                                    saveTo: shotsDirectory.appendingPathComponent("\(name).png"),
                                    content: {
                    AnyView(DuplicatesView(state: state))
                })
                guard let result else {
                    print("  ✗ \(name)：渲染失败")
                    failures += 1
                    continue
                }
                // 顶部区域左右边缘不该有内容 —— 有就说明有控件被挤出了画布
                let clipped = max(result.leadingEdgeInk, result.trailingEdgeInk)
                let mark = clipped > 0.0005 ? "✗ 越界" : "✓"
                print(String(format: "  %@ %@：墨迹 %.4f  边缘 %.5f / %.5f",
                             mark, name, result.inkRatio,
                             result.leadingEdgeInk, result.trailingEdgeInk))
                if clipped > 0.0005 { failures += 1 }
            }
            state.resetKeepRecommendations()
        }
        state.groups[0].disposition = .bySelection

        // ---------- 页面级：内容不能顶到裁剪边界 ----------
        //
        // 选项区在滚动区域**内部**。某一行一旦比卡片宽，SwiftUI 不报任何错，
        // 结果是被 ScrollView 裁在边界上 —— 画布外的边缘检测（只量顶部那条带）看不见它，
        // 而在真实窗口里就表现为「右边有个控件被切了一半」。
        //
        // 判据取**相对值**：竖直滚动条就贴着右边缘，绝对墨迹会被它抬高，
        // 只有比同页宽画布多出来的那部分才是真被裁掉的内容 —— 宽画布下按定义不会越界。
        print("\n▸ 窄画布下的选项区（整幅边缘墨迹，与 1400 宽同页对比）")
        let pageCases: [(name: String, view: (AppState) -> AnyView)] = [
            ("扫描页", { AnyView(ScanView(state: $0)) }),
            ("整理规则页", { AnyView(OrganizeView(state: $0)) })
        ]
        for page in pageCases {
            guard let wide = await render(name: "wide-\(page.name)",
                                          size: CGSize(width: 1400, height: 1100),
                                          content: { page.view(state) }) else {
                print("  ✗ \(page.name)：宽画布渲染失败")
                failures += 1
                continue
            }
            // 844 = 最小窗口 1180 − 侧栏 260 − 页面留白 44 − 卡片内边距 32
            for narrowWidth in [844.0, 920.0] {
                guard let narrow = await render(name: "narrow-\(page.name)-\(Int(narrowWidth))",
                                                size: CGSize(width: narrowWidth, height: 1100),
                                                content: { page.view(state) }) else {
                    print("  ✗ \(page.name) @\(Int(narrowWidth))：渲染失败")
                    failures += 1
                    continue
                }
                let extraLeading = narrow.fullLeadingEdgeInk - wide.fullLeadingEdgeInk
                let extraTrailing = narrow.fullTrailingEdgeInk - wide.fullTrailingEdgeInk
                let overflow = max(extraLeading, extraTrailing) > 0.002
                print(String(format: "  %@ %@ @%.0f：边缘 %.5f / %.5f（比宽画布多 %.5f / %.5f）",
                             overflow ? "✗ 顶到边界" : "✓", page.name, narrowWidth,
                             narrow.fullLeadingEdgeInk, narrow.fullTrailingEdgeInk,
                             extraLeading, extraTrailing))
                if overflow { failures += 1 }
            }
        }

        print(String(repeating: "─", count: 64))
        print(failures == 0
              ? "窄宽度渲染全部通过（\(widths.count) 档宽度 × \(variants.count) 种状态，顶部区域均无越界）"
              : "窄宽度渲染有 \(failures) 项越界或失败")
        print("渲染图已导出到：\(shotsDirectory.path)")
        return failures == 0 ? 0 : 1
    }

    /// 把视图挂进一个**永不显示**的无边框窗口再截图 —— 只建 NSHostingView 不给窗口，
    /// 像 NavigationSplitView / ScrollView 这类容器量不到尺寸，布局不会完整解析。
    ///
    /// `async` 不是为了并发，而是为了**给异步加载留出落地时间**：缩略图走 `.task` 异步解码，
    /// 而本函数原本是纯同步的连续调用 —— 中途不让出主 actor，那些任务就一直排在队里不推进。
    /// 结果是导出的截图里每张缩略图都停在 `ProgressView` 占位符上，看起来像张坏图。
    /// `settle` 就是「装好视图之后、真正截图之前」那段让出主 actor 的等待。
    static func render(name: String,
                       size: CGSize,
                       colorScheme: ColorScheme? = .light,
                       saveTo: URL? = nil,
                       settle: TimeInterval = 0.45,
                       @ViewBuilder content: () -> AnyView) async -> RenderResult? {
        await renderOnMainThread(name: name, size: size,
                                 colorScheme: colorScheme, saveTo: saveTo,
                                 settle: settle, content: content)
    }

    private static func renderOnMainThread(name: String,
                                           size: CGSize,
                                           colorScheme: ColorScheme?,
                                           saveTo: URL?,
                                           settle: TimeInterval,
                                           content: () -> AnyView) async -> RenderResult? {
        // 首次调用时把 AppKit 初始化出来，避免后续窗口创建依赖未初始化的运行时
        _ = NSApplication.shared

        var view = AnyView(content()
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        if let colorScheme {
            view = AnyView(view.environment(\.colorScheme, colorScheme))
        }

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        // 让异步加载赶在截图之前完成。
        //
        // 两个坑叠在一起：
        // 1. SwiftUI 的 `.task` 只在视图进入窗口、且窗口可见之后才启动，所以要
        //    把窗口挪到屏幕外再 `orderBack` —— 既不显示，又算「已进入窗口层级」。
        // 2. 它的续体排在主 actor 的队列里，纯同步的连续调用推不动它。
        //    **不能用 `RunLoop.run` 硬泵** —— 实测那样排不动 Swift 并发的队列，
        //    必须靠 `await` 真的把主 actor 让出去，队列才会被消费。
        // 合起来的效果：不这么做，导出的截图里所有缩略图都是转圈的空框。
        if settle > 0 {
            window.setFrameOrigin(NSPoint(x: -32000, y: -32000))
            window.orderBack(nil)
            let deadline = Date().addingTimeInterval(settle)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 12_000_000)
                window.layoutIfNeeded()
                hosting.layoutSubtreeIfNeeded()
            }
        }

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        // 可选导出：给人工核对留一份实物，也为后续视觉回归留基线
        if let saveTo,
           let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: saveTo.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? png.write(to: saveTo)
        }

        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0, let data = rep.bitmapData else { return nil }

        // 取像素做亮度与墨迹统计。
        //
        // 关于「主色是否被画出来」的判定：这里用**色族**而不是精确匹配。
        // 原因是 SwiftUI 的渲染管线与 `NSColor.usingColorSpace()` 的换算结果并不一致 ——
        // 实测 sRGB(0.21,0.53,0.80) 经 NSColor 换算到显示器空间是 (0.30,0.52,0.78)，
        // 而画到位图里实际是 (0.42,0.59,0.80)，红通道差了 0.12。
        // 既然精确比对在跨色彩空间时不可靠，就用「蓝 > 绿 > 红且足够亮」来判族 ——
        // 它同样能区分橙、红、绿等其它语义色，且不依赖任何换算。
        // 主色本身的精确性由 `accentComponents`（sRGB 常量比对）单独守住。
        var luminanceSum = 0.0
        var samples = 0
        var luminances: [Double] = []
        var accentLike = 0
        // 出现过的色相桶。用来回答一个「墨迹比例答不了」的问题：图上**有没有照片**。
        // 缩略图没解码出来时，网格里是一片灰色占位符 —— 它同样有墨迹、同样让页面
        // 「渲染成功」，人不去看图根本发现不了。而照片是彩色的，色相天然分散。
        var hueBuckets = Set<Int>()
        let stepX = max(1, width / 220)
        let stepY = max(1, height / 150)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                if let raw = rep.colorAt(x: x, y: y),
                   let color = raw.usingColorSpace(rep.colorSpace) {
                    let r = Double(color.redComponent)
                    let g = Double(color.greenComponent)
                    let b = Double(color.blueComponent)
                    let value = 0.299 * r + 0.587 * g + 0.114 * b
                    luminanceSum += value
                    luminances.append(value)
                    samples += 1

                    if b > g + 0.10, g > r + 0.05, b > 0.60 { accentLike += 1 }
                    if let bucket = hueBucket(r, g, b) { hueBuckets.insert(bucket) }
                }
                x += stepX
            }
            y += stepY
        }
        guard samples > 0 else { return nil }

        let average = luminanceSum / Double(samples)
        let sorted = luminances.sorted()
        let median = sorted[sorted.count / 2]
        let ink = luminances.filter { abs($0 - median) > 0.10 }.count

        // 对整幅位图做哈希，用于比对两次渲染是否逐位相同
        let byteCount = rep.bytesPerRow * height
        let raw = Data(bytes: data, count: byteCount)
        let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()

        // 边缘墨迹：顶部区域（页头 + 操作行）最左/最右各 4 列。
        // 页面有 22pt 横向留白，这几列上正常只有背景色；一旦出现与背景差异明显的像素，
        // 就说明有控件被挤出了画布 —— SwiftUI 对这种越界不报任何错，只能靠像素判。
        // 只看顶部这一段是因为再往下是滚动区，滚动条就贴着右边缘，会误报。
        // `NSBitmapImageRep.colorAt` 的原点在左上，所以 y 从 0 开始就是画面顶部。
        func edgeInk(band: Int) -> (leading: Double, trailing: Double) {
            // 位图是按显示器缩放比渲染的（外接屏 1x、内建屏 2x），
            // 所以这里把「点」换算成像素再取样，否则检测范围会随屏幕而变。
            let scale = size.width > 0 ? Double(width) / Double(size.width) : 1
            let band = min(band, height)
            let columns = min(max(1, Int(4 * scale)), max(1, width / 4))
            var leading = 0
            var trailing = 0
            var counted = 0
            func value(_ x: Int, _ y: Int) -> Double? {
                guard let raw = rep.colorAt(x: x, y: y),
                      let color = raw.usingColorSpace(rep.colorSpace) else { return nil }
                return 0.299 * Double(color.redComponent)
                    + 0.587 * Double(color.greenComponent)
                    + 0.114 * Double(color.blueComponent)
            }
            for y in 0..<band {
                for offset in 0..<columns {
                    if let v = value(offset, y), abs(v - median) > 0.04 { leading += 1 }
                    if let v = value(width - 1 - offset, y), abs(v - median) > 0.04 { trailing += 1 }
                    counted += 1
                }
            }
            guard counted > 0 else { return (0, 0) }
            return (Double(leading) / Double(counted), Double(trailing) / Double(counted))
        }
        let topScale = size.width > 0 ? Double(width) / Double(size.width) : 1
        let edges = edgeInk(band: Int(140 * topScale))
        let fullEdges = edgeInk(band: height)

        return RenderResult(name: name,
                            width: width,
                            height: height,
                            luminance: average,
                            inkRatio: Double(ink) / Double(samples),
                            digest: digest,
                            accentLikeCount: accentLike,
                            leadingEdgeInk: edges.leading,
                            trailingEdgeInk: edges.trailing,
                            hueBucketCount: hueBuckets.count,
                            fullLeadingEdgeInk: fullEdges.leading,
                            fullTrailingEdgeInk: fullEdges.trailing)
    }

    /// 把颜色映射到 12 个色相桶之一；灰色与接近全黑 / 全白的不计入（返回 nil）。
    ///
    /// 「有没有画东西」用墨迹比例就能判，但**空占位符也有墨迹** ——
    /// 一片灰色转圈框同样能通过那条判据，而缩略图网格页真正的缺陷恰恰是「图没出来」。
    /// 这里补一个正交的判据：照片是彩色的，色相分布天然散开；
    /// 整片灰底时桶数会塌到 1–2 个。两者一起看才分得清「画了内容」和「画了照片」。
    private static func hueBucket(_ r: Double, _ g: Double, _ b: Double) -> Int? {
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let delta = maxValue - minValue
        // 太暗、太亮、或几乎无彩色的像素不参与统计（它们本来就是灰阶）
        guard maxValue > 0.18, maxValue < 0.97, delta > 0.06 else { return nil }
        guard delta / max(maxValue, 0.0001) > 0.12 else { return nil }

        var hue: Double
        if maxValue == r {
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxValue == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return Int(hue / 30) % 12
    }
}
