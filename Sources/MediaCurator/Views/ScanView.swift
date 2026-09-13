import SwiftUI
import AppKit

struct ScanView: View {
    @ObservedObject var state: AppState
    @State private var showFailures = false

    private var isBusy: Bool { state.progress.phase.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "扫描", subtitle: "选择目录并读取拍摄时间、设备与内容指纹", step: 1) {
                AnyView(headerActions)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sourceCard
                    if isBusy || state.progress.phase == .cancelled { progressCard }
                    optionsCard
                    if state.scannedOnce { summarySection }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - 头部按钮

    private var headerActions: some View {
        HStack(spacing: 10) {
            if isBusy {
                Button("停止") { state.cancelScan() }
                    .controlSize(.regular)
            }
            Button {
                state.startScan()
            } label: {
                Label(state.items.isEmpty ? "开始扫描" : "重新扫描", systemImage: "play.fill")
                    .frame(minWidth: 86)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isBusy || state.settings.sourceFolders.isEmpty)
        }
    }

    // MARK: - 源目录

    private var sourceCard: some View {
        SectionCard(title: "扫描目录", subtitle: "可以添加多个目录；互相包含的目录会自动去重",
                    symbol: "folder") {
            VStack(alignment: .leading, spacing: 8) {
                if state.settings.sourceFolders.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "tray")
                            .foregroundStyle(.tertiary)
                        Text("还没有添加目录")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(state.settings.sourceFolders, id: \.self) { path in
                        HStack(spacing: 9) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.accent)
                            PathLabel(path: path, color: .primary)
                            Spacer(minLength: 8)
                            Button {
                                state.revealInFinder(path)
                            } label: {
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .help("在访达中显示")

                            Button {
                                state.removeSourceFolder(path)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .help("移除该目录")
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 9)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.16)))
                    }
                }

                Button {
                    state.addSourceFolders()
                } label: {
                    Label("添加目录", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(isBusy)
            }
        }
    }

    // MARK: - 进度

    private var progressCard: some View {
        SectionCard(title: state.progress.phase.displayName,
                    subtitle: state.progress.currentFile.isEmpty ? nil : state.progress.currentFile,
                    symbol: "hourglass") {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: state.progress.fraction)
                    .progressViewStyle(.linear)

                HStack(spacing: 18) {
                    metric("已处理", "\(state.progress.processed)")
                    metric("总数", "\(state.progress.total)")
                    metric("速度", state.progress.throughputLabel)
                    metric("预计剩余", state.progress.remainingLabel)
                    if state.progress.cachedHits > 0 {
                        metric("缓存命中", "\(state.progress.cachedHits)")
                    }
                    if state.progress.failureCount > 0 {
                        metric("跳过", "\(state.progress.failureCount)", tint: Palette.caution)
                    }
                    Spacer()
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundStyle(tint)
        }
    }

    // MARK: - 选项
    //
    // 这一区有十来个控件，原先只是「两列 + 两条分隔线」把它们摊在一起：
    // 两列宽度不等（250 / 300）、开关与输入框各贴各的右边界、行距也疏密不一，
    // 视线扫过去找不到落点 —— 而这里恰恰是每次扫描前都要过一眼的地方。
    //
    // 现在按「在问什么」分成三组：扫描内容 / 读取与性能 / 查重。三条硬规则：
    // 1. 每组都有小标题 —— 用户是先找标题再看开关，不是逐行读过去；
    // 2. 同一列里每个控件都贴齐列右边缘 —— 否则会冒出好几个右边界，看着就是一堆参差的方块；
    // 3. 从属于某个开关的选项挂在一条竖线后面，竖线随主开关亮灭 ——
    //    「关掉它以后哪几项就不起作用了」不用靠猜。

    private var optionsCard: some View {
        SectionCard(title: "扫描选项", subtitle: "影响速度与查重的判定范围",
                    symbol: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 34) {
                    scopeOptions
                    readingOptions
                    Spacer(minLength: 0)
                }

                Divider()

                dedupOptions
            }
        }
    }

    /// 决定哪些文件进库。
    private var scopeOptions: some View {
        OptionGroup(title: "扫描内容", symbol: "photo.on.rectangle.angled") {
            VStack(alignment: .leading, spacing: 10) {
                CheckRow(title: "包含图片", subtitle: "含 HEIC 与 RAW（DNG / CR3 / NEF 等）",
                         isOn: $state.settings.includeImages)
                CheckRow(title: "包含视频", subtitle: "含 MKV / AVI / MTS 等常见容器",
                         isOn: $state.settings.includeVideos)
                // 隐藏文件与包目录是两个独立开关。原先合成一个，标签写着「与包目录」
                // 而绑定只有 skipHidden —— 引擎那边又把「跳过包」写死开启，
                // 于是这个设置项整条都是假的。拆开才是它声称的那件事。
                CheckRow(title: "跳过隐藏文件", subtitle: "以 . 开头的文件与目录",
                         isOn: $state.settings.skipHidden)
                CheckRow(title: "跳过包目录", subtitle: "照片图库与 .app 这类被系统视作单个文件的目录",
                         isOn: $state.settings.skipPackages)
                OptionRow(title: "最小文件体积（KB）",
                          hint: "更小的文件不进库，用来滤掉缩略图缓存这类噪音。") {
                    TextField("", value: Binding(
                        get: { Int(state.settings.minimumFileSize / 1024) },
                        set: { state.settings.minimumFileSize = Int64(max(0, $0)) * 1024 }
                    ), format: .number)
                    .frame(width: 84)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: optionColumnWidth, alignment: .leading)
    }

    /// 决定怎么读、读得多快。
    private var readingOptions: some View {
        OptionGroup(title: "读取与性能", symbol: "speedometer") {
            VStack(alignment: .leading, spacing: 10) {
                CheckRow(title: "复用指纹缓存", subtitle: "未修改的文件不重复计算",
                         isOn: $state.settings.useHashCache)
                CheckRow(title: "允许 ffmpeg 兜底", subtitle: "处理系统解码器不支持的格式",
                         isOn: $state.settings.useFFmpegFallback)
                OptionRow(title: "视频抽帧数",
                          hint: "抽帧越多越能识别被剪辑过的同一段视频；解码时间随之线性增加。") {
                    HStack(spacing: 8) {
                        Text("\(state.settings.videoFrameSamples) 帧")
                            .font(.system(size: 12, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                        Stepper("", value: $state.settings.videoFrameSamples, in: 2...16)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                }
                OptionRow(title: "视频容器时间",
                          hint: "多数相机与安卓设备写的是当地时间，Apple 设备严格写 UTC；"
                              + "选错会让视频目录整体偏一个时区。") {
                    Picker("", selection: $state.settings.interpretVideoTimeAsLocalWallClock) {
                        Text("按本机钟表时间解释（推荐）").tag(true)
                        Text("按 UTC 换算到本机时区").tag(false)
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
            }
        }
        .frame(maxWidth: optionColumnWidth, alignment: .leading)
    }

    /// 决定扫完要不要比对、怎么比对。
    ///
    /// 主开关与它管辖的项收在同一组里。关掉时**不把下面的项藏起来** ——
    /// 藏起来用户就看不到自己设过什么了，改成变灰，保留「我这样设过」的记忆。
    private var dedupOptions: some View {
        OptionGroup(title: "查重", symbol: "square.on.square.dashed") {
            VStack(alignment: .leading, spacing: 12) {
                CheckRow(title: "检查重复媒体",
                         subtitle: "找出重复与相似的图片、视频；关闭则跳过整个比对阶段，扫描更快",
                         isOn: $state.settings.checkDuplicates)

                NestedOptions(isActive: state.settings.checkDuplicates) {
                    VStack(alignment: .leading, spacing: 12) {
                        thresholdRow
                        CheckRow(title: "视频相似度比对", subtitle: "抽帧比对；耗时主要来自解码",
                                 isOn: $state.settings.enableVideoSimilarity)
                    }
                }
                .disabled(!state.settings.checkDuplicates)
            }
        }
        .frame(maxWidth: optionColumnWidth, alignment: .leading)
    }

    /// 相似判定阈值。
    ///
    /// 滑块不设固定宽度，跟着这一列一起伸缩 —— 它本来就该越宽越好调，
    /// 原先钉死 240 点只是为了让两列凑出固定的总宽。
    private var thresholdRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text("相似判定阈值").font(.system(size: 12))
                Spacer(minLength: 12)
                if state.isDedupRunning {
                    ProgressView().controlSize(.mini)
                }
                TagChip(text: "汉明距离 ≤ \(state.settings.similarityThreshold)",
                        tint: Palette.accent)
            }
            HStack(spacing: 8) {
                Text("严格").font(.system(size: 10)).foregroundStyle(.tertiary)
                Slider(value: Binding(
                    get: { Double(state.settings.similarityThreshold) },
                    set: { state.settings.similarityThreshold = Int($0.rounded()) }
                ), in: 0...16, step: 1) { editing in
                    if !editing { state.scheduleThresholdRecompute() }
                }
                Text("宽松").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            OptionHint(text: "越小越严格：0–2 只找几乎一模一样的，6 左右适合识别同一次拍摄的不同版本，超过 10 容易把无关照片并到一起。")
        }
    }

    // MARK: - 扫描结果概览

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                StatCard(title: "文件总数", value: "\(state.items.count)",
                         subtitle: "耗时 \(String(format: "%.1f", state.lastScanElapsed)) 秒",
                         symbol: "photo.on.rectangle")
                StatCard(title: "图片", value: "\(state.imageCount)", subtitle: nil,
                         symbol: "photo", tint: Palette.positive)
                StatCard(title: "视频", value: "\(state.videoCount)", subtitle: nil,
                         symbol: "film", tint: Palette.violet)
                StatCard(title: "总体积",
                         value: ByteCountFormatter.string(fromByteCount: state.totalBytes, countStyle: .file),
                         subtitle: state.cachedHitCount > 0 ? "缓存命中 \(state.cachedHitCount)" : nil,
                         symbol: "externaldrive")
                StatCard(title: "重复可释放", value: state.dedupSummary.reclaimableLabel,
                         subtitle: "\(state.dedupSummary.totalGroupCount) 组",
                         symbol: "arrow.down.circle", tint: Palette.caution)
            }

            HStack(alignment: .top, spacing: 14) {
                SectionCard(title: "拍摄年份分布", subtitle: "按 EXIF / 容器时间统计", symbol: "chart.bar") {
                    if state.yearHistogram.isEmpty {
                        Text("没有可用于统计的拍摄时间").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    } else {
                        let maxValue = state.yearHistogram.map { $0.count }.max() ?? 1
                        VStack(spacing: 6) {
                            ForEach(state.yearHistogram, id: \.label) { row in
                                BarRow(label: row.label, value: row.count, maxValue: maxValue)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)

                SectionCard(title: "拍摄设备分布", subtitle: "取前 8 名", symbol: "camera") {
                    if state.deviceHistogram.isEmpty {
                        Text("没有识别到设备信息").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    } else {
                        let maxValue = state.deviceHistogram.map { $0.count }.max() ?? 1
                        VStack(spacing: 6) {
                            ForEach(state.deviceHistogram, id: \.label) { row in
                                BarRow(label: row.label, value: row.count, maxValue: maxValue,
                                       tint: Palette.violet)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }

            if state.unknownTimeCount > 0 || state.unreliableTimeCount > 0 {
                SectionCard(title: "需要注意的时间信息", symbol: "exclamationmark.triangle") {
                    VStack(alignment: .leading, spacing: 6) {
                        if state.unknownTimeCount > 0 {
                            bullet("\(state.unknownTimeCount) 个文件完全无法确定拍摄时间，"
                                   + "整理时会进入「未识别日期」目录。", tint: Palette.caution)
                        }
                        if state.unreliableTimeCount > 0 {
                            bullet("\(state.unreliableTimeCount) 个文件只能取文件系统时间作为拍摄时间，"
                                   + "可能与真实时间不符。", tint: Palette.caution)
                        }
                    }
                }
            }

            if !state.failures.isEmpty {
                SectionCard(title: "未能处理的文件", subtitle: "这些文件已被跳过，不影响其余处理",
                            symbol: "doc.questionmark") {
                    DisclosureGroup(isExpanded: $showFailures) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(state.failures.prefix(200), id: \.path) { failure in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(failure.message)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Palette.caution)
                                        .frame(width: 160, alignment: .leading)
                                    PathLabel(path: failure.path)
                                    Spacer(minLength: 0)
                                }
                            }
                            if state.failures.count > 200 {
                                Text("仅显示前 200 条，共 \(state.failures.count) 条")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("共 \(state.failures.count) 个文件，展开查看")
                            .font(.system(size: 11.5))
                    }
                }
            }
        }
    }

    private func bullet(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(tint).frame(width: 5, height: 5).padding(.top, 6)
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
