import SwiftUI
import AppKit
import AVKit

/// 放大预览。点击重复项里的缩略图后铺满内容区。
///
/// 预览解码到约 2400px 而不是原图：几十兆像素的原图解码后要占上百 MB，
/// 而预览窗口根本显示不了那么多像素。`CGImageSourceCreateThumbnailAtIndex`
/// 在解码阶段就完成缩放，比「先解全图再缩」既省内存也快。
/// 这也是它不走缩略图缓存的原因 —— 一张大图会把瓦片缓存里的缩略图全挤掉。
struct MediaPreviewOverlay: View {
    /// 顶部那个按钮的语义。两个页面共用这个浮层，但勾选的含义**正好相反**：
    /// 重复项页勾的是「留下」，所有媒体页勾的是「清掉」。
    /// 沿用同一套文案的话，用户会以为自己标记的是保留。
    enum Marking {
        case keep
        case cleanup
    }

    let items: [MediaItem]
    @Binding var index: Int
    /// 组内被标记保留的成员（可多选）。`marking == .cleanup` 时它是「已勾选清理」的集合。
    let keepIDs: Set<UUID>
    /// 本组的整组决定。非「按勾选」时逐张勾选无效，工具条要换成状态说明 ——
    /// 之前这里直接把按钮藏掉，用户只看得出「按钮没了」，看不出为什么。
    /// `marking == .cleanup` 时无意义（所有媒体页没有整组决定）。
    var disposition: GroupDisposition = .bySelection
    var marking: Marking = .keep
    let onToggleKeep: (UUID) -> Void
    let onReveal: (String) -> Void
    let onOpen: (String) -> Void
    let onClose: () -> Void

    /// 仅供离屏渲染注入：传了就跳过异步解码直接用这张图。
    /// 正常运行时不传，走 `load()` 从磁盘解码 —— 界面自检是同步渲染的，
    /// 异步任务来不及完成，否则导出的预览图只会是一个加载指示器。
    var injectedImage: NSImage? = nil

    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var loading = true

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragBase: CGSize = .zero
    @State private var dragging = false
    @State private var scaleBase: CGFloat = 1
    @State private var magnifying = false

    private static let maxScale: CGFloat = 8
    private static let previewPixel: CGFloat = 2400

    private var safeIndex: Int { min(max(0, index), max(0, items.count - 1)) }
    private var item: MediaItem? { items.isEmpty ? nil : items[safeIndex] }
    private var isVideo: Bool { item?.kind == .video }
    private var isCurrentKept: Bool { item.map { keepIDs.contains($0.id) } ?? false }

    /// 当前这张是本组唯一的保留项 —— 不允许取消，否则整组都会变成待清理
    private var isLastKeep: Bool { isCurrentKept && keepIDs.count <= 1 }

    private var dispositionSymbol: String {
        disposition == .keepAll ? "checkmark.shield.fill" : "trash.fill"
    }

    private var dispositionSummary: String {
        disposition == .keepAll ? "本组已设为保留整组" : "本组已设为都不保留"
    }

    private var dispositionHelp: String {
        disposition == .keepAll
            ? "这几张都要留下：本组不产生任何清理操作，但仍会按整理规则归档。"
              + "逐张勾选在整组决定下无效，可在分组卡片上取消这一决定。"
            : "这一组一张都不要：\(items.count) 个文件会全部移入系统回收站"
              + "（可在操作日志里撤销找回）。逐张勾选在整组决定下无效。"
    }

    var body: some View {
        ZStack {
            // 背景层单独放：点空白处关闭，且不会吞掉图片上的点击
            Color.black.opacity(0.9)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                toolbar
                content
                if let item { metadataBar(item) }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        // `load()` 本身是同步的：解码交给它内部的 `Task.detached`，
        // 所以这里不该出现 `await`（编译器会为此报警告）。
        .task(id: item?.id) { load() }
    }

    // MARK: - 顶部工具条

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 9) {
            circleButton("chevron.left", help: "上一张（←）", disabled: items.count < 2) { step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            circleButton("chevron.right", help: "下一张（→）", disabled: items.count < 2) { step(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])

            Text("\(safeIndex + 1) / \(items.count)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .frame(minWidth: 44)

            if !isVideo { zoomControls }

            Spacer(minLength: 12)

            quickActions

            circleButton("xmark", help: "关闭（Esc）") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var zoomControls: some View {
        Divider().frame(height: 18).overlay(Color.white.opacity(0.25))

        circleButton("minus.magnifyingglass", help: "缩小") { setScale(scale / 1.4) }
        Text("\(Int((scale * 100).rounded()))%")
            .font(.system(size: 11.5, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 46)
        circleButton("plus.magnifyingglass", help: "放大") { setScale(scale * 1.4) }
        if scale != 1 || offset != .zero {
            circleButton("arrow.counterclockwise", help: "还原到适应窗口") { resetView() }
        }
    }

    @ViewBuilder
    private var quickActions: some View {
        if let item {
            if marking == .cleanup {
                cleanupToggle(item)
            } else if disposition == .bySelection {
                keepToggle(item)
            } else {
                // 整组决定生效：说明为什么这里没有勾选按钮，
                // 以及当前这张在这一决定下会有什么下场。
                Label(dispositionSummary, systemImage: dispositionSymbol)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                    .help(dispositionHelp)
            }

            Button {
                onReveal(item.path)
            } label: {
                Label("在访达中显示", systemImage: "folder")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .controlSize(.small)

            Button {
                onOpen(item.path)
            } label: {
                Label("用默认程序打开", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .controlSize(.small)
        }
    }

    /// 重复项页：勾选 = 留下。支持多选，所以是「切换」而不是「设为唯一保留」。
    private func keepToggle(_ item: MediaItem) -> some View {
        Button {
            onToggleKeep(item.id)
        } label: {
            Label(isCurrentKept ? "取消保留" : "设为保留",
                  systemImage: isCurrentKept ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 11.5, weight: .medium))
        }
        .buttonStyle(.borderedProminent)
        .tint(isCurrentKept ? Palette.neutral : Palette.positive)
        .controlSize(.small)
        .disabled(isCurrentKept && isLastKeep)
        .help(isCurrentKept
              ? (isLastKeep
                 ? "本组至少需要保留一份，先勾选其它成员再取消这一份"
                 : "取消保留，这张将进入待清理列表")
              : "标记为保留（可多选）")
    }

    /// 「所有媒体」页：勾选 = 清掉。这里没有「至少留一份」的兜底 ——
    /// 用户是在逐张点名，程序不该替他决定留下哪一张；
    /// 风险由计划页的提示与「只进回收站、可撤销」来兜。
    private func cleanupToggle(_ item: MediaItem) -> some View {
        Button {
            onToggleKeep(item.id)
        } label: {
            Label(isCurrentKept ? "取消清理" : "加入清理",
                  systemImage: isCurrentKept ? "trash.slash.fill" : "trash")
                .font(.system(size: 11.5, weight: .medium))
        }
        .buttonStyle(.borderedProminent)
        .tint(isCurrentKept ? Palette.neutral : Palette.danger)
        .controlSize(.small)
        .help(isCurrentKept
              ? "取消勾选，这个文件会被留下"
              : "加入清理：生成计划时会移入系统回收站，可在操作日志里撤销找回")
    }

    private func circleButton(_ symbol: String,
                              help: String,
                              disabled: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.14)))
                .foregroundStyle(.white)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(help)
    }

    // MARK: - 图像区

    @ViewBuilder
    private var content: some View {
        ZStack {
            if isVideo {
                videoPlayer
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 4)
                    .gesture(panGesture.simultaneously(with: magnifyGesture))
                    .onTapGesture(count: 2) { toggleZoom() }
                    .help(scale > 1 ? "拖拽可平移，双击还原" : "双击放大")
            } else if loading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 26))
                    Text("无法解码该文件")
                        .font(.system(size: 12.5))
                    Text("可能是相机 RAW 或系统不支持该编码。可用「用默认程序打开」查看。")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var videoPlayer: some View {
        if let player {
            AVPlayerContainer(player: player)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .shadow(color: .black.opacity(0.5), radius: 16, y: 4)
        } else {
            ProgressView().controlSize(.large).tint(.white)
        }
    }

    // MARK: - 手势

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard scale > 1 else { return }
                if !dragging { dragBase = offset; dragging = true }
                offset = CGSize(width: dragBase.width + value.translation.width,
                                height: dragBase.height + value.translation.height)
            }
            .onEnded { _ in
                dragging = false
                clampOffset()
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if !magnifying { scaleBase = scale; magnifying = true }
                scale = min(Self.maxScale, max(1, scaleBase * value.magnification))
            }
            .onEnded { _ in
                magnifying = false
                scaleBase = scale
                clampOffset()
            }
    }

    private func setScale(_ value: CGFloat) {
        withAnimation(.easeOut(duration: 0.16)) {
            scale = min(Self.maxScale, max(1, value))
            clampOffset()
        }
    }

    private func toggleZoom() {
        setScale(scale > 1 ? 1 : 2)
    }

    private func resetView() {
        withAnimation(.easeOut(duration: 0.18)) {
            scale = 1
            offset = .zero
            dragBase = .zero
            scaleBase = 1
        }
    }

    /// 放大后平移不能把图拖出视野，否则会出现「图不见了」的错觉
    private func clampOffset() {
        guard scale > 1 else {
            offset = .zero
            dragBase = .zero
            return
        }
        let limit = CGSize(width: 600 * (scale - 1) / 2, height: 400 * (scale - 1) / 2)
        offset = CGSize(width: min(limit.width, max(-limit.width, offset.width)),
                        height: min(limit.height, max(-limit.height, offset.height)))
        dragBase = offset
    }

    private func step(_ delta: Int) {
        guard items.count > 1 else { return }
        index = (safeIndex + delta + items.count) % items.count
        resetView()
    }

    // MARK: - 加载

    private func load() {
        guard let item else { return }
        loading = true
        image = nil
        player?.pause()
        player = nil

        if let injectedImage {
            image = injectedImage
            loading = false
            return
        }

        if item.kind == .video {
            player = AVPlayer(url: item.url)
            loading = false
            return
        }

        let url = item.url
        let expected = item.id
        let maxPixel = Self.previewPixel
        Task {
            // 解码放到后台：几十兆像素的文件在主线程解会明显卡住界面
            let decoded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let cg = PerceptualHash.downsampledImage(url: url, maxPixel: Int(maxPixel)) else {
                    return nil
                }
                return ThumbnailProvider.nsImage(from: cg)
            }.value
            // 快速翻页时，上一张的解码可能比新的还晚完成；不加这层判断就会把当前这张
            // 覆盖成上一张（大图尤其容易撞上）。这里按 `safeIndex` 取实时下标对应的 id，
            // 不能用闭包外那个已解包的 `item` —— 它是调用时刻的快照。
            guard !items.isEmpty, items[safeIndex].id == expected else { return }
            image = decoded
            loading = false
        }
    }

    // MARK: - 元数据

    private func metadataBar(_ item: MediaItem) -> some View {
        VStack(spacing: 5) {
            Text(item.fileName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 16) {
                meta("分辨率", item.resolutionLabel)
                if let duration = item.durationLabel { meta("时长", duration) }
                meta("体积", item.fileSizeLabel)
                meta("拍摄时间", item.capturedAtLabel)
                meta("时间来源", item.timeSource.displayName)
                meta("设备", item.cameraLabel)
                if item.locationLabel != nil {
                    meta("位置", "含 GPS")
                }
            }

            PathLabel(path: item.path,
                      font: .system(size: 10, design: .monospaced),
                      color: .white.opacity(0.42))
        }
        .padding(.top, 12)
    }

    private func meta(_ key: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - 视频播放容器

/// `AVPlayerView` 的 SwiftUI 包装。
///
/// **刻意不用 SwiftUI 的 `VideoPlayer`**：它声明在私有框架 `_AVKit_SwiftUI` 里，
/// 而编译器只会自动链接那个私有框架，不会顺带链接 AVKit 本身；`VideoPlayer`
/// 内部却是 `AVPlayerView`（属 AVKit）的子类，于是运行时找不到父类，
/// 一构造播放器就 `failed to demangle superclass of VideoPlayerView` 并直接 trap。
///
/// 这里直接引用 `AVPlayerView`：
/// 1. 产生对 AVKit 的真实符号引用，链接期就不会再漏掉这个框架；
/// 2. 不再依赖私有框架，那个框架的接口本来也不保证稳定；
/// 3. 播放控件的样式、是否自动播放等都能自己决定。
struct AVPlayerContainer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        // 预览关闭时立刻停掉声音，否则浮层消失后音频还会继续
        view.player?.pause()
        view.player = nil
    }
}
