import Foundation
import CoreGraphics
import ImageIO
import AppKit

/// 无界面入口。同一个二进制既能双击运行，也能被脚本驱动。
///
/// 之所以让 GUI 应用自带 CLI，是为了让自动化验证跑在**真实交付的产物**上，
/// 而不是另编译一份只在测试里存在的代码。
enum HeadlessRunner {

    static func run(arguments: [String]) -> Never {
        // 输出走管道时默认是块缓冲，进程一旦异常终止就会丢掉全部日志。
        // 关掉缓冲，任何情况下都能看到已经打印到哪一步。
        setvbuf(stdout, nil, _IONBF, 0)

        let exitCode = Box<Int32>(1)
        let finished = Box(false)

        Task {
            exitCode.wrappedValue = await dispatch(arguments)
            finished.wrappedValue = true
        }

        // 不用 dispatchMain()：它与 Swift 并发的「主队列排空」机制不兼容，
        // 会导致 MainActor 与 DispatchQueue.main.sync 双双失效甚至死锁。
        // 改用主 RunLoop 泵，主队列与 MainActor 都由它驱动。
        while !finished.wrappedValue {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        exit(exitCode.wrappedValue)
    }

    private static let quietProgress: ProgressHandler = { _ in }

    private static func dispatch(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first(where: { !$0.hasPrefix("--") }) ?? arguments.first else {
            printUsage()
            return 2
        }
        let rest = arguments

        switch command {
        case "selftest":
            return await SelfTest.run()
        case "uicheck":
            let dir = value(of: "--dir", in: rest)
                ?? NSTemporaryDirectory() + "mediacurator-uicheck"
            let root = URL(fileURLWithPath: dir)
            try? FileManager.default.removeItem(at: root)
            guard FixtureBuilder.build(at: root) else {
                print("素材生成失败")
                return 1
            }
            let shots = value(of: "--shots", in: rest).map { URL(fileURLWithPath: $0) }
            return await UIRenderCheck.run(fixtureRoot: root, shotsDirectory: shots)
        case "fixtures":
            let dir = value(of: "--dir", in: rest) ?? NSTemporaryDirectory() + "mediacurator-fixtures"
            return FixtureBuilder.build(at: URL(fileURLWithPath: dir)) ? 0 : 1
        case "scan":
            return await scan(paths: positional(in: rest), printJSON: rest.contains("--json"))
        case "dedup":
            return await dedup(paths: positional(in: rest))
        case "organize":
            return await organize(arguments: rest)
        case "help", "--help", "-h":
            printUsage()
            return 0
        default:
            print("未知命令：\(command)")
            printUsage()
            return 2
        }
    }

    // MARK: - 参数解析

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func positional(in args: [String]) -> [String] {
        var out: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if arg.hasPrefix("--") {
                if ["--dir", "--dest", "--template", "--rename", "--threshold"].contains(arg) { skipNext = true }
                continue
            }
            if arg == "scan" || arg == "dedup" || arg == "organize" { continue }
            out.append(arg)
        }
        return out
    }

    private static func printUsage() {
        print("""
        影像管家 · 无界面模式

          MediaCurator --headless selftest
              生成测试素材并跑完整的 扫描→查重→计划→执行→撤销 闭环自检

          MediaCurator --headless uicheck
              离屏渲染全部页面，校验绘图内容、页面差异、主题与缩略图管线

          MediaCurator --headless fixtures --dir <目录>
              只生成测试素材

          MediaCurator --headless scan <目录>... [--json]
              扫描并输出统计

          MediaCurator --headless dedup <目录>...
              扫描并输出重复分组

          MediaCurator --headless organize <源目录> --dest <目标目录> \\
              [--template "{yyyy}/{MM}/{yyyy-MM-dd}"] [--rename "{datetime}_{orig}"] \\
              [--threshold 6] [--clean-duplicates] [--execute] [--undo]
        """)
    }

    // MARK: - 扫描

    private static func makeSettings(paths: [String], threshold: Int = 6) -> ScanSettings {
        var settings = ScanSettings()
        settings.sourceFolders = paths
        settings.similarityThreshold = threshold
        return settings
    }

    private static func runScan(paths: [String], threshold: Int = 6) async -> (ScanOutcome, DedupResult, FingerprintCache) {
        let cache = FingerprintCache()
        // 自检要的是确定性结果，所以不读也不写缓存
        var settings = makeSettings(paths: paths, threshold: threshold)
        settings.useHashCache = false
        let outcome = await MediaIndexer.index(settings: settings, cache: cache, onProgress: quietProgress)
        let dedup = await DuplicateDetector.detect(items: outcome.items,
                                                   settings: settings,
                                                   onStatus: { _ in })
        return (outcome, dedup, cache)
    }

    private static func scan(paths: [String], printJSON: Bool) async -> Int32 {
        guard !paths.isEmpty else { print("请至少指定一个目录"); return 2 }
        let (outcome, dedup, _) = await runScan(paths: paths)

        let images = outcome.items.filter { $0.kind == .image }.count
        let videos = outcome.items.filter { $0.kind == .video }.count
        let unknown = outcome.items.filter { $0.capturedAt == nil }.count
        let totalBytes = outcome.items.reduce(Int64(0)) { $0 + $1.fileSize }

        print("目录：\(paths.joined(separator: ", "))")
        print("文件：\(outcome.items.count) 个（图片 \(images) · 视频 \(videos)）")
        print("体积：\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
        print("耗时：\(String(format: "%.2f", outcome.elapsed)) 秒")
        if unknown > 0 { print("未识别拍摄时间：\(unknown) 个") }
        if !outcome.failures.isEmpty { print("处理失败：\(outcome.failures.count) 个") }
        print("重复组：\(dedup.summary.totalGroupCount) 组（精确 \(dedup.summary.exactGroupCount) · "
              + "相似图片 \(dedup.summary.similarImageGroupCount) · 相似视频 \(dedup.summary.similarVideoGroupCount)）")
        print("可释放：\(dedup.summary.reclaimableLabel)")

        if printJSON {
            let payload: [String: Any] = [
                "count": outcome.items.count,
                "images": images,
                "videos": videos,
                "bytes": totalBytes,
                "unknownTime": unknown,
                "exactGroups": dedup.summary.exactGroupCount,
                "similarImageGroups": dedup.summary.similarImageGroupCount,
                "similarVideoGroups": dedup.summary.similarVideoGroupCount,
                "reclaimable": dedup.summary.reclaimableBytes
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        }
        return 0
    }

    private static func dedup(paths: [String]) async -> Int32 {
        guard !paths.isEmpty else { print("请至少指定一个目录"); return 2 }
        let (_, dedupResult, _) = await runScan(paths: paths)
        let byID = Dictionary(uniqueKeysWithValues: dedupResult.items.map { ($0.id, $0) })

        for (index, group) in dedupResult.groups.enumerated() {
            print("\n[\(index + 1)] \(group.kind.displayName) · \(group.memberCount) 个成员 · 最大距离 \(group.maxDistance)")
            for id in group.memberIDs {
                guard let item = byID[id] else { continue }
                let mark = id == group.keepID ? "保留" : "冗余"
                print("   \(mark)  \(item.capturedAtLabel)  \(item.resolutionLabel)  "
                      + "\(item.fileSizeLabel)  \(item.path)")
            }
            if let reason = group.keepID {
                print("   推荐保留理由：\(String(describing: group.keepReason.displayName)) → "
                      + "\(byID[reason]?.fileName ?? "")")
            }
        }
        print("\n合计 \(dedupResult.summary.totalGroupCount) 组，冗余 \(dedupResult.summary.redundantFileCount) 个，"
              + "可释放 \(dedupResult.summary.reclaimableLabel)")
        return 0
    }

    // MARK: - 整理

    private static func organize(arguments: [String]) async -> Int32 {
        let paths = positional(in: arguments)
        guard let source = paths.first else { print("请指定源目录"); return 2 }

        var settings = makeSettings(paths: [source],
                                    threshold: Int(value(of: "--threshold", in: arguments) ?? "6") ?? 6)
        settings.useHashCache = false

        let cache = FingerprintCache()
        let outcome = await MediaIndexer.index(settings: settings, cache: cache, onProgress: quietProgress)
        let dedupResult = await DuplicateDetector.detect(items: outcome.items,
                                                         settings: settings,
                                                         onStatus: { _ in })

        var rule = OrganizeRule()
        rule.folderTemplate = value(of: "--template", in: arguments) ?? rule.folderTemplate
        rule.renameTemplate = value(of: "--rename", in: arguments) ?? ""
        rule.destinationRoot = value(of: "--dest", in: arguments) ?? ""
        rule.conflictPolicy = .autoNumber

        var filter = PlanFilter()
        filter.cleanRedundantDuplicates = arguments.contains("--clean-duplicates")

        let built = PlanBuilder.build(items: dedupResult.items,
                                      groups: dedupResult.groups,
                                      rule: rule,
                                      filter: filter)

        print("计划：共 \(built.operations.count) 行")
        let breakdown = "  移动 \(built.summary.moveCount) · 重命名 \(built.summary.renameCount) · 复制 \(built.summary.copyCount) · 回收站 \(built.summary.trashCount) · 已就位 \(built.summary.alreadyPlacedCount) · 跳过 \(built.summary.skippedCount)"
        print(breakdown)
        for warning in built.warnings { print("  ⚠︎ \(warning)") }

        if arguments.contains("--execute") {
            let report = await PlanExecutor.execute(operations: built.operations)
            print("执行结果：\(report.summaryLine)")
            for message in report.messages { print("  ! \(message)") }

            if arguments.contains("--undo") {
                let undo = await PlanExecutor.undo(session: report.session)
                print("撤销结果：\(undo.summaryLine)")
                for message in undo.messages { print("  ! \(message)") }
            }
        } else if arguments.contains("--undo") {
            print("--undo 需要与 --execute 一起使用")
        }
        return 0
    }
}
