// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MediaCurator",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MediaCurator", targets: ["MediaCurator"])
    ],
    targets: [
        .executableTarget(
            name: "MediaCurator",
            path: "Sources/MediaCurator",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            // 必须显式链接 AVKit。SwiftUI 的 `VideoPlayer` 声明在私有框架
            // `_AVKit_SwiftUI` 里，编译器只会自动链接那个私有框架，**不会**顺带
            // 链接 AVKit 本身；而 `VideoPlayer` 内部是 `AVPlayerView`（属 AVKit）的子类，
            // 于是运行时找不到父类，一构造视频播放器就 trap（闪退）。
            // 显式声明后 `otool -L` 里才会出现 AVKit.framework。
            linkerSettings: [.linkedFramework("AVKit")]
        )
    ]
)
