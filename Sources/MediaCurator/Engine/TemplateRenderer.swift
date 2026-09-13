import Foundation

/// 命名/归档模板渲染器。
///
/// 模板使用 `{变量}` 占位；目录模板里的 `/` 表示层级，每一层单独清洗，
/// 因此模板注入的字符不可能逃逸到预期目录之外。
enum TemplateRenderer {

    private static let localCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }()

    // MARK: - 变量表

    static func variables(for item: MediaItem,
                          sequence: Int,
                          padding: Int,
                          unknownDatePlaceholder: String) -> [String: String] {
        var vars: [String: String] = [:]

        let sourceFolder = URL(fileURLWithPath: item.sourceRoot).lastPathComponent
        vars["sourceFolder"] = sourceFolder.isEmpty ? "根目录" : sourceFolder
        vars["kind"] = item.kind.displayName
        vars["ext"] = item.url.pathExtension.lowercased()
        vars["orig"] = item.url.deletingPathExtension().lastPathComponent
        // 补零位数会被拼进格式串，必须夹住上下界：界面 Stepper 限制在 1–8，
        // 但规则是从偏好设置里反序列化来的，手改 plist 就能塞进一个天文数字，
        // 那种格式串会让 String(format:) 产生荒谬的输出（甚至直接崩）。
        let safePadding = min(12, max(1, padding))
        vars["seq"] = String(format: "%0\(safePadding)d", max(0, sequence))
        vars["hash8"] = PathTools.shortHash(item)
        vars["camera"] = item.cameraLabel
        vars["make"] = item.make ?? "未知厂商"
        vars["model"] = item.model ?? "未知型号"
        vars["lens"] = item.lens ?? "未知镜头"

        if let date = item.capturedAt {
            let c = localCalendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second, .weekOfYear], from: date)
            let y = c.year ?? 0
            let mo = c.month ?? 1
            let d = c.day ?? 1
            let h = c.hour ?? 0
            let mi = c.minute ?? 0
            let s = c.second ?? 0
            vars["yyyy"] = String(format: "%04d", y)
            vars["yy"] = String(format: "%02d", y % 100)
            vars["MM"] = String(format: "%02d", mo)
            vars["dd"] = String(format: "%02d", d)
            vars["HH"] = String(format: "%02d", h)
            vars["mm"] = String(format: "%02d", mi)
            vars["ss"] = String(format: "%02d", s)
            // 复合变量：模板里直接写 {yyyy-MM-dd} 时，解析器会整体取出 "yyyy-MM-dd" 作为
            // 变量名去查表，所以这类组合必须显式登记，不能指望逐段替换。
            vars["yyyy-MM-dd"] = String(format: "%04d-%02d-%02d", y, mo, d)
            vars["yyyy-MM"] = String(format: "%04d-%02d", y, mo)
            vars["MM-dd"] = String(format: "%02d-%02d", mo, d)
            vars["yyyyMMdd"] = String(format: "%04d%02d%02d", y, mo, d)
            vars["HHmmss"] = String(format: "%02d%02d%02d", h, mi, s)
            vars["yyyyMMdd_HHmmss"] = String(format: "%04d%02d%02d_%02d%02d%02d", y, mo, d, h, mi, s)
            vars["yyyy-MM-dd_HH-mm-ss"] = String(format: "%04d-%02d-%02d_%02d-%02d-%02d", y, mo, d, h, mi, s)
            vars["yyyy年MM月dd日"] = String(format: "%04d年%02d月%02d日", y, mo, d)
            vars["yyyy年MM月"] = String(format: "%04d年%02d月", y, mo)
            vars["date"] = String(format: "%04d-%02d-%02d", y, mo, d)
            vars["time"] = String(format: "%02d-%02d-%02d", h, mi, s)
            vars["datetime"] = String(format: "%04d-%02d-%02d_%02d-%02d-%02d", y, mo, d, h, mi, s)
            vars["weekNumber"] = String(format: "%02d", c.weekOfYear ?? 1)
        } else {
            // 时间未知时全部落到占位值，避免生成 "0000-00-00" 这种目录名
            for key in ["yyyy", "yy", "MM", "dd", "HH", "mm", "ss",
                        "yyyy-MM-dd", "yyyy-MM", "MM-dd",
                        "yyyyMMdd", "HHmmss", "yyyyMMdd_HHmmss", "yyyy-MM-dd_HH-mm-ss",
                        "yyyy年MM月dd日", "yyyy年MM月",
                        "date", "time", "datetime", "weekNumber"] {
                vars[key] = unknownDatePlaceholder
            }
        }

        return vars
    }

    // MARK: - 渲染

    /// 替换模板中的 `{变量}`。未知变量原样保留，便于用户发现拼写错误。
    static func render(_ template: String, variables: [String: String]) -> String {
        guard template.contains("{") else { return template }
        var output = ""
        output.reserveCapacity(template.count + 16)

        var index = template.startIndex
        while index < template.endIndex {
            let char = template[index]
            if char == "{", let close = template[index...].firstIndex(of: "}") {
                let name = String(template[template.index(after: index)..<close])
                if let value = variables[name] {
                    output += value
                } else {
                    output += "{" + name + "}"
                }
                index = template.index(after: close)
            } else {
                output.append(char)
                index = template.index(after: index)
            }
        }
        return output
    }

    /// 渲染目录模板。按 `/` 切层，每层独立清洗后重新拼接。
    static func renderFolderPath(_ template: String,
                                 variables: [String: String]) -> [String] {
        let raw = render(template, variables: variables)
        return raw
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { PathTools.sanitizeComponent(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// 渲染文件名模板，结果作为单一文件名的组成部分（不含扩展名）
    static func renderFileName(_ template: String,
                               variables: [String: String]) -> String {
        let raw = render(template, variables: variables)
        return PathTools.sanitizeComponent(raw, maxLength: 180)
    }

    /// 校验模板：返回未知变量列表
    static func unknownVariables(in template: String) -> [String] {
        let known = Set(OrganizeRule.templateVariables.map { $0.0 })
        var unknown: [String] = []
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{", let close = template[index...].firstIndex(of: "}") {
                let name = "{" + String(template[template.index(after: index)..<close]) + "}"
                if !known.contains(name) && !unknown.contains(name) { unknown.append(name) }
                index = template.index(after: close)
            } else {
                index = template.index(after: index)
            }
        }
        return unknown
    }
}
