import SwiftUI
import AppKit

// MARK: - 入口

/// 显式分流：同一个二进制既能双击启动 GUI，也能被脚本以 `--headless` 驱动做批量处理。
/// 这样自动化测试跑的就是用户实际拿到的那个产物，而不是另编译一份测试代码。
@main
struct MediaCuratorMain {
    static func main() {
        if CommandLine.arguments.contains("--headless") {
            HeadlessRunner.run(arguments: Array(CommandLine.arguments.dropFirst()))
        }
        MediaCuratorApp.main()
    }
}

// MARK: - 应用

struct MediaCuratorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup("影像管家") {
            ContentView()
                .frame(minWidth: 1180, minHeight: 740)
                .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme)
                .onAppear { AppAppearance.apply(appearanceRaw) }
                .onChange(of: appearanceRaw) { _, newValue in AppAppearance.apply(newValue) }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("清空指纹缓存") {
                    NotificationCenter.default.post(name: .clearFingerprintCache, object: nil)
                }
            }
        }
    }
}

extension Notification.Name {
    static let clearFingerprintCache = Notification.Name("MediaCurator.clearFingerprintCache")
}

// MARK: - 外观

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appAppearance"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// 两处都要设：原生部件（标题栏、文件面板）走 NSAppearance，
    /// SwiftUI 自绘部分走 preferredColorScheme，否则会出现上下半截颜色不一致。
    @MainActor
    static func apply(_ raw: String) {
        let appearance = AppAppearance(rawValue: raw) ?? .system
        NSApplication.shared.appearance = appearance.nsAppearance
        for window in NSApplication.shared.windows {
            window.appearance = appearance.nsAppearance
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 非 Xcode 打包的 SwiftUI 应用必须显式声明为常规前台应用，
        // 否则从命令行启动时不会出现在 Dock，也拿不到键盘焦点。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let stored = UserDefaults.standard.string(forKey: AppAppearance.storageKey)
        AppAppearance.apply(stored ?? AppAppearance.system.rawValue)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
