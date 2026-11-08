import Foundation
import AppKit
import CoreGraphics

/// 集中管理 UserDefaults 的键与默认值。
enum Preferences {
    /// 台前调度开启时，窗口左右各预留的宽度（整数，默认 245，允许 0）。
    /// 单位是 macOS 的「点」(pt)＝逻辑分辨率，不是物理像素；Retina 屏 1 点 = 2 物理像素。
    static let marginKey = "stageManagerMargin"

    /// 「左右预留」的默认值（逻辑分辨率 / 点）。设置页初值与读取回落共用，避免两处漂移。
    static let marginDefault = 245
    /// 「台前调度检测」开关（默认开启）：开 → 按系统台前调度状态决定是否预留；关 → 一律不预留。
    static let stageManagerDetectKey = "stageManagerDetectEnabled"
    /// 是否开机自动启动。
    static let launchKey = "launchAtLogin"
    /// 自适应居中开关（常驻监听窗口激活 / 跨屏 / 拖动 / 拉伸）。
    static let adaptiveCenterKey = "adaptiveCenter"
    /// 窄窗口模式的宽度取值方式（见 `NarrowWidthSource`）。
    static let narrowWidthSourceKey = "narrowWidthSource"
    /// 宽模式的最小宽度（整数，逻辑分辨率 / 点，默认 1710；0 = 不启用保底）。
    static let minimumWidthKey = "minimumWidth"
    /// 竖屏自适应开关。
    static let portraitAdaptiveKey = "portraitAdaptive"
    /// 平滑变化开关。
    static let smoothAnimationKey = "smoothAnimation"
    /// 平滑变化时长（毫秒，默认 1000）。
    static let animationDurationKey = "animationDurationMs"
    /// 触控板反馈强度档位（见 `HapticStrength`）。
    static let hapticStrengthKey = "hapticStrength"
    /// 「忽略自适应居中的窗口面积」阈值（宽×高，逻辑分辨率² / 点²；0 = 不启用该规则）。
    static let ignoreAdaptiveCenterAreaKey = "ignoreAdaptiveCenterArea"
    /// 「忽略复位的窗口面积」阈值（宽×高，逻辑分辨率² / 点²；0 = 不启用该规则）。
    static let ignoreResetAreaKey = "ignoreResetArea"
    /// 旧版单一「最小窗口面积」键：仅用于启动时把已有设置迁移到上面两个新键，值保持不变。
    static let legacyMinimumWindowAreaKey = "minimumWindowArea"
    /// 「吸附率」：中心磁吸范围占屏幕可见区宽 / 高的百分比（整数，默认 8，范围 1~20）。
    static let snapRatioKey = "snapRatioPercent"
    /// 「吸附率」默认值（百分数）。
    static let snapRatioPercentDefault = 8
    /// 「忽略的 App」列表（UserDefaults 里存 `[IgnoredApp]` 的 JSON 数据）。
    static let ignoredAppsKey = "ignoredApps"

    /// 读取左右预留（整数，逻辑分辨率 / 点）；未设置时默认 `marginDefault`，非法值收敛到 0~10000。
    /// 允许 0（用户显式设为 0 就是「不预留」），不再把 0 当成未设置而回落到默认值。
    /// 偏好键已写入时一律尊重用户的值，改默认值不会覆盖已有的显式设置。
    static var margin: CGFloat {
        guard UserDefaults.standard.object(forKey: marginKey) != nil else {
            return CGFloat(marginDefault)
        }
        let v = UserDefaults.standard.integer(forKey: marginKey)
        return CGFloat(min(10000, max(0, v)))
    }

    /// 「台前调度检测」开关（默认开启；键未写入过时按默认处理）。
    static var stageManagerDetectEnabled: Bool {
        guard UserDefaults.standard.object(forKey: stageManagerDetectKey) != nil else {
            return stageManagerDetectDefault
        }
        return UserDefaults.standard.bool(forKey: stageManagerDetectKey)
    }

    /// 本次布局实际预留的左右宽度（逻辑分辨率 / 点，宽模式使用）。
    /// - 开关关闭 → 0（不预留）
    /// - 开关开启 且 系统台前调度开启 → `margin`
    /// - 开关开启 但 系统台前调度关闭 → 0（不预留）
    /// - Note: 竖屏自适应的统一全宽布局由 `WindowManager.targetFrame` 提前接管，完全绕过这里。
    static var effectiveMargin: CGFloat {
        guard stageManagerDetectEnabled else { return 0 }
        guard StageManagerDetector.isEnabled() else { return 0 }
        return margin
    }

    /// 「台前调度检测」开关的默认值（默认开启 = 原来三态里的「自动检测」）。
    static let stageManagerDetectDefault = true

    /// 宽模式「最小宽度」的默认值（逻辑分辨率 / 点）。
    static let minimumWidthDefault = 1710

    /// 读取宽模式的最小宽度（整数，逻辑分辨率 / 点）；未设置时默认 1710，非法值收敛到 0~10000。
    /// - `0` = 不启用保底，完全按「左右预留」计算。
    /// - 这是宽模式宽度的**下限**，逻辑优先级高于「左右预留」：屏幕较小时预留会被压缩。
    /// - 窗口宽度不会超过屏幕可见宽（由 `WindowManager.targetFrame` 再夹一次）。
    static var minimumWidth: CGFloat {
        guard UserDefaults.standard.object(forKey: minimumWidthKey) != nil else {
            return CGFloat(minimumWidthDefault)
        }
        let v = UserDefaults.standard.integer(forKey: minimumWidthKey)
        return CGFloat(min(10000, max(0, v)))
    }

    /// 读取窄窗口模式的宽度取值方式；未设置或非法时默认「屏幕宽度的一半」。
    static var narrowWidthSource: NarrowWidthSource {
        let raw = UserDefaults.standard.integer(forKey: narrowWidthSourceKey)
        return NarrowWidthSource(rawValue: raw) ?? .halfScreenWidth
    }

    /// 自适应居中开关的默认值（默认开启）。
    static let adaptiveCenterDefault = true

    /// 自适应居中开关（默认开启；打开时启动常驻窗口监听服务）。
    /// 键未写入过时按默认值处理；用户显式关闭过则保持关闭，不会被重新打开。
    static var adaptiveCenter: Bool {
        guard UserDefaults.standard.object(forKey: adaptiveCenterKey) != nil else {
            return adaptiveCenterDefault
        }
        return UserDefaults.standard.bool(forKey: adaptiveCenterKey)
    }

    /// 首次启动时把默认值写入 UserDefaults，让偏好状态显式可见（`defaults read` 可查）。
    /// 已设置过（含用户手动关闭）时不做任何改动。
    static func registerAdaptiveCenterDefault() {
        if UserDefaults.standard.object(forKey: adaptiveCenterKey) == nil {
            UserDefaults.standard.set(adaptiveCenterDefault, forKey: adaptiveCenterKey)
        }
    }

    /// 竖屏自适应开关（默认关闭；关闭时一切按原有逻辑计算）。
    static var portraitAdaptive: Bool {
        UserDefaults.standard.bool(forKey: portraitAdaptiveKey)
    }

    /// 平滑变化开关（默认关闭；关闭时窗口立即跳到目标帧）。
    static var smoothAnimation: Bool {
        UserDefaults.standard.bool(forKey: smoothAnimationKey)
    }

    /// 平滑变化时长（毫秒）。未设置、或超出 16~60000 时回落到默认 1000。
    static var animationDurationMs: Int {
        let v = UserDefaults.standard.integer(forKey: animationDurationKey)
        return (16...60000).contains(v) ? v : 1000
    }

    /// 触控板反馈强度的默认档位（「强」= 调强后的 `.levelChange` × 2 脉冲，保持既有行为）。
    static let hapticStrengthDefault = HapticStrength.strong.rawValue

    /// 读取触控板反馈强度档位。
    /// 键未写入过时按默认「强」处理 —— `integer(forKey:)` 在键不存在时返回 0（轻），
    /// 直接映射会让旧版本升级后震动突然变弱。
    static var hapticStrength: HapticStrength {
        guard UserDefaults.standard.object(forKey: hapticStrengthKey) != nil else { return .strong }
        return HapticStrength(rawValue: UserDefaults.standard.integer(forKey: hapticStrengthKey)) ?? .strong
    }

    /// 两个面积阈值的共用默认值（宽×高，逻辑分辨率² / 点²）。
    /// 取 iPhone 镜像主窗口 326×719 = 234_394 向上留余量后的 240_000。
    /// 拆分后两项各自独立，但默认都沿用此值，因此升级后行为与旧版「最小窗口面积」完全一致。
    /// 覆盖调度中心缩略窗口、系统小浮层、最小化窗口等。
    static let windowAreaDefault = 240_000

    /// 读取某条功能路径忽略小窗口的面积阈值；键未写入时按默认值，非法值收敛到 0~100000000。
    /// `0` = 不启用该规则（该功能对所有尺寸的窗口都参与）。
    static func windowAreaThreshold(for feature: IgnoreFeature) -> Int {
        let key: String
        switch feature {
        case .adaptiveCenter: key = ignoreAdaptiveCenterAreaKey
        case .reset: key = ignoreResetAreaKey
        }
        guard UserDefaults.standard.object(forKey: key) != nil else { return windowAreaDefault }
        let v = UserDefaults.standard.integer(forKey: key)
        return min(100_000_000, max(0, v))
    }

    /// 首次启动时把旧版单一「最小窗口面积」迁移到拆分后的两个独立阈值。
    /// 两个新键各自判断：已存在（含用户显式设过 0）完全不动；旧键不存在时用默认值播种。
    /// 旧键保留不删，方便回滚到旧版。
    static func registerWindowAreaDefaults() {
        let d = UserDefaults.standard
        let seed = d.object(forKey: legacyMinimumWindowAreaKey) != nil
            ? min(100_000_000, max(0, d.integer(forKey: legacyMinimumWindowAreaKey)))
            : windowAreaDefault
        for key in [ignoreAdaptiveCenterAreaKey, ignoreResetAreaKey] where d.object(forKey: key) == nil {
            d.set(seed, forKey: key)
        }
    }

    /// 读取中心磁吸范围比例（0~1 的小数）；未设置按默认 8%，非法值收敛到 1~20%。
    /// 水平按可见区宽、垂直按可见区高分别计算，窗口中心需同时落在两个范围内才算进入磁吸区。
    static var snapRatio: CGFloat {
        guard UserDefaults.standard.object(forKey: snapRatioKey) != nil else {
            return CGFloat(snapRatioPercentDefault) / 100
        }
        let v = UserDefaults.standard.integer(forKey: snapRatioKey)
        return CGFloat(min(20, max(1, v))) / 100
    }

    /// 窄模式的目标宽度（按「窄窗口模式」单选器）。
    /// - Note: 竖屏自适应的统一全宽布局由 `WindowManager.targetFrame` 提前接管，此处不重复判断竖屏。
    static func narrowWidth(for screen: NSScreen) -> CGFloat {
        narrowWidthSource.width(for: screen)
    }

    // MARK: - 忽略的 App

    /// 内置默认项：iPhone 镜像（`com.apple.ScreenContinuity`，运行时实测的 Bundle ID）。
    /// 「自适应居中」不勾选（居中照常生效），「复位」勾选（点菜单栏图标不把它拉成大窗口）。
    static let ignoredAppsDefault: [IgnoredApp] = [
        IgnoredApp(bundleID: "com.apple.ScreenContinuity",
                   name: "iPhone镜像",
                   skipAdaptiveCenter: false,
                   skipReset: true),
    ]

    /// 读取忽略列表。键未写入（老版本升级）或损坏时回落到内置默认项；
    /// 显式存过空数组则保持为空，用户删掉 iPhone 镜像后不会被重新加回来。
    /// 顺带按 Bundle ID 去重，避免手工写偏好造成同一 App 出现多行。
    static var ignoredApps: [IgnoredApp] {
        guard let data = UserDefaults.standard.data(forKey: ignoredAppsKey),
              let apps = try? JSONDecoder().decode([IgnoredApp].self, from: data) else {
            return ignoredAppsDefault
        }
        var seen = Set<String>()
        return apps.filter { !$0.bundleID.isEmpty && seen.insert($0.bundleID).inserted }
    }

    static func setIgnoredApps(_ apps: [IgnoredApp]) {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        UserDefaults.standard.set(data, forKey: ignoredAppsKey)
    }

    /// 首次启动时把默认列表写入 UserDefaults，让偏好状态显式可见（`defaults read` 可查）。
    static func registerIgnoredAppsDefault() {
        if UserDefaults.standard.object(forKey: ignoredAppsKey) == nil {
            setIgnoredApps(ignoredAppsDefault)
        }
    }

    /// 按 Bundle ID 查忽略规则；不在列表里返回 nil。
    /// - Note: **列表优先级高于两个面积阈值** —— 列表里的 App 完全由复选框决定，
    ///   「忽略自适应居中的窗口面积」/「忽略复位的窗口面积」都不再叠加，
    ///   否则「不勾选 = 功能生效」会被按尺寸的一刀切悄悄覆盖。
    ///   未列入列表的 App 由调用方继续走面积规则。
    static func ignoredApp(for bundleID: String) -> IgnoredApp? {
        guard !bundleID.isEmpty else { return nil }
        return ignoredApps.first { $0.bundleID == bundleID }
    }
}

/// 窄窗口模式下窗口宽度的取值方式。
enum NarrowWidthSource: Int {
    /// 屏幕横向分辨率的一半（默认）。
    case halfScreenWidth = 0
    /// 取屏幕高度作为窄模式宽度。
    case screenHeight = 1

    func width(for screen: NSScreen) -> CGFloat {
        switch self {
        case .halfScreenWidth: return screen.frame.width / 2
        case .screenHeight: return screen.frame.height
        }
    }
}

/// 窗口目标比例模式：宽模式（默认）或窄模式。
/// - Note: rawValue 与既有偏好值保持一致，改动会导致已保存的设置失效。
enum WindowMode: Int {
    case wide = 0
    case narrow = 1
}

/// 触控板反馈的「强度」档位。
/// - Note: Apple 的 `NSHapticFeedbackManager` **没有强度参数**，`perform(_:performanceTime:)`
///   只有 3 种 `FeedbackPattern`（`generic` / `alignment` / `levelChange`），实际力度由系统
///   按设备与用户偏好决定。这里用「反馈模式 + 脉冲数」组合出三档可感知的强弱。
enum HapticStrength: Int {
    case light = 0
    case medium = 1
    case strong = 2

    var pattern: NSHapticFeedbackManager.FeedbackPattern {
        switch self {
        case .light: return .alignment      // Apple 刻意做得最轻的「对齐」反馈
        case .medium: return .generic
        case .strong: return .levelChange   // 离散档位变化，更 firm 的 detent
        }
    }

    /// 一次反馈事件内的脉冲数（间隔 80ms）。轻档单脉冲，中 / 强档双脉冲。
    /// 不连发 3 次以上：Apple 警告过度反馈会被当成故障、促使用户彻底关闭触觉反馈。
    var pulseCount: Int {
        switch self {
        case .light: return 1
        case .medium, .strong: return 2
        }
    }
}

extension Preferences {
    private static func modeKey(for bundleID: String) -> String { "windowMode.\(bundleID)" }

    /// 读取某 App 记忆的窗口模式；未记录时默认宽模式。
    static func windowMode(for bundleID: String) -> WindowMode {
        let raw = UserDefaults.standard.integer(forKey: modeKey(for: bundleID))
        return WindowMode(rawValue: raw) ?? .wide
    }

    /// 记忆某 App 的窗口模式（持久化到 UserDefaults）。
    static func setWindowMode(_ mode: WindowMode, for bundleID: String) {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey(for: bundleID))
    }
}

/// 「忽略的 App」列表里的一项。两个布尔量的含义都是**勾选 = 该功能对此 App 不生效**。
/// 以 Bundle ID 为唯一标识（`id`），比显示名稳定：系统本地化名、用户改 App 名都不会失效。
struct IgnoredApp: Codable, Identifiable, Equatable {
    var bundleID: String
    /// 设置界面显示的名称（来自 `NSRunningApplication.localizedName` 或 App 包信息）。
    var name: String
    /// 勾选：自适应居中不生效。
    var skipAdaptiveCenter: Bool
    /// 勾选：手动复位（点菜单栏图标）不生效。
    var skipReset: Bool

    var id: String { bundleID }
}

/// 受忽略列表控制的两条功能路径。
enum IgnoreFeature {
    case adaptiveCenter
    case reset
}
