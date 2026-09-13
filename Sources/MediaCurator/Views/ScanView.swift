import SwiftUI
import AppKit

struct ScanView: View {
    @ObservedObject var state: AppState
    @State private var showAdvanced = true
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

    private var optionsCard: some View {
        SectionCard(title: "扫描选项", subtitle: "影响速度与查重的判定范围", symbol: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        CheckRow(title: "包含图片", subtitle: nil, isOn: $state.settings.includeImages)
                        CheckRow(title: "包含视频", subtitle: nil, isOn: $state.settings.includeVideos)
                        CheckRow(title: "跳过隐藏文件与包目录", subtitle: nil, isOn: $state.settings.skipHidden)
                        CheckRow(title: "复用指纹缓存", subtitle: "未修改的文件不重复计算",
                                 isOn: $state.settings.useHashCache)
                    }
                    .frame(width: 250)

                    VStack(alignment: .leading, spacing: 10) {
                        CheckRow(title: "视频相似度比对", subtitle: "抽帧比对，耗时主要来自解码",
                                 isOn: $state.settings.enableVideoSimilarity)
                        CheckRow(title: "允许 ffmpeg 兜底", subtitle: "处理系统解码器不支持的格式",
                                 isOn: $state.settings.useFFmpegFallback)

                        HStack(spacing: 8) {
                            Text("最小文件体积")
                                .font(.system(size: 12))
                                .frame(width: 118, alignment: .leading)
                            TextField("", value: Binding(
                                get: { Int(state.settings.minimumFileSize / 1024) },
                                set: { state.settings.minimumFileSize = Int64(max(0, $0)) * 1024 }
                            ), format: .number)
                            .frame(width: 62)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            Text("KB").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 300)
                }

                Divider()

                HStack(alignment: .center, spacing: 26) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("相似判定阈值")
                                .font(.system(size: 12))
                            TagChip(text: "汉明距离 ≤ \(state.settings.similarityThreshold)",
                                    tint: Palette.accent)
                            if state.isDedupRunning {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        HStack(spacing: 8) {
                            Text("严格").font(.system(size: 10)).foregroundStyle(.tertiary)
                            Slider(value: Binding(
                                get: { Double(state.settings.similarityThreshold) },
                                set: { state.settings.similarityThreshold = Int($0.rounded()) }
                            ), in: 0...16, step: 1) { editing in
                                if !editing { state.scheduleThresholdRecompute() }
                            }
                            .frame(width: 240)
                            Text("宽松").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        Text("越小越严格。0–2 只找几乎一模一样的，6 左右适合识别同一次拍摄的不同版本，"
                             + "超过 10 容易把无关照片并到一起。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: 430, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("视频容器时间")
                            .font(.system(size: 12))
                        Picker("", selection: $state.settings.interpretVideoTimeAsLocalWallClock) {
                            Text("按本机钟表时间解释（推荐）").tag(true)
                            Text("按 UTC 换算到本机时区").tag(false)
                        }
                        .labelsHidden()
                        .frame(width: 240)
                        Text("多数相机与安卓设备会把当地时间直接写进 UTC 字段；"
                             + "Apple 设备则严格写 UTC。选错会让视频目录整体偏一个时区。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: 300, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }

                Divider()

                HStack(spacing: 8) {
                    Text("视频抽帧数")
                        .font(.system(size: 12))
                    Stepper(value: $state.settings.videoFrameSamples, in: 2...16) {
                        Text("\(state.settings.videoFrameSamples) 帧")
                            .font(.system(size: 12, design: .rounded))
                            .frame(width: 52, alignment: .leading)
                    }
                    .controlSize(.small)
                    Text("抽帧越多，越能识别被剪辑过的同一段视频，代价是解码时间线性增加。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
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
