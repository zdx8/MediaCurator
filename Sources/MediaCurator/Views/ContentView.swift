import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var state = AppState()

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 214, ideal: 236, max: 290)
        } detail: {
            VStack(spacing: 12) {
                if let notice = state.notice {
                    NoticeBanner(notice: notice) {
                        state.notice = nil
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                pageContent
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .animation(.easeInOut(duration: 0.18), value: state.notice?.id)
            .toolbar {
                // 右上角：界面外观切换
                ToolbarItem(placement: .primaryAction) {
                    ThemeToolbarButton()
                }
            }
        }
        .onAppear { state.loadIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .clearFingerprintCache)) { _ in
            state.handleCacheClearNotification()
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch state.page {
        case .scan: ScanView(state: state)
        case .allMedia: AllMediaView(state: state)
        case .duplicates: DuplicatesView(state: state)
        case .organize: OrganizeView(state: state)
        case .plan: PlanView(state: state)
        case .journal: JournalView(state: state)
        }
    }
}

// MARK: - 侧栏

struct SidebarView: View {
    @ObservedObject var state: AppState
    @State private var showCachePopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            Divider().padding(.horizontal, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(AppPage.allCases) { page in
                        pageRow(page)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }

            Spacer(minLength: 0)
            Divider().padding(.horizontal, 14)
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var brand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    // Logo 用品牌浅蓝（与应用程序图标同色），与界面强调色目前一致
                    .fill(LinearGradient(colors: [Palette.brandBright, Palette.brand, Palette.brandDeep],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "photo.stack")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: Palette.brandDeep.opacity(0.5), radius: 1, y: 0.5)
            }
            .frame(width: 32, height: 32)
            .shadow(color: Palette.brand.opacity(0.28), radius: 4, y: 1.5)

            VStack(alignment: .leading, spacing: 0) {
                Text("影像管家")
                    .font(.system(size: 14, weight: .semibold))
                Text("照片视频整理工具")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func pageRow(_ page: AppPage) -> some View {
        let selected = state.page == page
        return Button {
            state.page = page
        } label: {
            HStack(spacing: 9) {
                Text("\(page.step)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(selected ? .white : Palette.accent)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(selected ? Color.white.opacity(0.28) : Palette.accentSoft))
                Image(systemName: page.symbolName)
                    .font(.system(size: 12.5))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(page.title)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    Text(page.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(selected ? Color.white.opacity(0.78) : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let badge = badge(for: page) {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(selected ? .white : Palette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(selected ? Color.white.opacity(0.22) : Palette.accentSoft))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Palette.accent : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.white : .primary)
    }

    private func badge(for page: AppPage) -> String? {
        switch page {
        case .scan:
            return state.items.isEmpty ? nil : "\(state.items.count)"
        case .allMedia:
            // 只在这个页面里显示「已勾选待清理」的数量：它和「有多少文件」是两回事，
            // 显示总数会让人以为那些文件已经被选中了。
            return state.cleanupSelectedCount > 0 ? "\(state.cleanupSelectedCount)" : nil
        case .duplicates:
            return state.groups.isEmpty ? nil : "\(state.groups.count)"
        case .plan:
            return state.operations.isEmpty ? nil : "\(state.selectedOperationCount)"
        case .journal:
            return state.sessions.isEmpty ? nil : "\(state.sessions.count)"
        case .organize:
            return nil
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                showCachePopover = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 11))
                    Text("指纹缓存")
                        .font(.system(size: 11))
                    Spacer()
                    Text("\(state.cacheEntryCount)")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showCachePopover, arrowEdge: .top) {
                CachePopover(state: state, isPresented: $showCachePopover)
            }

            Text("外观切换在窗口右上角")
                .font(.system(size: 10))
                .foregroundStyle(Palette.tertiaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct CachePopover: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("指纹缓存")
                .font(.system(size: 12.5, weight: .semibold))
            Text("相同文件的元数据与哈希只算一次。缓存按「路径 + 体积 + 修改时间」匹配，"
                 + "文件变了会自动重算。当前已缓存 \(state.cacheEntryCount) 条。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260)
            HStack {
                Spacer()
                Button("清空缓存") {
                    state.clearFingerprintCache()
                    isPresented = false
                }
                .controlSize(.small)
            }
        }
        .padding(14)
    }
}
