import SwiftUI
import AppKit

struct JournalView: View {
    @ObservedObject var state: AppState
    @State private var selectedSessionID: String?
    @State private var pendingUndo: JournalSession?
    @State private var showingUndoConfirm = false

    private var selectedSession: JournalSession? {
        guard let id = selectedSessionID else { return state.sessions.first }
        return state.sessions.first { $0.id == id } ?? state.sessions.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "操作日志", subtitle: "每一次执行都有完整记录，可原路撤销", step: 5) {
                AnyView(
                    HStack(spacing: 9) {
                        Button {
                            state.sessions = JournalStore.loadSessions()
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.regular)

                        Button {
                            NSWorkspace.shared.open(JournalStore.directory)
                        } label: {
                            Label("日志目录", systemImage: "folder")
                        }
                        .controlSize(.regular)
                    }
                )
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if state.sessions.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath",
                           title: "还没有执行记录",
                           message: "在「执行计划」页确认执行后，每一步操作都会记录在这里，"
                               + "并且可以整批撤销。",
                           actionTitle: "去查看计划",
                           action: { state.page = .plan })
            } else {
                HStack(alignment: .top, spacing: 14) {
                    sessionList
                        .frame(width: 306)
                    detailPane
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
        .confirmationDialog("撤销这次执行？",
                            isPresented: $showingUndoConfirm,
                            titleVisibility: .visible) {
            Button("撤销", role: .destructive) {
                if let session = pendingUndo {
                    Task { await state.undo(session) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let session = pendingUndo {
                Text("将把 \(session.entries.filter { $0.result == .success && !$0.undone }.count) "
                     + "项改动全部还原：移动过的文件回到原位置，回收站里的文件被取回。"
                     + "撤销完成后需要重新扫描。")
            }
        }
    }

    // MARK: - 会话列表

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(state.sessions) { session in
                    sessionRow(session)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func sessionRow(_ session: JournalSession) -> some View {
        let selected = selectedSession?.id == session.id
        return Button {
            selectedSessionID = session.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "clock")
                        .font(.system(size: 10.5))
                        .foregroundStyle(selected ? .white : Palette.accent)
                    Text(DateFormat.display(session.startedAt))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(selected ? .white : .primary)
                    Spacer(minLength: 4)
                    if session.undoneCount > 0 {
                        TagChip(text: "已撤销 \(session.undoneCount)",
                                tint: selected ? .white.opacity(0.9) : Palette.neutral)
                    }
                }

                HStack(spacing: 8) {
                    piece("成功 \(session.successCount)",
                          tint: selected ? .white : Palette.positive)
                    if session.failedCount > 0 {
                        piece("失败 \(session.failedCount)",
                              tint: selected ? .white : Palette.danger)
                    }
                    if session.reclaimedBytes > 0 {
                        piece("释放 " + ByteCountFormatter.string(fromByteCount: session.reclaimedBytes,
                                                                countStyle: .file),
                              tint: selected ? .white : Palette.caution)
                    }
                    Spacer(minLength: 0)
                }

                Text("共 \(session.entries.count) 条记录")
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Palette.tertiaryText)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Palette.accent : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? .clear : Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func piece(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, design: .rounded))
            .foregroundStyle(tint)
    }

    // MARK: - 明细

    @ViewBuilder
    private var detailPane: some View {
        if let session = selectedSession {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("执行于 \(DateFormat.display(session.startedAt))")
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(session.successCount) 项成功 · \(session.failedCount) 项失败"
                             + (session.reclaimedBytes > 0
                                ? " · 释放 " + ByteCountFormatter.string(fromByteCount: session.reclaimedBytes,
                                                                        countStyle: .file)
                                : ""))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    if session.canUndo {
                        Button {
                            pendingUndo = session
                            showingUndoConfirm = true
                        } label: {
                            Label("撤销这次执行", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.caution)
                        .controlSize(.regular)
                    } else {
                        Label(session.undoneCount > 0 ? "已撤销" : "无可撤销的操作",
                              systemImage: session.undoneCount > 0 ? "checkmark.circle" : "minus.circle")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }

                if let path = session.filePath {
                    HStack(spacing: 7) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        PathLabel(path: path, color: Palette.tertiaryText)
                        Spacer()
                    }
                }

                entryTable(session)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
        } else {
            EmptyState(symbol: "doc.text.magnifyingglass",
                       title: "选择左侧的一条记录",
                       message: "查看该次执行的每一步操作明细。")
        }
    }

    private func entryTable(_ session: JournalSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("时间").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
                Text("操作").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)
                Text("文件").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("目标 / 说明").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 268, alignment: .leading)
                Text("结果").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(session.entries.reversed()) { entry in
                        entryRow(entry)
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: JournalEntry) -> some View {
        let tint: Color = {
            if entry.undone { return Palette.neutral }
            switch entry.result {
            case .success: return Palette.tint(for: entry.kind)
            case .failed: return Palette.danger
            case .skipped: return Palette.neutral
            case .undone: return Palette.neutral
            }
        }()

        return HStack(spacing: 10) {
            Text(timeString(entry.timestamp))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)

            HStack(spacing: 4) {
                Image(systemName: entry.kind.symbolName).font(.system(size: 9.5))
                Text(entry.kind.displayName).font(.system(size: 10.5))
            }
            .foregroundStyle(tint)
            .frame(width: 74, alignment: .leading)

            Text(URL(fileURLWithPath: entry.sourcePath).lastPathComponent)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(entry.sourcePath)

            VStack(alignment: .leading, spacing: 1) {
                if let destination = entry.destinationPath {
                    PathLabel(path: URL(fileURLWithPath: destination).deletingLastPathComponent().path,
                              font: .system(size: 9.5), color: Palette.tertiaryText)
                } else if let message = entry.message {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if entry.destinationPath != nil, let message = entry.message {
                    Text(message)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 268, alignment: .leading)

            Text(entry.undone ? "已撤销" : entry.result.displayName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
    }

    private func timeString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
