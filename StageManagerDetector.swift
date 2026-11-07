import Foundation

/// 检测系统「台前调度 (Stage Manager)」是否开启。
///
/// 这里只回答**系统状态**；「要不要因此预留左右边距」由 `Preferences.effectiveMargin`
/// 结合设置里的「台前调度检测」开关决定（开关关闭时一律不预留）。
struct StageManagerDetector {
    /// 主判据：`com.apple.WindowManager GloballyEnabled`（开启为 1 / 关闭为 0）。
    /// 读到明确值时直接以它为准，不再看其它键 —— `AutoHide` 是「自动隐藏最近使用的应用」
    /// 之类的另一项设置，与台前调度开关无关，拿它兜底会把「台前调度已关」误判成开启。
    /// 主键不存在（旧系统版本 / 从未配置）时才尝试其它候选键；都读不到则按「未开启」处理。
    static func isEnabled() -> Bool {
        if let primary = readDefaults(domain: "com.apple.WindowManager", key: "GloballyEnabled") {
            return isTruthy(primary)
        }
        let fallbacks: [(domain: String, key: String)] = [
            ("NSGlobalDomain", "AppleSpacesWindowManagementStyle"),
            ("com.apple.WindowManager", "AutoHide")
        ]
        for candidate in fallbacks {
            if let value = readDefaults(domain: candidate.domain, key: candidate.key),
               isTruthy(value) {
                return true
            }
        }
        return false
    }

    private static func isTruthy(_ value: String) -> Bool {
        let v = value.lowercased()
        return v == "1" || v == "true"
    }

    /// 用 `/usr/bin/defaults read <domain> <key>` 读系统偏好（能拿到 cfprefsd 之外的最新值）。
    /// - Returns: 读取成功时的字符串；键不存在 / 命令失败时返回 nil。
    private static func readDefaults(domain: String, key: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", domain, key]
        let output = Pipe()
        let error = Pipe()
        task.standardOutput = output
        task.standardError = error
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0,
                  let data = try? output.fileHandleForReading.readToEnd(),
                  let str = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !str.isEmpty else { return nil }
            return str
        } catch {
            return nil
        }
    }
}
