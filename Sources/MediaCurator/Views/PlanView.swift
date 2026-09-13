import SwiftUI
import AppKit

struct PlanView: View {
    @ObservedObject var state: AppState
    @State private var kindFilter: OperationKind? = nil
    @State private var showConfirmation = false
    @State private var visibleCount = 200

    private var rows: [PlanOperation] {
        let base = kindFilter == nil ? state.operations : state.operations.filter { $0.kind == kindFilter }
        return Array(base.prefix(visibleCount))
    }

    private var totalRows: Int {
        kindFilter == nil ? state.operations.count : state.operations.filter { $0.kind == kindFilter }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "执行计划", subtitle: "逐项确认后才会改动文件；所有操作都可从日志撤销", step: 4) {
                AnyView(headerActions)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if state.operations.isEmpty {
                EmptyState(symbol: "list.bullet.rectangle",
                           title: "还没有生成计划",
                           message: "在「整理规则」页配置好模板后点击「生成计划」，"
                               + "这里会列出每一步将要发生的改动。",
                           actionTitle: "去配置规则",
                           action: { state.page = .organize })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summaryCards
                        if !state.planWarnings.isEmpty { warningBox }
                        if let report = state.lastExecution, report.succeeded + report.failed > 0 {
                            resultBox(report)
                        }
                        if let progress = state.executionProgress { executionProgressCard(progress) }
                        selectionBar
                        tableCard
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 26)
                }
            }
        }
        .sheet(isPresented: $showConfirmation) {
            ConfirmationSheet(state: state, isPresented: $showConfirmation)
        }
        .onChange(of: kindFilter) { _, _ in visibleCount = 200 }
    }

    // MARK: - 头部

    private var headerActions: some View {
        HStack(spacing: 9) {
            Menu {
                ForEach(PlanExportFormat.allCases) { format in
                    Button(format.displayName) { state.exportPlan(format: format) }
                }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 84)
            .disabled(state.operations.isEmpty)

            Button {
                showConfirmation = true
            } label: {
                Label("执行计划", systemImage: "play.circle.fill")
                    .frame(minWidth: 92)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(state.destructiveCount > 0 ? Palette.danger : Palette.accent)
            .disabled(!state.hasExecutableWork || state.executionProgress != nil)
        }
    }

    // MARK: - 汇总

    private var summaryCards: some View {
        HStack(spacing: 12) {
            StatCard(title: "待执行", value: "\(state.selectedOperationCount)",
                     subtitle: "共 \(state.operations.count) 行",
                     symbol: "checkmark.circle", tint: Palette.accent)
            StatCard(title: "移动 / 重命名",
                     value: "\(state.planSummary.moveCount + state.planSummary.renameCount)",
                     subtitle: state.planSummary.moveBytesLabel,
                     symbol: "arrow.right.doc.on.clipboard")
            if state.planSummary.copyCount > 0 {
                StatCard(title: "复制", value: "\(state.planSummary.copyCount)",
                         subtitle: "源文件保留", symbol: "plus.square.on.square",
                         tint: Palette.teal)
            }
            StatCard(title: "移入回收站", value: "\(state.planSummary.trashCount)",
                     subtitle: "可释放 " + state.planSummary.reclaimableLabel,
                     symbol: "trash", tint: state.planSummary.trashCount > 0 ? Palette.danger : Palette.neutral)
            StatCard(title: "无需处理", value: "\(state.planSummary.alreadyPlacedCount)",
                     subtitle: "已在目标位置", symbol: "checkmark.seal", tint: Palette.positive)
            StatCard(title: "跳过", value: "\(state.planSummary.skippedCount)",
                     subtitle: "因冲突策略", symbol: "minus.circle", tint: Palette.neutral)
        }
    }

    private var warningBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.caution)
                    .font(.system(size: 12))
                Text("执行前请确认")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
            }
            // 用下标当 id：这些提示是人写的整句，将来若有两处追加同一句话，
            // `id: \.self` 就会给出重复 id（SwiftUI 会报 duplicate id 并可能错位显示）。
            ForEach(state.planWarnings.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 7) {
                    Circle().fill(Palette.caution).frame(width: 4.5, height: 4.5).padding(.top, 6)
                    Text(state.planWarnings[index])
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Palette.caution.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Palette.caution.opacity(0.3), lineWidth: 1))
    }

    private func resultBox(_ report: ExecutionReport) -> some View {
        let ok = report.failed == 0
        let tint = ok ? Palette.positive : Palette.caution
        let messages = Array(report.messages.prefix(6))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tint)
                    .font(.system(size: 12))
                Text("上次执行：\(report.summaryLine)")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button {
                    if let session = state.sessions.first(where: { $0.id == report.session.id }) {
                        Task { await state.undo(session) }
                    } else {
                        Task { await state.undo(report.session) }
                    }
                } label: {
                    Label("撤销这次执行", systemImage: "arrow.uturn.backward")
                }
                .controlSize(.small)
            }
            // 用下标而不是 `id: \.self`：执行报告里的消息可能重复（同一个失败原因
            // 出现在多个文件上），一旦重复，SwiftUI 会拿到重复 id 并可能显示错乱。
            ForEach(messages.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 7) {
                    Circle().fill(tint).frame(width: 4.5, height: 4.5).padding(.top, 6)
                    Text(messages[index])
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tint.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(tint.opacity(0.3), lineWidth: 1))
    }

    private func executionProgressCard(_ progress: ExecutionProgress) -> some View {
        SectionCard(title: "正在执行", subtitle: progress.currentPath, symbol: "gearshape.2") {
            VStack(alignment: .leading, spacing: 9) {
                ProgressView(value: progress.fraction).progressViewStyle(.linear)
                HStack(spacing: 18) {
                    Text("\(progress.completed) / \(progress.total)")
                        .font(.system(size: 11.5, design: .rounded))
                    Text("成功 \(progress.succeeded)")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Palette.positive)
                    if progress.failed > 0 {
                        Text("失败 \(progress.failed)")
                            .font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(Palette.danger)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - 选择工具栏

    private var selectionBar: some View {
        HStack(spacing: 9) {
            Picker("", selection: $kindFilter) {
                Text("全部 \(state.operations.count)").tag(OperationKind?.none)
                Text("移动 \(state.planSummary.moveCount)").tag(OperationKind?.some(.move))
                Text("重命名 \(state.planSummary.renameCount)").tag(OperationKind?.some(.rename))
                if state.planSummary.copyCount > 0 {
                    Text("复制 \(state.planSummary.copyCount)").tag(OperationKind?.some(.copy))
                }
                Text("回收站 \(state.planSummary.trashCount)").tag(OperationKind?.some(.trash))
                Text("已就位 \(state.planSummary.alreadyPlacedCount)").tag(OperationKind?.some(.alreadyPlaced))
                Text("跳过 \(state.planSummary.skippedCount)").tag(OperationKind?.some(.skipped))
            }
            .labelsHidden()
            .frame(width: 156)

            Divider().frame(height: 18)

            Button("全选") { state.selectAllOperations(true) }
                .controlSize(.small)
            Button("全不选") { state.selectAllOperations(false) }
                .controlSize(.small)
            Button("仅归档") { onlyArchive() }
                .controlSize(.small)
            Button("仅清理回收站") { onlyTrash() }
                .controlSize(.small)

            Spacer()

            Text("已勾选 \(state.selectedOperationCount) 项")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private func onlyArchive() {
        state.selectAllOperations(false)
        for index in state.operations.indices {
            switch state.operations[index].kind {
            case .move, .rename, .copy: state.operations[index].selected = true
            default: break
            }
        }
        state.planSummary = PlanSummary.compute(from: state.operations)
    }

    private func onlyTrash() {
        state.selectAllOperations(false)
        for index in state.operations.indices where state.operations[index].kind == .trash {
            state.operations[index].selected = true
        }
        state.planSummary = PlanSummary.compute(from: state.operations)
    }

    // MARK: - 列表

    private var tableCard: some View {
        SectionCard(title: "操作清单", subtitle: "取消勾选即可跳过该行", symbol: "list.bullet") {
            VStack(spacing: 0) {
                rowHeader
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(rows) { operation in
                        OperationRow(operation: operation,
                                     onToggle: { state.setSelection(operationID: operation.id, selected: $0) },
                                     onReveal: { state.revealInFinder(operation.sourcePath) })
                        Divider().opacity(0.35)
                    }
                }
                if totalRows > visibleCount {
                    Button {
                        visibleCount += 200
                    } label: {
                        Label("继续加载（还有 \(totalRows - visibleCount) 行）", systemImage: "ellipsis.circle")
                    }
                    .controlSize(.regular)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var rowHeader: some View {
        HStack(spacing: 10) {
            Text("").frame(width: 20)
            Text("类型").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Text("文件").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 178, alignment: .leading)
            Text("目标位置").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("原因").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 226, alignment: .leading)
            Text("体积").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
}

// MARK: - 单行

struct OperationRow: View {
    let operation: PlanOperation
    let onToggle: (Bool) -> Void
    let onReveal: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if operation.kind.isMutating {
                Toggle("", isOn: Binding(get: { operation.selected }, set: onToggle))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: 20)
            } else {
                Image(systemName: operation.kind.symbolName)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)
            }

            HStack(spacing: 5) {
                Image(systemName: operation.kind.symbolName)
                    .font(.system(size: 10))
                Text(operation.kind.displayName)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(Palette.tint(for: operation.kind))
            .frame(width: 68, alignment: .leading)

            HStack(spacing: 5) {
                Image(systemName: operation.kindOfMedia.symbolName)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Text(operation.fileName)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 178, alignment: .leading)
            .help(operation.sourcePath)

            destinationCell
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(operation.reason)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(width: 226, alignment: .leading)

            Text(operation.fileSize > 0
                 ? ByteCountFormatter.string(fromByteCount: operation.fileSize, countStyle: .file)
                 : "—")
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(hovering ? Color(nsColor: .quaternaryLabelColor).opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("在访达中显示原文件", action: onReveal)
            if let destination = operation.destinationPath {
                Button("复制目标路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(destination, forType: .string)
                }
            }
        }
    }

    @ViewBuilder
    private var destinationCell: some View {
        switch operation.kind {
        case .alreadyPlaced:
            Text("已在目标位置")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.positive)
                .lineLimit(1)
        case .skipped:
            Text(operation.destinationPath ?? "—")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .trash:
            Text("移入系统回收站")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.danger)
        case .move, .rename, .copy:
            VStack(alignment: .leading, spacing: 1) {
                PathLabel(path: operation.destinationPath.map {
                    URL(fileURLWithPath: $0).deletingLastPathComponent().path
                } ?? "", font: .system(size: 10), color: Palette.tertiaryText)
                Text(operation.destinationPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

// MARK: - 执行确认

struct ConfirmationSheet: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool

    private var destructive: [PlanOperation] {
        state.operations.filter { $0.selected && $0.kind == .trash }
    }

    private var mutating: [PlanOperation] {
        state.operations.filter { $0.selected && $0.kind.isMutating }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: destructive.isEmpty ? "checkmark.shield" : "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(destructive.isEmpty ? Palette.accent : Palette.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("确认执行 \(mutating.count) 项改动")
                        .font(.system(size: 15, weight: .semibold))
                    Text(destructive.isEmpty
                         ? "这些操作都可以从「操作日志」里一键撤销。"
                         : "其中包含移入回收站的操作，请逐项核对。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !destructive.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("⚠️ 以下 \(destructive.count) 个文件将被移入系统回收站"
                         + "（可释放 \(state.planSummary.reclaimableLabel)）：")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.danger)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(destructive.prefix(30)) { operation in
                                HStack(spacing: 7) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Palette.danger)
                                    Text(operation.fileName)
                                        .font(.system(size: 10.5, design: .monospaced))
                                    Spacer(minLength: 6)
                                    Text(ByteCountFormatter.string(fromByteCount: operation.fileSize,
                                                                   countStyle: .file))
                                        .font(.system(size: 10, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if destructive.count > 30 {
                                Text("……以及另外 \(destructive.count - 30) 个文件")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(9)
                    }
                    .frame(height: 148)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.danger.opacity(0.06)))
                    Text("文件会进入系统回收站而不是被删除，仍可从回收站手动找回；"
                         + "本次操作也会写入日志，可在「操作日志」页整批撤销。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            let moves = state.operations.filter { $0.selected && ($0.kind == .move || $0.kind == .rename) }
            if !moves.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("文件搬运：\(moves.count) 个，涉及 \(state.planSummary.moveBytesLabel)")
                        .font(.system(size: 12, weight: .semibold))
                    Text(state.rule.transferMode == .move
                         ? "执行后源位置不再保留这些文件。"
                         : "执行后源文件保持不变。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if !state.planWarnings.isEmpty {
                let shownWarnings = Array(state.planWarnings.prefix(4))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shownWarnings.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 6) {
                            Circle().fill(Palette.caution).frame(width: 4, height: 4).padding(.top, 5)
                            Text(shownWarnings[index])
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(destructive.isEmpty ? "确认执行" : "确认执行并移入回收站") {
                    isPresented = false
                    Task { await state.executePlan() }
                }
                .buttonStyle(.borderedProminent)
                .tint(destructive.isEmpty ? Palette.accent : Palette.danger)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620)
    }
}
