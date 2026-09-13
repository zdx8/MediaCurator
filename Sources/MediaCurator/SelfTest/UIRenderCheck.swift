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
            guard let result = render(name: page.title, size: canvas,
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
        guard let before = render(name: "重复项-原始", size: canvas, content: {
            AnyView(DuplicatesView(state: state))
        }) else {
            checker.check(false, "重复项页首次渲染")
            return 1
        }

        // 造一个差异：把重复组全部隐藏（模拟没有重复项）
        let savedGroups = state.groups
        state.groups = []
        guard let after = render(name: "重复项-空", size: canvas, content: {
            AnyView(DuplicatesView(state: state))
        }) else {
            checker.check(false, "重复项页空态渲染")
            return 1
        }
        state.groups = savedGroups

        checker.check(before.digest != after.digest,
                      "重复项页随数据变化而重绘（有数据 vs 无数据字节不同）")
        print(String(format: "  · 有数据：墨迹 %.4f / 空态：墨迹 %.4f", before.inkRatio, after.inkRatio))

        // 「保留整组」是新增的人工决定，它必须有可见的视觉差异，
        // 否则用户点了之后完全看不出发生了什么。
        state.groups = savedGroups
        if !state.groups.isEmpty {
            state.groups[0].keepWholeGroup = false
            let toggleOff = render(name: "整组保留-关", size: canvas, content: {
                AnyView(DuplicatesView(state: state))
            })
            state.groups[0].keepWholeGroup = true
            let toggleOn = render(name: "整组保留-开", size: canvas,
                                  saveTo: shotsDirectory?.appendingPathComponent("2-重复项-整组保留.png"),
                                  content: {
                AnyView(DuplicatesView(state: state))
            })
            state.groups[0].keepWholeGroup = false

            if let toggleOff, let toggleOn {
                checker.check(toggleOff.digest != toggleOn.digest,
                              "「保留整组」开关会改变分组卡片的呈现")
                checker.check(toggleOn.inkRatio > 0.01,
                              String(format: "整组保留状态可正常绘制（墨迹 %.4f）", toggleOn.inkRatio))
            } else {
                checker.check(false, "整组保留状态渲染")
            }
        }

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
                let overlay = render(name: "放大预览", size: canvas,
                                     saveTo: shotsDirectory?.appendingPathComponent("6-放大预览.png"),
                                     content: {
                    AnyView(MediaPreviewOverlay(items: members,
                                                index: .constant(0),
                                                keepID: group.keepID,
                                                keepWhole: group.keepWholeGroup,
                                                onSetKeep: { _ in },
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
            let videoOverlay = render(name: "视频预览", size: canvas,
                                      saveTo: shotsDirectory?.appendingPathComponent("7-视频预览.png"),
                                      content: {
                AnyView(MediaPreviewOverlay(items: videoMembers,
                                            index: .constant(0),
                                            keepID: videoGroup.keepID,
                                            keepWhole: videoGroup.keepWholeGroup,
                                            onSetKeep: { _ in },
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
            guard let result = render(name: item.label,
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

    /// 把视图挂进一个**永不显示**的无边框窗口再截图 —— 只建 NSHostingView 不给窗口，
    /// 像 NavigationSplitView / ScrollView 这类容器量不到尺寸，布局不会完整解析。
    static func render(name: String,
                       size: CGSize,
                       colorScheme: ColorScheme? = .light,
                       saveTo: URL? = nil,
                       @ViewBuilder content: () -> AnyView) -> RenderResult? {
        MainThread.run {
            renderOnMainThread(name: name, size: size,
                               colorScheme: colorScheme, saveTo: saveTo, content: content)
        }
    }

    private static func renderOnMainThread(name: String,
                                           size: CGSize,
                                           colorScheme: ColorScheme?,
                                           saveTo: URL?,
                                           content: () -> AnyView) -> RenderResult? {
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

        return RenderResult(name: name,
                            width: width,
                            height: height,
                            luminance: average,
                            inkRatio: Double(ink) / Double(samples),
                            digest: digest,
                            accentLikeCount: accentLike)
    }
}
