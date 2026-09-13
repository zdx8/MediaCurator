import SwiftUI
import AppKit

// MARK: - 配色

/// 用明确的 RGB 而不是全部依赖系统语义色：语义色在不同外观下差异过大，
/// 图表与状态标签需要稳定的识别度。
///
/// 「界面强调色」和「品牌色」分成两组令牌。两者目前取同一个浅蓝，
/// 但仍各自独立 —— 它们性质不同（交互反馈 vs 品牌标识），
/// 将来任一方要单独调整时不必再拆一次。`brand` 直接引用 `accent`，
/// 这样两者不可能悄悄漂移。
enum Palette {
    /// 界面强调色（浅蓝）。取值没有更浅是为了白字压上去时仍有足够对比度 ——
    /// 与 macOS 自带强调蓝大致相当。
    static let accent = Color(red: 0.21, green: 0.53, blue: 0.80)
    static let accentSoft = Color(red: 0.21, green: 0.53, blue: 0.80).opacity(0.12)

    /// 品牌浅蓝，用于侧栏 logo 与应用程序图标。
    /// 注意：`Scripts/make_icon.swift` 用的是同一组数值（独立脚本无法引用这里），
    /// 改动这里要同步改那边，否则 App 内 logo 与访达里的图标会不同色。
    static let brand = accent
    static let brandBright = Color(red: 0.40, green: 0.72, blue: 0.93)
    static let brandDeep = Color(red: 0.10, green: 0.34, blue: 0.58)

    /// 语义上的「通过 / 保留 / 已就位」。绿色与浅蓝强调色天然区分得开
    static let positive = Color(red: 0.11, green: 0.42, blue: 0.28)
    static let caution = Color(red: 0.76, green: 0.49, blue: 0.08)
    static let danger = Color(red: 0.73, green: 0.24, blue: 0.23)
    static let neutral = Color(red: 0.42, green: 0.45, blue: 0.50)
    /// `.tertiary` 是 ShapeStyle 而不是 Color，组件参数需要具体类型，这里给一个等价的可自适应颜色
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)

    // 分类色：只用于区分操作类型与重复类型，不参与品牌表达。
    // 「复制」特意用青绿而不是蓝色 —— 蓝色已经被强调色占用了。
    static let indigo = Color(red: 0.35, green: 0.33, blue: 0.68)
    static let teal = Color(red: 0.09, green: 0.55, blue: 0.55)
    static let violet = Color(red: 0.46, green: 0.30, blue: 0.68)

    static func tint(for kind: OperationKind) -> Color {
        switch kind {
        case .move: return accent
        case .rename: return indigo
        case .copy: return teal
        case .trash: return danger
        case .alreadyPlaced: return positive
        case .skipped: return neutral
        }
    }

    static func tint(for kind: DuplicateKind) -> Color {
        switch kind {
        case .exact: return danger
        case .similarImage: return caution
        case .similarVideo: return violet
        }
    }
}

// MARK: - 右上角：界面外观切换

/// 界面外观开关。只有浅色与深色两个状态，所以点一下直接来回切 ——
/// 为一个二值选择弹下拉菜单，反而多出一次点击。
struct ThemeToolbarButton: View {
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue

    /// 当前是否为深色。存储值可能是「跟随系统」，这种时候要看系统实际生效的外观。
    private var isDark: Bool {
        switch AppAppearance(rawValue: appearanceRaw) ?? .system {
        case .dark: return true
        case .light: return false
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    var body: some View {
        Button {
            let next: AppAppearance = isDark ? .light : .dark
            appearanceRaw = next.rawValue
            // 立即生效：NSAppearance 管原生部件，App 层的 preferredColorScheme 管自绘部分
            AppAppearance.apply(next.rawValue)
        } label: {
            // 图标表示「当前」状态，填充表示激活，具体动作交给提示文字
            Image(systemName: isDark ? "moon.fill" : "sun.max")
                .font(.system(size: 12.5, weight: .medium))
        }
        .help(isDark ? "当前为深色界面，点击切换为浅色" : "当前为浅色界面，点击切换为深色")
    }
}

// MARK: - 区块容器

struct SectionCard<Content: View>: View {
    var title: String
    var subtitle: String?
    var symbol: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !title.isEmpty {
                HStack(spacing: 8) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
    }
}

// MARK: - 指标卡

struct StatCard: View {
    var title: String
    var value: String
    var subtitle: String?
    var symbol: String
    var tint: Color = Palette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tint.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(tint.opacity(0.20), lineWidth: 1))
    }
}

// MARK: - 标签

struct TagChip: View {
    var text: String
    var tint: Color = Palette.neutral
    var filled: Bool = true

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(filled ? .white : tint)
            .background(Capsule().fill(filled ? tint : tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(filled ? .clear : tint.opacity(0.35), lineWidth: 1))
    }
}

/// 模板变量提示片，点击可插入到模板里
struct TokenChip: View {
    var token: String
    var hint: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(token)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? Palette.accentSoft.opacity(2) : Color(nsColor: .quaternaryLabelColor).opacity(0.25)))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Palette.accent.opacity(hovering ? 0.6 : 0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(hint)
        .onHover { hovering = $0 }
    }
}

// MARK: - 缩略图

struct ThumbnailView: View {
    var url: URL
    var kind: MediaKind
    var size: CGFloat = 96
    var highlighted: Bool = false
    var dimmed: Bool = false

    @State private var image: NSImage?
    @State private var failed = false
    /// 已经载入（或确认无需再载入）的是哪个 URL。
    ///
    /// 它解决的问题是「先清空、再异步填回」这一对操作：缓存命中时初始值已经是最终画面，
    /// 但 `.task` 一进来就把 `image` 置空，随后的 `await` 又要等下一帧才回填 ——
    /// 真实界面里表现为闪一下，离屏渲染里根本没有下一帧，导出的截图就永远停在空占位符上。
    @State private var loadedURL: URL?

    init(url: URL, kind: MediaKind, size: CGFloat = 96,
         highlighted: Bool = false, dimmed: Bool = false) {
        self.url = url
        self.kind = kind
        self.size = size
        self.highlighted = highlighted
        self.dimmed = dimmed
        // 缓存命中就直接作为初始值，并且标记为「已载入」，让 `.task` 直接跳过。
        let cached = ThumbnailProvider.shared.cachedImage(for: url, maxPixel: max(64, size * 2))
        if let cached {
            _image = State(initialValue: ThumbnailProvider.nsImage(from: cached))
            _loadedURL = State(initialValue: url)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.22))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(dimmed ? 0.45 : 1)
            } else if failed {
                Image(systemName: kind.symbolName)
                    .font(.system(size: size * 0.28))
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }

            if kind == .video {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: size * 0.22))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                        Spacer()
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(highlighted ? Palette.positive : Color(nsColor: .separatorColor),
                          lineWidth: highlighted ? 2.5 : 1))
        .task(id: url) {
            guard loadedURL != url else { return }
            image = nil
            failed = false
            let target = max(64, size * 2)
            if let cg = await ThumbnailProvider.shared.thumbnail(for: url, maxPixel: target) {
                image = ThumbnailProvider.nsImage(from: cg)
            } else {
                failed = true
            }
            loadedURL = url
        }
    }
}

// MARK: - 路径显示

struct PathLabel: View {
    var path: String
    var font: Font = .system(size: 11, design: .monospaced)
    var color: Color = .secondary

    var body: some View {
        Text(path)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(path)
    }
}

// MARK: - 横向条形（分布图）

struct BarRow: View {
    var label: String
    var value: Int
    var maxValue: Int
    var tint: Color = Palette.accent
    var valueFormatter: (Int) -> String = { "\($0)" }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 132, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            GeometryReader { geo in
                let ratio = maxValue > 0 ? CGFloat(value) / CGFloat(maxValue) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.22))
                    Capsule().fill(tint.opacity(0.75))
                        .frame(width: max(3, geo.size.width * ratio))
                }
            }
            .frame(height: 8)
            Text(valueFormatter(value))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
        }
    }
}

// MARK: - 空状态

struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.accent.opacity(0.55))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - 提示条

struct NoticeBanner: View {
    var notice: AppNotice
    var onDismiss: () -> Void

    private var tint: Color {
        switch notice.level {
        case .info: return Palette.accent
        case .success: return Palette.positive
        case .warning: return Palette.caution
        case .failure: return Palette.danger
        }
    }

    private var symbol: String {
        switch notice.level {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(notice.message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(tint.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(tint.opacity(0.28), lineWidth: 1))
    }
}

// MARK: - 页头

struct PageHeader: View {
    var title: String
    var subtitle: String
    var step: Int?
    @ViewBuilder var trailing: () -> AnyView

    init(title: String, subtitle: String, step: Int? = nil,
         @ViewBuilder trailing: @escaping () -> AnyView = { AnyView(EmptyView()) }) {
        self.title = title
        self.subtitle = subtitle
        self.step = step
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let step {
                Text("\(step)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Palette.accent))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

// MARK: - 复选行

struct CheckRow: View {
    var title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                if let subtitle {
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// MARK: - 键值行

struct KeyValueRow: View {
    var key: String
    var value: String
    var mono: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 11.5))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
