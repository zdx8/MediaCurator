import SwiftUI
import AppKit

struct OrganizeView: View {
    @ObservedObject var state: AppState
    @State private var showVariables = false
    @FocusState private var folderTemplateFocused: Bool
    @FocusState private var renameTemplateFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "整理规则", subtitle: "定义目录结构与命名方式，规则变化后需要重新生成计划", step: 3) {
                AnyView(
                    Button {
                        state.generatePlan()
                    } label: {
                        Label("生成计划", systemImage: "list.bullet.rectangle.portrait")
                            .frame(minWidth: 92)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(state.items.isEmpty)
                )
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    actionCard
                    destinationCard
                    folderTemplateCard
                    renameTemplateCard
                    filterCard
                    conflictCard
                    previewCard
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 26)
            }
        }
    }

    // MARK: - 处理方式

    private var actionCard: some View {
        SectionCard(title: "要做哪些事", subtitle: "两项可以同时进行；重复副本会被清理而不是归档",
                    symbol: "checklist") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 34) {
                    VStack(alignment: .leading, spacing: 10) {
                        CheckRow(title: "按规则归档",
                                     subtitle: "把文件移动/复制到模板指定的目录，并可重命名",
                                     isOn: $state.filter.archiveFiles)
                        CheckRow(title: "清理重复副本",
                                     subtitle: "把重复组里未被保留的副本移入系统回收站",
                                     isOn: $state.filter.cleanRedundantDuplicates)
                    }
                    .frame(maxWidth: optionColumnWidth, alignment: .leading)

                    // 与其它选项行同一套排版：标签在左、控件贴齐列右边缘、说明另起一行。
                    // 原先这里是「标签独占一行、控件在下一行、说明再一行」，
                    // 和同页面其它行摆在一起就是两种格式。
                    OptionRow(title: "搬运方式",
                              hint: state.rule.transferMode == .move
                                  ? "移动：整理后原位置不再保留文件，可真正腾出空间。"
                                  : "复制：原文件保持不动，适合先验证规则是否正确。") {
                        Picker("", selection: $state.rule.transferMode) {
                            ForEach(TransferMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 170)
                    }
                    .frame(maxWidth: optionColumnWidth, alignment: .leading)

                    Spacer()
                }

                if !state.filter.doesAnyWork {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.caution)
                        Text("两项都没勾选，生成计划不会有任何结果。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.caution)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - 目标位置

    private var destinationCard: some View {
        SectionCard(title: "目标位置", subtitle: "原地整理会在各源目录内部建立子目录，不改变根目录位置",
                    symbol: "folder.badge.gearshape") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: Binding(
                    get: { state.rule.isInPlace },
                    set: { inPlace in
                        if inPlace {
                            state.rule.destinationRoot = ""
                        } else if state.rule.destinationRoot.isEmpty,
                                  let first = state.settings.sourceFolders.first {
                            state.rule.destinationRoot = first + "/整理输出"
                        }
                    }
                )) {
                    Text("原地整理").tag(true)
                    Text("输出到新目录").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)

                if !state.rule.isInPlace {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        PathLabel(path: state.rule.destinationRoot.isEmpty ? "（未设置）" : state.rule.destinationRoot,
                                  color: state.rule.destinationRoot.isEmpty ? Palette.caution : .primary)
                        Button("选择…") { state.chooseDestinationFolder() }
                            .controlSize(.small)
                        Spacer()
                    }
                } else {
                    Text("文件会在各自所属的源目录内，按下面的模板建立子目录。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - 目录模板

    private var folderTemplateCard: some View {
        SectionCard(title: "目录结构模板", subtitle: "用 / 表示层级；无法确定拍摄时间的文件会单独归入一个目录",
                    symbol: "square.grid.3x1.folder.badge.plus") {
            VStack(alignment: .leading, spacing: 11) {
                presetPicker(title: "常用结构", presets: OrganizeRule.folderPresets,
                             binding: $state.rule.folderTemplate) {
                    folderTemplateFocused = true
                }

                HStack(spacing: 8) {
                    Text("模板").font(.system(size: 12)).frame(width: 40, alignment: .leading)
                    TextField("例如 {yyyy}/{MM}/{MM-dd}", text: $state.rule.folderTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($folderTemplateFocused)
                    Button {
                        showVariables.toggle()
                    } label: {
                        Label("变量", systemImage: "curlybraces")
                    }
                    .controlSize(.small)
                    .popover(isPresented: $showVariables, arrowEdge: .top) {
                        variablePopover { token in
                            state.rule.folderTemplate += token
                        }
                    }
                }

                if !unknownVariables.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.caution)
                        Text("无法识别的变量：\(unknownVariables.joined(separator: "、"))，它们会原样出现在目录名里。")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.caution)
                        Spacer()
                    }
                }

                HStack(spacing: 8) {
                    Text("未识别日期目录").font(.system(size: 12))
                    TextField("未识别日期", text: $state.rule.unknownDateFolder)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .font(.system(size: 12))
                    Text("拍摄时间完全无法确定时使用")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }

                templatePreview
            }
        }
    }

    private var unknownVariables: [String] {
        TemplateRenderer.unknownVariables(in: state.rule.folderTemplate)
            + TemplateRenderer.unknownVariables(in: state.rule.renameTemplate)
    }

    // MARK: - 命名模板

    private var renameTemplateCard: some View {
        SectionCard(title: "重命名模板", subtitle: "留空则保持原文件名不变",
                    symbol: "textformat.abc") {
            VStack(alignment: .leading, spacing: 11) {
                presetPicker(title: "常用命名", presets: OrganizeRule.renamePresets,
                             binding: $state.rule.renameTemplate) {
                    renameTemplateFocused = true
                }

                HStack(spacing: 8) {
                    Text("模板").font(.system(size: 12)).frame(width: 40, alignment: .leading)
                    TextField("留空表示不重命名", text: $state.rule.renameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($renameTemplateFocused)
                    Button {
                        state.rule.renameTemplate = ""
                    } label: {
                        Text("清空")
                    }
                    .controlSize(.small)
                }

                HStack(spacing: 12) {
                    Text("编号起始").font(.system(size: 12))
                    TextField("", value: $state.rule.sequenceStart, format: .number)
                        .frame(width: 56)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    Text("补零位数").font(.system(size: 12))
                    Stepper(value: $state.rule.sequencePadding, in: 1...8) {
                        Text("\(state.rule.sequencePadding)")
                            .font(.system(size: 12, design: .rounded))
                            .frame(width: 20)
                    }
                    .controlSize(.small)
                    Text("编号 {seq} 按目标目录独立计数，并按拍摄时间排序")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
    }

    /// 预设下拉。选中「自定义」时不改动模板，而是把焦点交给下面的输入框 ——
    /// 直接清空会毁掉用户已经调好的模板。
    private func presetPicker(title: String,
                              presets: [(String, String)],
                              binding: Binding<String>,
                              onCustom: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).frame(width: 62, alignment: .leading)
            Picker("", selection: Binding(
                get: { presets.first(where: { $0.1 == binding.wrappedValue })?.0 ?? "自定义" },
                set: { name in
                    if let match = presets.first(where: { $0.0 == name }) {
                        binding.wrappedValue = match.1
                    } else {
                        onCustom?()
                    }
                }
            )) {
                ForEach(presets, id: \.0) { preset in
                    Text(preset.0).tag(preset.0)
                }
                Divider()
                Text("自定义").tag("自定义")
            }
            .labelsHidden()
            .frame(width: 246)
            Spacer()
        }
    }

    private func variablePopover(insert: @escaping (String) -> Void) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text("点击变量即可追加到模板末尾")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ForEach(OrganizeRule.templateVariables, id: \.0) { variable in
                    HStack(spacing: 9) {
                        TokenChip(token: variable.0, hint: variable.1) { insert(variable.0) }
                        Text(variable.1)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 330, height: 380)
    }

    // MARK: - 模板实时预览

    private var templatePreview: some View {
        let sample = state.items.first { $0.capturedAt != nil } ?? state.items.first
        return Group {
            if let item = sample {
                let vars = TemplateRenderer.variables(for: item,
                                                      sequence: state.rule.sequenceStart,
                                                      padding: state.rule.sequencePadding,
                                                      unknownDatePlaceholder: state.rule.unknownDateFolder)
                let components = item.capturedAt == nil
                    ? [PathTools.sanitizeComponent(state.rule.unknownDateFolder)]
                    : TemplateRenderer.renderFolderPath(state.rule.folderTemplate, variables: vars)
                let base = state.rule.isInPlace
                    ? item.sourceRoot
                    : (state.rule.destinationRoot.isEmpty ? "（未设置目标目录）" : state.rule.destinationRoot)
                let stem = state.rule.renameTemplate.trimmingCharacters(in: .whitespaces).isEmpty
                    ? item.url.deletingPathExtension().lastPathComponent
                    : TemplateRenderer.renderFileName(state.rule.renameTemplate, variables: vars)
                let ext = item.url.pathExtension
                let fullName = ext.isEmpty ? stem : "\(stem).\(ext)"
                let full = ([base] + components + [fullName]).joined(separator: "/")

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Image(systemName: "eye")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.accent)
                        Text("以「\(item.fileName)」为例")
                            .font(.system(size: 11, weight: .medium))
                        TagChip(text: "时间来源 \(item.timeSource.displayName)", tint: Palette.neutral, filled: false)
                        Spacer()
                    }
                    Text(full)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(Palette.accentSoft))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 筛选
    //
    // 与扫描页的选项区同一套排版约定（见 `ScanView` 里 `optionsCard` 的注释）：
    // 分组小标题 + 控件贴齐列右边缘 + 从属项挂在竖线后面。
    //
    // 原先这一卡分两列，宽度写的是 260 / 330，而「最低像素数」那一行的内容
    // （标签 84 + 输入框 90 + 一句说明 ≈ 190）加起来约 375 点 —— **比它自己声明的列宽还宽**。
    // 溢出的部分正好被右边的空白吃掉，所以一直没暴露；窗口再窄一点就会顶到卡片边界。
    // 把说明改成行下小字、输入框贴齐右边缘之后，这一行不再有硬编码宽度可言。

    private var filterCard: some View {
        SectionCard(title: "筛选条件", subtitle: "只有满足条件的文件才会进入计划",
                    symbol: "line.3.horizontal.decrease.circle") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 34) {
                    contentFilterOptions
                    dateAndPixelOptions
                    Spacer(minLength: 0)
                }

                if !state.availableDevices.isEmpty {
                    Divider()
                    deviceFilterOptions
                }
            }
        }
    }

    /// 按内容筛：哪一类文件进计划、是不是只做重复清理。
    private var contentFilterOptions: some View {
        OptionGroup(title: "处理内容", symbol: "square.on.square.dashed") {
            VStack(alignment: .leading, spacing: 10) {
                // 原文案写的是「忽略归档，仅做重复清理」，但这一项其实只是个**范围**过滤：
                // 它把非重复副本剔出计划，至于剩下的重复副本是清理还是归档，
                // 仍由「要做哪些事」里的两个开关决定。文案按实现收窄，别承诺代码没做的事。
                CheckRow(title: "只处理重复副本", subtitle: "只把重复副本纳入计划",
                         isOn: $state.filter.onlyRedundantDuplicates)
                CheckRow(title: "包含图片", subtitle: "jpg / heic / png / tiff 等",
                         isOn: $state.filter.includeImages)
                CheckRow(title: "包含视频", subtitle: "mp4 / mov / m4v 等",
                         isOn: $state.filter.includeVideos)
            }
        }
        .frame(maxWidth: optionColumnWidth, alignment: .leading)
    }

    /// 按拍摄时间与像素筛。
    private var dateAndPixelOptions: some View {
        OptionGroup(title: "拍摄时间与像素", symbol: "calendar") {
            VStack(alignment: .leading, spacing: 10) {
                CheckRow(title: "拍摄时间范围", subtitle: nil, isOn: dateRangeEnabled)

                if dateRangeEnabled.wrappedValue {
                    // 两个日期连同「拍摄时间未知会被排除」都是从属关系，
                    // 挂在竖线后面，与扫描页的查重组保持同一种读法。
                    NestedOptions(isActive: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                DatePicker("", selection: Binding(
                                    get: { state.rule.dateFrom ?? Date() },
                                    set: { state.rule.dateFrom = $0 }), displayedComponents: .date)
                                    .labelsHidden()
                                Text("至").font(.system(size: 11)).foregroundStyle(.secondary)
                                DatePicker("", selection: Binding(
                                    get: { state.rule.dateTo ?? Date() },
                                    set: { state.rule.dateTo = $0 }), displayedComponents: .date)
                                    .labelsHidden()
                            }
                            OptionHint(text: "拍摄时间未知的文件会被排除。")
                        }
                    }
                }

                OptionRow(title: "最低像素数",
                          hint: "例如 1000000 约等于 100 万像素。") {
                    TextField("", value: $state.filter.minimumPixelCount, format: .number)
                        .frame(width: 96)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: optionColumnWidth, alignment: .leading)
    }

    /// 时间范围开关：两侧都为空才算关；写回时一次把起止都设上或都清掉，
    /// 免得出现「只设了起始、没有结束」这种半开状态 —— 那种状态在界面上看不出来，
    /// 但过滤行为已经变了。
    private var dateRangeEnabled: Binding<Bool> {
        Binding(
            get: { state.rule.dateFrom != nil || state.rule.dateTo != nil },
            set: { on in
                if on {
                    state.rule.dateFrom = Calendar.current.date(byAdding: .year, value: -10, to: Date())
                    state.rule.dateTo = Date()
                } else {
                    state.rule.dateFrom = nil
                    state.rule.dateTo = nil
                }
            })
    }

    /// 设备筛选。
    ///
    /// 芯片是自适应网格，所以这一组占满整宽；状态与「清除」放到标题行右端 ——
    /// 原先它们夹在标题后面，网格一换行就与标题错开，看着像两个不相干的东西。
    private var deviceFilterOptions: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                OptionGroupTitle(title: "只处理这些设备", symbol: "camera")
                Spacer(minLength: 8)
                TagChip(text: state.rule.deviceFilter.isEmpty
                        ? "全部设备" : "已选 \(state.rule.deviceFilter.count)",
                        tint: Palette.accent, filled: false)
                if !state.rule.deviceFilter.isEmpty {
                    Button("清除") { state.rule.deviceFilter.removeAll() }
                        .controlSize(.mini)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 7)], spacing: 7) {
                ForEach(state.availableDevices, id: \.self) { device in
                    deviceChip(device)
                }
            }
        }
    }

    private func deviceChip(_ device: String) -> some View {
        let selected = state.rule.deviceFilter.contains(device)
        let count = state.items.filter { $0.cameraLabel == device }.count
        return Button {
            if selected { state.rule.deviceFilter.remove(device) }
            else { state.rule.deviceFilter.insert(device) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                Text(device)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                Text("\(count)")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Palette.accentSoft : Color(nsColor: .quaternaryLabelColor).opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Palette.accent.opacity(0.5) : Color(nsColor: .separatorColor), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Palette.accent : .primary)
    }

    // MARK: - 冲突策略

    private var conflictCard: some View {
        SectionCard(title: "同名文件处理", symbol: "exclamationmark.arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 9) {
                Picker("", selection: $state.rule.conflictPolicy) {
                    ForEach(ConflictPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)

                Text(state.rule.conflictPolicy.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(state.rule.conflictPolicy == .overwrite ? Palette.danger : .secondary)

                if state.rule.conflictPolicy == .overwrite {
                    Text("「覆盖同名文件」会把目标位置的原文件先移入回收站，再由新文件顶替 —— "
                         + "不会不可恢复地删除，执行后可在「操作日志」里撤销找回。"
                         + "不过仍建议优先使用自动追加序号，避免来回折腾。")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 结构预览

    private var previewCard: some View {
        SectionCard(title: "结构与改名预览", subtitle: state.folderCounts.isEmpty
                    ? "生成计划后这里会展示目标目录结构" : "基于最近一次生成的计划",
                    symbol: "rectangle.3.group") {
            if state.folderCounts.isEmpty {
                Text("还没有生成计划。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("目录分布")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        let base = state.rule.isInPlace ? "" : state.rule.destinationRoot
                        let entries = state.folderCounts
                            .map { (path: relativePath($0.key, base: base), count: $0.value) }
                            .sorted { $0.path < $1.path }
                            .prefix(24)
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(entries, id: \.path) { entry in
                                HStack(spacing: 6) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(Palette.accent)
                                    Text(entry.path)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Text("\(entry.count)")
                                        .font(.system(size: 10.5, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if state.folderCounts.count > 24 {
                            Text("还有 \(state.folderCounts.count - 24) 个目录…")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 330, alignment: .leading)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("改名示例")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(state.operations.filter { $0.kind == .move }.prefix(8)) { operation in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(operation.fileName)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 5) {
                                        Image(systemName: "arrow.turn.down.right")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Palette.accent)
                                        Text(operation.destinationPath.map {
                                            URL(fileURLWithPath: $0).lastPathComponent
                                        } ?? "")
                                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                            .foregroundStyle(Palette.accent)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private func relativePath(_ path: String, base: String) -> String {
        guard !base.isEmpty, path.hasPrefix(base) else { return path }
        var trimmed = String(path.dropFirst(base.count))
        if trimmed.hasPrefix("/") { trimmed.removeFirst() }
        return trimmed.isEmpty ? "（根目录）" : trimmed
    }
}
