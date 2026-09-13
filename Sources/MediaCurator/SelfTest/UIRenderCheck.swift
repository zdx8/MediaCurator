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
                      "五个页面渲染结果互不相同（\(digests.count)/\(results.count)）")

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
        // 224 = `DuplicateGroupCard` 里 size 112 的缩略图实际请求的像素数。
        var warmed = 0
        for item in state.items {
            if await ThumbnailProvider.shared.thumbnail(for: item.url, maxPixel: 224) != nil { warmed += 1 }
        }
        print("缩略图预热：\(warmed)/\(state.items.count) 张")

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

        func save(_ file: String,
                  size: CGSize,
                  scheme: ColorScheme? = .light,
                  content: () -> AnyView) async {
            let result = await render(name: file,
                                      size: size,
                                      colorScheme: scheme,
                                      saveTo: shotsDirectory.appendingPathComponent("\(file).png"),
                                      settle: 0.6,
                                      content: content)
            if let result {
                print(String(format: "  ✓ %@：%d×%d", file, result.width, result.height))
            } else {
                failures.append(file)
                print("  ✗ \(file)")
            }
        }

        // 整机总览：侧栏 + 重复项页，官网首屏用
        let overview = CGSize(width: 1360, height: 860)
        await save("0-总览-浅色", size: overview, scheme: .light) {
            AnyView(HStack(spacing: 0) {
                SidebarView(state: state)
                DuplicatesView(state: state)
            })
        }
        await save("0-总览-深色", size: overview, scheme: .dark) {
            AnyView(HStack(spacing: 0) {
                SidebarView(state: state)
                DuplicatesView(state: state)
            })
        }

        // 各功能页
        let canvas = CGSize(width: 1400, height: 925)
        for page in AppPage.allCases {
            state.page = page
            await save("\(page.step)-\(page.title)", size: canvas) {
                AnyView(pageView(for: page, state: state))
            }
        }

        // 重复项的两种整组决定：各出一张，官网要能看出区别
        state.page = .duplicates
        let dispositions: [(String, GroupDisposition)] = [
            ("2-重复项-保留整组", .keepAll),
            ("2-重复项-都不保留", .discardAll)
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
            await save("6-放大预览", size: canvas) {
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
            await save("7-视频预览", size: canvas) {
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
            print(String(format: "  · 越界对照：边缘墨迹 %.5f / %.5f",
                         overflow.leadingEdgeInk, overflow.trailingEdgeInk))
            if overflow.trailingEdgeInk > 0.0005 {
                print("  ✓ 边缘检测有效（构造的越界画面被抓到）")
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
        func edgeInk() -> (leading: Double, trailing: Double) {
            // 位图是按显示器缩放比渲染的（外接屏 1x、内建屏 2x），
            // 所以这里把「点」换算成像素再取样，否则检测范围会随屏幕而变。
            let scale = size.width > 0 ? Double(width) / Double(size.width) : 1
            let band = min(Int(140 * scale), height)
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
        let edges = edgeInk()

        return RenderResult(name: name,
                            width: width,
                            height: height,
                            luminance: average,
                            inkRatio: Double(ink) / Double(samples),
                            digest: digest,
                            accentLikeCount: accentLike,
                            leadingEdgeInk: edges.leading,
                            trailingEdgeInk: edges.trailing)
    }
}
