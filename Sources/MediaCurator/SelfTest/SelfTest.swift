import Foundation

/// 端到端自检。跑的是真实交付产物里的同一批代码：合成素材 → 扫描 → 查重 → 生成计划 → 执行 → 撤销，
/// 每一步都对结果做断言。
///
/// 之所以要断言而不是「跑完不崩就算过」：查重的准确率、日期解析的时区语义、
/// 撤销的可逆性，这些都不会在「不崩」的前提下暴露问题。
enum SelfTest {

    private final class Checker {
        private(set) var passed = 0
        private(set) var failed = 0
        private(set) var failures: [String] = []

        func check(_ condition: Bool, _ label: String) {
            if condition {
                passed += 1
                print("  ✓ \(label)")
            } else {
                failed += 1
                failures.append(label)
                print("  ✗ \(label)")
            }
        }

        func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
            let ok = actual == expected
            check(ok, ok ? label : "\(label) —— 实际 \(actual)，期望 \(expected)")
        }

        func section(_ title: String) {
            print("\n▸ \(title)")
        }

        var conclusion: String {
            failed == 0 ? "全部通过（\(passed) 项）" : "\(passed) 项通过，\(failed) 项失败"
        }
    }

    static func run() async -> Int32 {
        print("影像管家 · 自检")
        print(String(repeating: "─", count: 64))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mediacurator-selftest-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("media", isDirectory: true)
        let destination = root.appendingPathComponent("organized", isDirectory: true)
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let checker = Checker()

        // 自检会真的执行计划，必须真的写日志；但要把日志目录重定向到临时目录 ——
        // 否则每跑一次自检，用户的「操作日志」页就会多出几条他从未做过的操作。
        JournalStore.overrideDirectory = root.appendingPathComponent("journals", isDirectory: true)

        // ---------- 素材 ----------
        guard FixtureBuilder.build(at: source) else {
            print("素材生成失败，测试中止")
            return 1
        }

        let expectedImageCount = 9
        var expectedVideoCount = 0
        if ToolLocator.hasFFmpeg { expectedVideoCount = 3 }
        let expectedTotal = expectedImageCount + expectedVideoCount
        print("\n已生成素材：\(expectedTotal) 个文件于 \(source.path)")
        if expectedVideoCount == 0 {
            print("未检测到 ffmpeg，视频相关用例将跳过")
        }

        // ---------- 扫描 ----------
        checker.section("扫描与元数据")
        var settings = ScanSettings()
        settings.sourceFolders = [source.path]
        settings.useHashCache = false
        settings.similarityThreshold = 6
        // 素材里包含刻意做出来的纯色小图，体积可能只有几 KB；
        // 自检要覆盖它们，因此关掉体积门槛，避免断言被无关的启发式规则带偏。
        settings.minimumFileSize = 0

        let outcome = await MediaIndexer.index(settings: settings,
                                              cache: FingerprintCache(),
                                              onProgress: { _ in })
        let images = outcome.items.filter { $0.kind == .image }
        let videos = outcome.items.filter { $0.kind == .video }

        checker.equal(outcome.items.count, expectedTotal, "识别到全部媒体文件")
        checker.equal(images.count, expectedImageCount, "图片数量")
        checker.equal(videos.count, expectedVideoCount, "视频数量")
        checker.check(outcome.failures.isEmpty,
                      "全部文件处理成功（失败 \(outcome.failures.count) 个）")

        let byName = Dictionary(uniqueKeysWithValues: outcome.items.map { ($0.fileName, $0) })

        if let item = byName["A_original.jpg"] {
            checker.equal(localFields(item.capturedAt), "2023-05-10 12:00:00", "EXIF 拍摄时间解析")
            checker.equal(item.timeSource, CaptureTimeSource.exif, "时间来源标记为 EXIF")
            checker.equal(item.cameraLabel, "Apple iPhone 13", "设备识别")
            checker.equal(item.resolutionLabel, "1200×800", "像素尺寸")
        } else {
            checker.check(false, "找不到 A_original.jpg")
        }

        if let item = byName["B_original.jpg"] {
            checker.equal(localFields(item.capturedAt), "2024-07-01 08:30:00", "第二台设备拍摄时间")
            checker.equal(item.cameraLabel, "Canon EOS R6", "第二台设备识别")
        } else {
            checker.check(false, "找不到 B_original.jpg")
        }

        if let item = byName["IMG_20220301_101112.jpg"] {
            checker.equal(localFields(item.capturedAt), "2022-03-01 10:11:12", "无 EXIF 时从文件名解析时间")
            checker.equal(item.timeSource, CaptureTimeSource.fileName, "时间来源标记为文件名")
        } else {
            checker.check(false, "找不到 IMG_20220301_101112.jpg")
        }

        if expectedVideoCount > 0, let clip = byName["clip_a.mp4"] {
            checker.equal(localFields(clip.capturedAt), "2024-05-20 08:15:30", "视频容器时间按当地钟表时间解释")
            checker.equal(clip.timeSource, CaptureTimeSource.container, "视频时间来源标记为容器")
            checker.check(clip.videoFrames?.isEmpty == false,
                          "视频抽帧指纹（\(clip.videoFrames?.count ?? 0) 帧）")
        }

        // ---------- 查重 ----------
        checker.section("查重")
        let dedup = await DuplicateDetector.detect(items: outcome.items,
                                                   settings: settings,
                                                   onStatus: { _ in })
        let byID = Dictionary(uniqueKeysWithValues: dedup.items.map { ($0.id, $0) })

        func groupNames(_ group: DuplicateGroup) -> Set<String> {
            Set(group.memberIDs.compactMap { byID[$0]?.fileName })
        }
        func groupKindContaining(_ name: String) -> DuplicateGroup? {
            dedup.groups.first { $0.memberIDs.contains { byID[$0]?.fileName == name } }
        }

        // 精确重复：B 组是纯字节副本
        let exactGroups = dedup.groups.filter { $0.kind == .exact }
        checker.equal(exactGroups.count, 1, "纯字节副本形成一个精确重复组")
        if let group = exactGroups.first(where: { groupNames($0).contains("B_original.jpg") }) {
            checker.equal(groupNames(group), ["B_original.jpg", "B_exact_copy.jpg"],
                          "精确重复组成员正确")
            checker.equal(group.maxDistance, 0, "精确重复的最大距离为 0")
            checker.equal(group.keepIDs.count, 1, "精确重复组默认只推荐保留一份")
        } else {
            checker.check(false, "图片 B 未形成精确重复组")
        }

        // A 组同时含字节副本与缩小版 —— 应合并为一个「相似」分组，而不是各报一次
        let imageGroups = dedup.groups.filter { $0.kind == .similarImage }
        if let group = imageGroups.first(where: { groupNames($0).contains("A_resized.jpg") }) {
            checker.equal(groupNames(group),
                          ["A_original.jpg", "A_exact_copy.jpg", "A_resized.jpg"],
                          "字节副本与缩小版本合入同一分组")
            checker.equal(group.memberIDs.first, byName["A_original.jpg"]?.id,
                          "推荐保留分辨率最高的原始文件")
            checker.equal(group.keepReason, KeepReason.highestResolution, "保留理由为分辨率最高")
            checker.check(group.maxDistance > 0, "相似组记录了最大距离")
        } else {
            checker.check(false, "缩小版本未与原始图片成组")
        }

        // 同一批素材不应在两个分组里各出现一次（否则可释放空间会被重复计算）
        let aGroupAppearances = dedup.groups.filter { groupNames($0).contains("A_original.jpg") }.count
        checker.equal(aGroupAppearances, 1, "同一文件只出现在一个分组里")

        // ---------- 颜色签名（平坦画面误判的唯一防线）----------
        checker.section("颜色签名")

        // 这段断言是补一个真实发生过的漏洞：`colorGrid` 曾经因为 bytesPerRow 与像素
        // 格式不匹配而让 CGContext 创建失败，签名静默变成全 0；于是 colorDistance 永远
        // 是 0、这道校验永远通过，而**当时的自检依然全绿**。
        // 所以必须直接断言签名本身有效，不能只看「两张纯色图没被合并」这种结果 ——
        // 那个结果当时是靠 JPEG 压缩噪声碰巧成立的。
        if let blue = byName["flat_blue.jpg"], let gray = byName["flat_gray.jpg"] {
            let bs = blue.colorSignature ?? []
            let gs = gray.colorSignature ?? []
            checker.check(!bs.isEmpty, "颜色签名非空（\(bs.count) 字节）")
            checker.check(!bs.allSatisfy { $0 == 0 }, "颜色签名不是全零（全零意味着校验失效）")
            checker.check(bs.count == gs.count, "不同图片的签名长度一致")

            let far = PerceptualHash.colorDistance(bs, gs)
            let same = PerceptualHash.colorDistance(bs, bs)
            print(String(format: "  · 蓝 vs 灰 颜色距离 %.1f，蓝 vs 蓝 %.1f（阈值 48）", far, same))
            checker.check(same == 0, "同一颜色自比距离为 0")
            checker.check(far > 48, String(format: "颜色差异大时距离超过阈值（%.1f > 48）", far))
            checker.check(!DuplicateDetector.colorCompatible(blue, gray),
                          "颜色差异大时判为不兼容")
            checker.check(DuplicateDetector.colorCompatible(blue, blue),
                          "颜色一致时判为兼容")
        } else {
            checker.check(false, "找不到纯色图素材")
        }

        // 极端对抗用例：纯绿与近白的 64 位感知哈希**完全相同**（实测距离 0），
        // 只靠哈希必然被并成一组并建议删掉一张。这正是颜色签名存在的理由。
        if let green = FixtureBuilder.solidImage(width: 400, height: 300,
                                                red: 30, green: 180, blue: 60),
           let white = FixtureBuilder.solidImage(width: 400, height: 300,
                                                red: 240, green: 240, blue: 240),
           let greenSig = PerceptualHash.signature(from: green),
           let whiteSig = PerceptualHash.signature(from: white) {
            let distance = PerceptualHash.hamming(greenSig.perceptualHash, whiteSig.perceptualHash)
            print("  · 对抗用例：纯绿 vs 近白的汉明距离 \(distance)，"
                  + String(format: "颜色距离 %.1f",
                           PerceptualHash.colorDistance(greenSig.colorSignature,
                                                        whiteSig.colorSignature)))
            var greenItem = MediaItem(url: URL(fileURLWithPath: "/tmp/fixture-green.png"),
                                      sourceRoot: "/tmp")
            greenItem.colorSignature = greenSig.colorSignature
            greenItem.perceptualHash = greenSig.perceptualHash
            greenItem.width = 400
            greenItem.height = 300
            var whiteItem = MediaItem(url: URL(fileURLWithPath: "/tmp/fixture-white.png"),
                                      sourceRoot: "/tmp")
            whiteItem.colorSignature = whiteSig.colorSignature
            whiteItem.perceptualHash = whiteSig.perceptualHash
            whiteItem.width = 400
            whiteItem.height = 300
            checker.check(!DuplicateDetector.colorCompatible(greenItem, whiteItem),
                          "哈希相同但颜色迥异的两个纯色图不会被判为相似")
        } else {
            checker.check(false, "无法构造纯色对抗用例")
        }

        // 相似但不该合并的反例
        if let group = imageGroups.first(where: { groupNames($0).contains("flat_blue.jpg") }) {
            checker.check(!groupNames(group).contains("flat_gray.jpg"),
                          "纯色图之间的误判被颜色签名拦住")
        } else {
            checker.check(true, "纯色图未产生相似分组")
        }

        if let group = imageGroups.first(where: { groupNames($0).contains("A_different.jpg") }) {
            checker.check(!groupNames(group).contains("A_original.jpg"),
                          "内容不同的图画未与原始图片混为一组")
        } else {
            checker.check(true, "内容不同的画未参与相似分组")
        }

        // 相似视频
        if expectedVideoCount > 0 {
            let videoGroups = dedup.groups.filter { $0.kind == .similarVideo }
            if let group = videoGroups.first(where: { groupNames($0).contains("clip_a.mp4") }) {
                checker.check(groupNames(group).contains("clip_b.mp4"),
                              "同画面不同编码的视频被判为相似")
                checker.check(!groupNames(group).contains("clip_other.mp4"),
                              "不同画面的视频未被误判")
            } else {
                checker.check(false, "相似视频未成组")
            }
        }

        checker.check(dedup.summary.reclaimableBytes > 0, "统计出可释放空间")

        // ---------- 整理计划 ----------
        checker.section("整理计划")

        // 目录模板本身先单独验一遍。预设结构是最容易被改坏的地方，
        // 而且改坏了不会报错，只会把文件静默放进错误的目录。
        if let sample = byName["A_original.jpg"] {
            func renderFolder(_ template: String) -> String {
                let vars = TemplateRenderer.variables(for: sample,
                                                      sequence: 1,
                                                      padding: 3,
                                                      unknownDatePlaceholder: "未识别日期")
                return TemplateRenderer.renderFolderPath(template, variables: vars)
                    .joined(separator: "/")
            }

            // A_original 的拍摄时间是 2023-05-10，设备 Apple iPhone 13，类型 图片
            let expectations: [(String, String)] = [
                ("{yyyy}/{MM}/{MM-dd}/{camera}", "2023/05/05-10/Apple iPhone 13"),
                ("{yyyy}/{MM}/{MM-dd}/{kind}", "2023/05/05-10/图片"),
                ("{yyyy}/{MM}/{MM-dd}", "2023/05/05-10"),
                ("{yyyy}/{MM-dd}/{camera}", "2023/05-10/Apple iPhone 13"),
                ("{yyyy}/{MM-dd}/{kind}", "2023/05-10/图片"),
                ("{yyyy}/{MM-dd}", "2023/05-10"),
                ("{MM-dd}/{camera}", "05-10/Apple iPhone 13"),
                ("{MM-dd}/{kind}", "05-10/图片"),
                ("{MM-dd}", "05-10")
            ]
            for (template, expected) in expectations {
                checker.equal(renderFolder(template), expected, "模板 \(template)")
            }

            checker.equal(OrganizeRule.folderPresets.count, 9, "目录结构预设共 9 种")
            let presetsUseKnownVariables = OrganizeRule.folderPresets.allSatisfy {
                TemplateRenderer.unknownVariables(in: $0.1).isEmpty
            }
            checker.check(presetsUseKnownVariables, "全部预设只用到了已登记变量")
            checker.check(OrganizeRule.folderPresets.contains { $0.1 == OrganizeRule().folderTemplate },
                          "默认模板命中某个预设（首次进入下拉不会显示「自定义」）")
        } else {
            checker.check(false, "找不到用于模板断言的样例文件")
        }
        var rule = OrganizeRule()
        // 用出厂默认模板，顺带覆盖 {MM-dd}
        rule.folderTemplate = "{yyyy}/{MM}/{MM-dd}"
        rule.renameTemplate = "{datetime}_{orig}"
        rule.destinationRoot = destination.path
        rule.conflictPolicy = .autoNumber
        rule.transferMode = .move

        var filter = PlanFilter()
        filter.cleanRedundantDuplicates = false

        let plan = PlanBuilder.build(items: dedup.items,
                                     groups: dedup.groups,
                                     rule: rule,
                                     filter: filter)

        checker.equal(plan.summary.moveCount, expectedTotal, "每个文件都产生了移动操作")
        checker.equal(plan.summary.trashCount, 0, "未开启清理时不应产生删除操作")

        var pathMismatches: [String] = []
        for operation in plan.operations where operation.kind == .move {
            guard let target = operation.destinationPath,
                  let item = dedup.items.first(where: { $0.id == operation.itemID }),
                  let date = item.capturedAt else { continue }
            let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
            // 模板 {yyyy}/{MM}/{MM-dd}
            let expectedDir = String(format: "%04d/%02d/%02d-%02d",
                                     c.year ?? 0, c.month ?? 0, c.month ?? 0, c.day ?? 0)
            if !target.contains(expectedDir) {
                pathMismatches.append("\(item.fileName) → \(target)（期望含 \(expectedDir)）")
            }
        }
        checker.check(pathMismatches.isEmpty,
                      pathMismatches.isEmpty
                        ? "全部目标路径按拍摄日期正确分级"
                        : "目标路径不符合模板：\(pathMismatches.prefix(3).joined(separator: "；"))")

        // 重命名模板生效
        let renamed = plan.operations.filter {
            $0.kind == .move && ($0.destinationPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
                .contains("_A_original") || ($0.destinationPath ?? "").contains("_A_original")
        }
        checker.check(!renamed.isEmpty || plan.operations.contains {
            ($0.destinationPath ?? "").contains("2023-05-10")
        }, "重命名模板按拍摄时间生成文件名")

        // 重复项清理计划
        var cleanFilter = PlanFilter()
        cleanFilter.cleanRedundantDuplicates = true
        cleanFilter.onlyRedundantDuplicates = true
        let cleanPlan = PlanBuilder.build(items: dedup.items,
                                          groups: dedup.groups,
                                          rule: rule,
                                          filter: cleanFilter)
        checker.check(cleanPlan.summary.trashCount >= 2,
                      "清理模式把冗余副本标记为回收站操作（\(cleanPlan.summary.trashCount) 个）")
        checker.check(cleanPlan.operations.allSatisfy { $0.kind == .trash },
                      "清理模式不应夹带文件搬运")

        // 整组保留：该组不再产生任何清理操作，但归档不受影响
        if let victim = dedup.groups.first {
            var modified = dedup.groups
            if let index = modified.firstIndex(where: { $0.id == victim.id }) {
                modified[index].keepWholeGroup = true
            }
            let victimIDs = Set(victim.memberIDs)

            let keptCleanPlan = PlanBuilder.build(items: dedup.items, groups: modified,
                                                  rule: rule, filter: cleanFilter)
            let stillCleaned = keptCleanPlan.operations.filter {
                $0.kind == .trash && victimIDs.contains($0.itemID)
            }
            checker.check(stillCleaned.isEmpty,
                          "整组保留后该组不再产生清理操作（原组 \(victim.memberCount) 个成员）")

            var archiveFilter = PlanFilter()
            archiveFilter.archiveFiles = true
            let keptArchivePlan = PlanBuilder.build(items: dedup.items, groups: modified,
                                                    rule: rule, filter: archiveFilter)
            let archived = keptArchivePlan.operations.filter {
                $0.kind == .move && victimIDs.contains($0.itemID)
            }
            checker.equal(archived.count, victim.memberCount,
                          "整组保留不影响归档，组内成员仍会按规则移动")

            let sizes = Dictionary(dedup.items.map { ($0.id, $0.fileSize) },
                                   uniquingKeysWith: { first, _ in first })
            let before = DedupSummary.compute(groups: dedup.groups, sizes: sizes)
            let after = DedupSummary.compute(groups: modified, sizes: sizes)
            checker.equal(after.reclaimableBytes,
                          before.reclaimableBytes - victim.reclaimableBytes(sizes: sizes),
                          "整组保留后汇总的可释放空间正确减少")
            checker.equal(after.keptWholeGroupCount, 1, "汇总记录了整组保留的组数")
            checker.equal(after.redundantFileCount,
                          before.redundantFileCount - (victim.memberCount - 1),
                          "整组保留后冗余文件数正确减少")
            checker.check(after.totalGroupCount == before.totalGroupCount,
                          "整组保留不改变分组总数")
        } else {
            checker.check(false, "没有可用于整组保留断言的分组")
        }

        // ---------- 保留多选 ----------
        checker.section("保留多选")

        // 取一个 3 成员的组，把保留项从一个改成两个，验证「少清理一份」
        if let base = dedup.groups.first(where: { $0.memberCount >= 3 }) {
            let sizes = Dictionary(dedup.items.map { ($0.id, $0.fileSize) },
                                   uniquingKeysWith: { first, _ in first })

            var multi = dedup.groups
            let index = multi.firstIndex { $0.id == base.id }!
            let firstTwo = Array(base.memberIDs.prefix(2))
            multi[index].keepIDs = Set(firstTwo)

            checker.equal(multi[index].keepCount, 2, "同组可以勾选两个保留项")
            checker.equal(multi[index].removableCount, base.memberCount - 2,
                          "多选后待清理数量相应减少")
            checker.equal(multi[index].reclaimableBytes(sizes: sizes),
                          base.reclaimableBytes(sizes: sizes) - (sizes[firstTwo[1]] ?? 0),
                          "多选后可释放空间相应减少")
            checker.check(!multi[index].allMembersKept, "仍有一部分成员待清理时不算全部保留")

            // 计划里只应剩下未勾选的那些
            var multiFilter = PlanFilter()
            multiFilter.cleanRedundantDuplicates = true
            multiFilter.onlyRedundantDuplicates = true
            let multiPlan = PlanBuilder.build(items: dedup.items, groups: multi,
                                              rule: rule, filter: multiFilter)
            let trashed = multiPlan.operations.filter {
                $0.kind == .trash && base.memberIDs.contains($0.itemID)
            }
            checker.equal(trashed.count, base.memberCount - 2,
                          "计划只为未勾选的成员生成清理操作")
            checker.check(trashed.allSatisfy { !firstTwo.contains($0.itemID) },
                          "被勾选保留的成员一个都不会被清理")
            checker.check(trashed.allSatisfy { $0.reason.contains("等 2 份") },
                          "清理理由标出了同组保留的份数")

            // 全部勾选：等价于不清理
            var allKept = dedup.groups
            allKept[index].keepIDs = Set(base.memberIDs)
            checker.check(allKept[index].allMembersKept, "全部勾选后识别为全部保留")
            checker.equal(allKept[index].removableCount, 0, "全部勾选后不再产生待清理项")
        } else {
            checker.check(false, "没有可用于保留多选断言的 3 成员分组")
        }

        // 危险状态：保留集合为空时**绝不能**把整组都判成冗余
        // （那样清理计划会把原件也移进回收站，属于不可接受的数据损失）
        if let sample = dedup.groups.first {
            var empty = sample
            empty.keepIDs = []
            checker.equal(empty.effectiveKeepIDs.count, 1,
                          "保留集合为空时兜底保留一份")
            checker.check(empty.effectiveKeepIDs.contains(sample.memberIDs[0]),
                          "兜底保留的是组内首个成员")
            checker.equal(empty.removableCount, sample.memberCount - 1,
                          "保留集合为空时待清理数量仍是 成员数-1，而不是全部")
            checker.equal(empty.reclaimableBytes(sizes: [:]),
                          0, "空体积表下可释放空间为 0（不会误报）")
        }

        // ---------- 执行与撤销 ----------
        checker.section("执行与撤销")

        // 先把文件复制到另一个工作区，保证可以反复验证而不破坏素材
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        for item in dedup.items {
            let target = workspace.appendingPathComponent(item.fileName)
            try? FileManager.default.copyItem(at: item.url, to: target)
        }

        var workspaceSettings = ScanSettings()
        workspaceSettings.sourceFolders = [workspace.path]
        workspaceSettings.useHashCache = false
        let workspaceOutcome = await MediaIndexer.index(settings: workspaceSettings,
                                                        cache: FingerprintCache(),
                                                        onProgress: { _ in })

        var execRule = OrganizeRule()
        execRule.folderTemplate = "{yyyy}/{MM}/{yyyy-MM-dd}"
        execRule.renameTemplate = ""
        execRule.destinationRoot = root.appendingPathComponent("output").path
        execRule.conflictPolicy = .autoNumber

        let execPlan = PlanBuilder.build(items: workspaceOutcome.items,
                                         groups: [],
                                         rule: execRule,
                                         filter: PlanFilter())

        let originalPaths = execPlan.operations
            .filter { $0.kind == .move }
            .map { $0.sourcePath }
        checker.equal(originalPaths.count, expectedTotal, "工作区计划行数")

        let report = await PlanExecutor.execute(operations: execPlan.operations)
        checker.equal(report.failed, 0, "执行零失败（\(report.summaryLine)）")
        checker.equal(report.succeeded, expectedTotal, "全部文件执行成功")

        let missing = execPlan.operations.compactMap { operation -> String? in
            guard operation.kind == .move, let target = operation.destinationPath else { return nil }
            return FileManager.default.fileExists(atPath: target) ? nil : target
        }
        checker.check(missing.isEmpty,
                      missing.isEmpty ? "全部文件已出现在目标位置"
                                      : "有 \(missing.count) 个文件未到达目标位置")

        let leftovers = originalPaths.filter { FileManager.default.fileExists(atPath: $0) }
        checker.check(leftovers.isEmpty,
                      leftovers.isEmpty ? "源位置已清空（移动语义正确）"
                                        : "源位置残留 \(leftovers.count) 个文件")

        checker.check(FileManager.default.fileExists(atPath: report.session.filePath ?? ""),
                      "操作日志已落盘")

        // 撤销
        let undo = await PlanExecutor.undo(session: report.session)
        checker.equal(undo.failed, 0, "撤销零失败（\(undo.summaryLine)）")

        let notRestored = originalPaths.filter { !FileManager.default.fileExists(atPath: $0) }
        checker.check(notRestored.isEmpty,
                      notRestored.isEmpty ? "全部文件已还原到原始位置"
                                          : "有 \(notRestored.count) 个文件未还原")

        let stillAtTarget = execPlan.operations.compactMap { operation -> String? in
            guard operation.kind == .move, let target = operation.destinationPath else { return nil }
            return FileManager.default.fileExists(atPath: target) ? target : nil
        }
        checker.check(stillAtTarget.isEmpty,
                      stillAtTarget.isEmpty ? "目标位置已清空（撤销是彻底可逆的）"
                                            : "目标位置残留 \(stillAtTarget.count) 个文件")

        // ---------- 覆盖同名文件（冲突策略）----------
        checker.section("覆盖同名文件")

        // 这条断言补的是「计划说覆盖、执行却一律失败」的不一致：
        // 计划里写着会覆盖，执行器却不认识这个意图，于是每个冲突文件都报
        // 「目标已存在同名文件，未执行」。现在覆盖被实现为「先把原文件移入回收站，
        // 再落位」，所以这里要同时验证三件事：新文件到位、旧文件进了回收站、撤销后两者都回原位。
        let clashSrc = root.appendingPathComponent("clash/src", isDirectory: true)
        let clashDst = root.appendingPathComponent("clash/dst", isDirectory: true)
        try? FileManager.default.createDirectory(at: clashSrc, withIntermediateDirectories: true)
        let clashFolder = clashDst.appendingPathComponent("2022/03/2022-03-01", isDirectory: true)
        try? FileManager.default.createDirectory(at: clashFolder, withIntermediateDirectories: true)

        let clashName = "IMG_20220301_101112.jpg"
        let incoming = byName[clashName]?.url
        let occupant = byName["B_original.jpg"]?.url
        var clashReady = false
        var incomingSize: Int64 = 0
        var occupantSize: Int64 = 0

        if let incoming, let occupant {
            let srcFile = clashSrc.appendingPathComponent(clashName)
            let dstFile = clashFolder.appendingPathComponent(clashName)
            if (try? FileManager.default.copyItem(at: incoming, to: srcFile)) != nil,
               (try? FileManager.default.copyItem(at: occupant, to: dstFile)) != nil {
                incomingSize = sizeOf(srcFile)
                occupantSize = sizeOf(dstFile)
                // 前提必须成立，否则这个用例会变成「目标本来就不存在」的假测试
                clashReady = incomingSize > 0 && occupantSize > 0 && incomingSize != occupantSize
            }
        }
        checker.check(clashReady, "构造出「目标已存在同名文件」且体积不同的场景")

        if clashReady {
            var clashSettings = ScanSettings()
            clashSettings.sourceFolders = [clashSrc.path]
            clashSettings.useHashCache = false
            let clashScan = await MediaIndexer.index(settings: clashSettings,
                                                     cache: FingerprintCache(),
                                                     onProgress: { _ in })

            var clashRule = OrganizeRule()
            clashRule.folderTemplate = "{yyyy}/{MM}/{yyyy-MM-dd}"
            clashRule.renameTemplate = ""
            clashRule.destinationRoot = clashDst.path
            clashRule.conflictPolicy = .overwrite

            let clashPlan = PlanBuilder.build(items: clashScan.items, groups: [],
                                              rule: clashRule, filter: PlanFilter())
            let clashOps = clashPlan.operations.filter { $0.kind.isMutating }
            checker.equal(clashOps.count, 1, "覆盖模式下产生 1 条操作")
            checker.equal(clashOps.first?.overwritesExisting, true,
                          "计划明确标注了「覆盖已存在的同名文件」")
            checker.equal(clashOps.first?.kind, .move, "操作类型为移动")

            let clashTarget = clashOps.first?.destinationPath ?? ""
            checker.check(FileManager.default.fileExists(atPath: clashTarget),
                          "目标位置确实已存在同名文件")

            let clashReport = await PlanExecutor.execute(operations: clashPlan.operations)
            checker.equal(clashReport.failed, 0, "覆盖执行零失败（\(clashReport.summaryLine)）")
            checker.equal(sizeOf(URL(fileURLWithPath: clashTarget)), incomingSize,
                          "新文件已顶替到位（体积与源一致）")

            let displaced = clashReport.session.entries.first {
                $0.kind == .trash && $0.message?.contains("顶替") == true
            }
            checker.check(displaced != nil, "日志记录了被顶替的原文件")
            if let displaced, let trashPath = displaced.trashPath {
                checker.check(FileManager.default.fileExists(atPath: trashPath),
                              "被顶替的文件确实进了回收站（没有不可恢复地删除）")
                checker.equal(sizeOf(URL(fileURLWithPath: trashPath)), occupantSize,
                              "回收站里的正是被顶替的那个文件（体积一致）")
            } else {
                checker.check(false, "被顶替的文件没有记录回收站位置")
            }

            let clashUndo = await PlanExecutor.undo(session: clashReport.session)
            checker.equal(clashUndo.failed, 0, "覆盖后可撤销（\(clashUndo.summaryLine)）")
            checker.equal(sizeOf(clashSrc.appendingPathComponent(clashName)), incomingSize,
                          "撤销后源文件回到原处")
            checker.equal(sizeOf(URL(fileURLWithPath: clashTarget)), occupantSize,
                          "撤销后被顶替的文件也回到原位")
        }

        // ---------- 汇总 ----------
        print("\n" + String(repeating: "─", count: 64))
        print("自检结论：\(checker.conclusion)")
        if checker.failed > 0 {
            print("失败用例：")
            for item in checker.failures { print("  · \(item)") }
        }
        return checker.failed == 0 ? 0 : 1
    }

    // MARK: - 工具

    /// 文件字节数；不存在返回 -1，便于把「文件不在」与「零字节」区分开
    static func sizeOf(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return -1 }
        return size.int64Value
    }

    /// 用本地日历取字段，避免时区解释差异把断言带偏
    static func localFields(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
