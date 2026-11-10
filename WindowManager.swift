import Cocoa
import Foundation
import CoreGraphics
import ApplicationServices

/// 使用 Accessibility API 调整“当前置顶（焦点）窗口”的位置与大小。
struct WindowManager {
    /// 窗口中心相对目标布局中心的允许偏差（pt）。用于判定「是否真的摆正」。
    /// 2pt 与 `isAtTarget(.narrow)` 的垂直容差一致：手动拖偏后一律先归位，再点才切换模式。
    private static let centerTolerance: CGFloat = 2

    /// 将当前焦点窗口按规则复位到它所在的屏幕。
    ///
    /// 每个 App 会记忆自己的目标比例（宽模式 / 窄模式，见 `WindowMode`）。
    /// - 默认（未记忆）为宽模式：优先用宽模式布局复位。
    /// - 若窗口「已处于当前目标布局」**且**窗口中心落在目标布局的中心范围内，
    ///   说明用户意图是切换比例，则翻转并记忆该 App 的模式，再应用新布局。
    /// - 否则直接按当前模式复位：把窗口归位居中（窄模式还会把被拉伸的高度补齐到上下贴边），
    ///   不翻转模式。窗口被拖到屏幕一侧时属于这种情况。
    static func adjustCurrentWindow() {
        // 需要辅助功能权限；未授权则弹出系统授权提示后返回。
        if !AXIsProcessTrusted() {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as CFString
            let dict: [AnyHashable: Any] = [promptKey: kCFBooleanTrue!]
            let options = NSDictionary(dictionary: dict) as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            return
        }

        // 若上一次动画还没结束，先把它收尾到终点，避免用「中间帧」去判定是否已处于目标布局。
        finishPendingAnimation()

        guard let window = focusedWindow(),
              let frame = getFrame(window) else { return }

        // 目标 App 的 Bundle ID：既用于记忆其窗口比例偏好，也用于「忽略的 App」判定。
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""

        // 「忽略的 App」优先：列表里的 App 完全由「复位」复选框决定，不再叠加面积规则。
        // 未列出的 App 才看面积：宽×高不超过「忽略复位的窗口面积」的窗口不复位，
        // 位置由用户自己摆，点菜单栏图标也不该把它拉成大窗口或切换宽 / 窄模式。
        if let rule = Preferences.ignoredApp(for: bundleID) {
            guard !rule.skipReset else { return }
        } else {
            guard !isIgnoredByArea(frame, for: .reset) else { return }
        }

        // 找到窗口中心所在的屏幕。
        let screen = (NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        // 「左右预留」由「台前调度检测」开关 + 系统台前调度状态共同决定：
        // 开关关闭、或系统台前调度关闭 → 0（宽模式占满可见宽度，不预留）。
        // 竖屏自适应会提前接管布局，完全绕过这个值；
        // 宽模式布局里「最小宽度」的优先级更高，必要时会把这里的预留压缩到 0。
        let margin = Preferences.effectiveMargin

        // 当前 App 记忆的窗口比例模式（默认宽模式）。
        let mode = Preferences.windowMode(for: bundleID)

        // 当前模式对应的目标布局。
        let target = targetFrame(for: mode,
                                 frame: frame,
                                 visible: visible,
                                 screen: screen,
                                 margin: margin)

        // 判断窗口是否已处于当前模式的布局：
        // 宽模式按“宽度 + 水平居中”判定；窄模式按“宽度命中 + 上下铺满可见区”判定（含等比缩小兜底）。
        var atTarget = isAtTarget(mode: mode, frame: frame, visible: visible, screen: screen, margin: margin)
        // 兜底：部分 App（企业微信等）有最小宽度限制，会夹断 AXSize 写入，窗口实际尺寸
        // 永远达不到窄模式目标宽度，`isAtTarget` 的三项判据全部不成立 → 永远判「未摆正」，
        // 每次点击都重复摆正、无法切换回宽模式。这里用「上次写入目标后系统实际呈现的帧」
        // （该 App 在当前模式下的有效布局）做比对：当前帧与它一致（容差 2pt）说明布局
        // 已是本 App 可达到的最终形态，视为已摆正，允许进入切换分支。
        // 用户拖动过窗口时位置对不上，仍走「复位」分支，既有行为不受影响。
        if !atTarget,
           let effective = Preferences.effectiveFrame(mode: mode, for: bundleID),
           abs(frame.origin.x - effective.origin.x) <= 2,
           abs(frame.origin.y - effective.origin.y) <= 2,
           abs(frame.width - effective.width) <= 2,
           abs(frame.height - effective.height) <= 2 {
            atTarget = true
        }
        // 是否「真的摆正」主要看窗口中心在不在目标布局的中心范围内（设计约定）。
        // isAtTarget 的三项判据都不检查水平位置，靠右 640px 的窗口仍会被判「已在窄模式」而直接翻宽；
        // 且 byAspect 是 `||` 兜底、同样不看位置，只在单项里补 x 判定会被它绕过 —— 门禁必须放最外层。
        // 用中心而非左上角 x：窗口宽度被 App 最大尺寸夹断时 x 对不上，但中心仍可能正确，不应误判。
        let centerAligned = isCenterAligned(frame, target: target)
        if atTarget && centerAligned {
            let newMode: WindowMode = (mode == .wide) ? .narrow : .wide
            Preferences.setWindowMode(newMode, for: bundleID)
            let newTarget = targetFrame(for: newMode,
                                        frame: frame,
                                        visible: visible,
                                        screen: screen,
                                        margin: margin)
            applyFrame(window, from: frame, to: newTarget, mode: newMode, bundleID: bundleID)
        } else {
            applyFrame(window, from: frame, to: target, mode: mode, bundleID: bundleID)
        }
    }

    // MARK: - 按面积忽略窗口

    /// 该窗口是否因面积被指定功能路径忽略：面积（宽×高）不超过该功能对应的阈值。
    /// - 自适应居中 → 「忽略自适应居中的窗口面积」
    /// - 手动复位   → 「忽略复位的窗口面积」
    /// 判定用 AX 读到的逻辑尺寸（点 pt），与设置项单位一致；阈值 `0` = 不启用该规则。
    /// iPhone 镜像主窗口 326×719 = 234_394 是默认阈值的基准；调度中心缩略窗口、
    /// 系统小浮层、最小化窗口等同属这一类。
    /// - Note: 只对**未列入「忽略的 App」列表**的 App 生效：列表里的条目由复选框
    ///   显式决定，面积规则不再叠加（否则「不勾选 = 功能生效」会被悄悄覆盖）。
    /// 用「不超过」而非「小于」，保证「这个尺寸及以下」被完整覆盖。
    static func isIgnoredByArea(_ frame: CGRect, for feature: IgnoreFeature) -> Bool {
        let threshold = Preferences.windowAreaThreshold(for: feature)
        guard threshold > 0 else { return false }
        return frame.width * frame.height <= CGFloat(threshold)
    }

    // MARK: - 目标布局计算

    /// 竖屏自适应是否生效：开关打开 且 该屏幕高 > 宽。
    private static func portraitAdaptiveEnabled(for screen: NSScreen) -> Bool {
        Preferences.portraitAdaptive && screen.frame.height > screen.frame.width
    }

    /// 计算给定窗口比例模式下应放置的目标矩形。
    /// 关键原则：无论窗口是否可拉伸，最终结果都「居中」到当前屏幕可用区域。
    static func targetFrame(for mode: WindowMode,
                                    frame: CGRect,
                                    visible: CGRect,
                                    screen: NSScreen,
                                    margin: CGFloat) -> CGRect {
        // 竖屏自适应：不分宽模式 / 窄模式，两种模式共用同一个全宽布局。
        // 宽度直接取显示器宽度、x 取屏幕左边缘，完全绕过 margin（即使开着台前调度也不预留）；
        // 高度占满可见区，不侵入菜单栏 / Dock。
        if portraitAdaptiveEnabled(for: screen) {
            return CGRect(x: screen.frame.minX,
                          y: visible.minY,
                          width: screen.frame.width,
                          height: visible.height)
        }
        switch mode {
        case .wide:
            // 宽模式：先按「左右预留」算宽度，再用「最小宽度」保底，
            // 上下占满可用区域（铺满上下，受 Dock/菜单栏影响的可见区）。
            //
            // margin 由 `Preferences.effectiveMargin` 给出：只有「台前调度检测」开关开启
            // 且系统台前调度确实开启时才非 0，其余情况一律 0。
            //
            // 「最小宽度」优先于「左右预留」：小屏幕上按 margin 预留后的宽度若不足
            // 最小宽度，预留会被自动压缩（左右仍对称、窗口始终水平居中）；压缩到 0 时
            // 窗口顶到可见区左右两边。可见宽本身小于最小宽度时取可见宽，绝不超出屏幕。
            // 数学上：width = max(可见宽 - 2×margin, min(最小宽度, 可见宽))，
            //        x = visible.minX + (visible.width - width) / 2。
            let reservedWidth = max(0, visible.width - margin * 2)
            let floorWidth = min(Preferences.minimumWidth, visible.width)
            let width = max(reservedWidth, floorWidth)
            let x = visible.minX + (visible.width - width) / 2
            return CGRect(x: x,
                          y: visible.minY,
                          width: width,
                          height: visible.height)
        case .narrow:
            // 窄模式：宽度由「窄窗口模式」单选器决定（竖屏自适应时由上面的统一布局接管）。
            // 判定处调用同一个 `Preferences.narrowWidth(for:)`，保持一致。
            // 高度占满可见区（y = visible.minY, height = visible.height），上下顶到菜单栏下沿 / Dock 上沿。
            // 直接按可见高写入，使布局与判定共用同一份精确目标，避免系统夹断高度后居中产生偏移。
            let width = Preferences.narrowWidth(for: screen)
            return centeredFrame(keeping: CGRect(x: 0, y: 0, width: width, height: visible.height), in: visible)
        }
    }

    /// 判断窗口是否已处于指定模式的布局。
    /// - 宽模式：仅按“宽度 + 水平居中”判定，不依赖高度（高度受 Dock 影响不可靠）。
    ///   目标宽度同时受台前调度预留与「最小宽度」保底影响，与布局共用 `targetFrame`，不会不一致。
    /// - 窄模式：宽度命中目标宽度 **且** 垂直方向占满可见区，才算真正到位；
    ///   只满足宽度（例如用户手动拉伸过高度）视为「未摆正」，按当前模式复位补齐上下，不翻转模式。
    ///   另保留「宽高比接近目标比」兜底，覆盖被最大尺寸 / 台前调度等比缩小、系统写不到目标高度的窗口。
    /// - 注意：本函数**不判定窗口中心 / 水平位置**。位置是否到位由 `adjustCurrentWindow`
    ///   的 `isCenterAligned` 门禁统一负责，这样 `byAspect` 兜底也受同一约束。
    /// - Note: App 最小宽度夹断导致目标帧**不可达**的场景，由 `adjustCurrentWindow`
    ///   的「有效布局帧」比对兜底（见 `Preferences.effectiveFrame`），这里不处理。
    static func isAtTarget(mode: WindowMode,
                                   frame: CGRect,
                                   visible: CGRect,
                                   screen: NSScreen,
                                   margin: CGFloat) -> Bool {
        // 竖屏自适应下两种模式的目标布局完全相同，切换模式已无意义：
        // 始终按「未到位」处理，每次触发只把窗口摆正到统一的全宽布局，也不翻转记忆的模式。
        if portraitAdaptiveEnabled(for: screen) { return false }
        switch mode {
        case .wide:
            let wideTarget = targetFrame(for: .wide, frame: frame, visible: visible, screen: screen, margin: margin)
            let widthOK = abs(frame.width.rounded() - wideTarget.width.rounded()) <= 1
            let xOK = abs(frame.origin.x.rounded() - wideTarget.origin.x.rounded()) <= 1
            return widthOK && xOK
        case .narrow:
            let narrowWidth = Preferences.narrowWidth(for: screen)
            // 与布局共用同一个目标帧：宽度命中 + 上下贴合可见区，才算「已摆正」。
            // 手动拉伸过高度时宽度仍对，但 verticalOK 为 false → 视为未到位，
            // 按当前模式复位补齐上下，不翻转到宽模式。
            let narrowTarget = targetFrame(for: .narrow, frame: frame, visible: visible,
                                           screen: screen, margin: margin)
            let byWidth = abs(frame.width - narrowWidth) <= 1
            let verticalOK = abs(frame.height - narrowTarget.height) <= 2
                && abs(frame.origin.y - narrowTarget.origin.y) <= 2
            // 兜底：部分 App（如 Safari）有最大尺寸限制、或台前调度会等比缩小窗口，
            // 此时宽度 / 高度都达不到目标，但宽高比仍接近窄模式目标比，也视为已在窄模式，
            // 否则这类被夹断的窗口永远检测不到“已在窄模式”，无法切回宽模式。
            // 宽度选「屏幕的高度」时，因目标高改用可见高，目标比约为 1.02 而非严格 1:1。
            let byAspect = frame.height > 0 && narrowTarget.height > 0
                && abs(frame.width / frame.height - narrowWidth / narrowTarget.height) <= 0.02
            return (byWidth && verticalOK) || byAspect
        }
    }

    /// 窗口中心是否落在目标布局的中心范围内。
    /// 只有「布局已到位」且「中心也在范围内」才允许翻转模式；否则按当前模式复位归位。
    /// 以中心而非 `origin.x` 为准，兼容被 App 最大尺寸夹断、宽度达不到目标但整体仍居中的窗口。
    /// - Note: 声明为 internal 便于单独验证，不改变运行时行为。
    static func isCenterAligned(_ frame: CGRect, target: CGRect) -> Bool {
        abs(frame.midX - target.midX) <= centerTolerance
            && abs(frame.midY - target.midY) <= centerTolerance
    }

    // MARK: - Accessibility 读取 / 写入

    /// 当前焦点窗口（供 `AdaptiveCenterManager` 复用）。
    static func focusedWindow() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let appRef else { return nil }
        let appElement = appRef as! AXUIElement

        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winRef else { return nil }
        return (winRef as! AXUIElement)
    }

    /// 读取窗口帧，返回 Cocoa 坐标（左下原点）；供 `AdaptiveCenterManager` 复用。
    static func getFrame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef as! AXValue?,
              let sizeVal = sizeRef as! AXValue? else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal, .cgPoint, &point)
        AXValueGetValue(sizeVal, .cgSize, &size)
        // Accessibility 坐标为左上原点、y 向下；转换为 Cocoa 坐标再计算。
        return axToCocoa(CGRect(origin: point, size: size))
    }

    private static func setFrame(_ window: AXUIElement, _ cocoaRect: CGRect) {
        let ax = cocoaToAX(cocoaRect)
        var point = ax.origin
        var size = ax.size
        let posVal = AXValueCreate(.cgPoint, &point)
        let sizeVal = AXValueCreate(.cgSize, &size)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal! as CFTypeRef)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal! as CFTypeRef)
    }

    /// 只写位置、保持窗口当前尺寸不变（避免再次触发尺寸夹断），供 `AdaptiveCenterManager` 复用。
    /// 传进来的矩形仅用其 origin 与 size 做 Cocoa -> AX 的 y 翻转。
    static func setPosition(_ window: AXUIElement, _ cocoaRect: CGRect) {
        var point = cocoaToAX(cocoaRect).origin
        let posVal = AXValueCreate(.cgPoint, &point)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal! as CFTypeRef)
    }

    /// 「贴边后拉伸另一面」：把窗口在垂直方向铺满可见区，保持 x / width 不变。
    ///
    /// 必须**同时写 `AXSize` 与 `AXPosition`** —— Cocoa 坐标下改高度会改变 `origin.y`，
    /// 只写尺寸会让「底部固定、顶部往上长」的窗口往错误方向延伸。
    /// 目标是 `y = visible.minY, height = visible.height`：
    /// - 顶部已贴边（`frame.maxY == visible.maxY`）⇒ AX 左上角 y 不变，只有底边往下长；
    /// - 底部已贴边（`frame.minY == visible.minY`）⇒ 底边不动，顶边往上长。
    /// 供 `AdaptiveCenterManager` 复用；返回目标帧（Cocoa 坐标）供状态记录。
    @discardableResult
    static func setVerticalFill(_ window: AXUIElement, frame: CGRect, visible: CGRect) -> CGRect {
        let target = CGRect(x: frame.origin.x,
                            y: visible.minY,
                            width: frame.width,
                            height: visible.height)
        setFrame(window, target)
        return target
    }

    /// 一次性写入完整目标帧（位置 + 尺寸）并做收尾居中兜底；供 `AdaptiveCenterManager`
    /// 的「首次激活按记忆模式摆正」使用，返回摆正后系统实际呈现的帧。
    ///
    /// 与手动复位共用 `recenterAfterAdjust`：App 夹断尺寸（固定宽度、最大尺寸上限等）时，
    /// 窗口仍会以系统实际给出的尺寸居中，不会停在按目标宽度算出的错误 x 上。
    /// 提供 `mode` / `bundleID` 时，写入完成后回读实际帧并记忆为该模式的有效布局，
    /// 与手动复位共用同一份基准（见 `adjustCurrentWindow` 的有效帧比对）。
    @discardableResult
    static func applyLayout(_ window: AXUIElement, to target: CGRect,
                            mode: WindowMode? = nil, bundleID: String? = nil) -> CGRect {
        setFrame(window, target)
        recenterAfterAdjust(window, target: target)
        if let mode, let bundleID, let actual = getFrame(window) {
            Preferences.setEffectiveFrame(actual, mode: mode, for: bundleID)
        }
        return getFrame(window) ?? target
    }

    // MARK: - 收尾强制居中（兜底）

    /// 调整完成后的兜底：**不判断窗口尺寸能否自由拉伸**，一律再按实际尺寸把窗口摆到居中位置。
    ///
    /// 锚点是「目标布局的中心」：`(target.midX, target.midY)`，窗口保持系统实际给出的尺寸。
    /// 这样对三种布局都成立：宽模式 / 窄模式以可见区中心为锚，竖屏统一全宽布局以屏幕中心为锚。
    ///
    /// 幂等：若尺寸完全按目标生效，算出的帧与目标帧一模一样，正常窗口零副作用；
    /// 若系统 / App 忽略了尺寸请求（固定宽度、最大尺寸上限、台前调度夹断等），
    /// 窗口就会以它真正的尺寸居中，而不是停在按目标宽度算出的错误 x 上。
    /// 只写位置、不改尺寸，避免再次触发尺寸夹断。
    private static func recenterAfterAdjust(_ window: AXUIElement, target: CGRect) {
        guard let actual = getFrame(window) else { return }
        let centered = CGRect(x: target.midX - actual.width / 2,
                              y: target.midY - actual.height / 2,
                              width: actual.width,
                              height: actual.height)
        // 位置本来就居中时不再写，避免无意义的 AX 调用。
        guard abs(centered.origin.x - actual.origin.x) > 1
                || abs(centered.origin.y - actual.origin.y) > 1 else { return }
        setPosition(window, centered)
    }

    // MARK: - 平滑变化（逐帧动画）

    /// 正在进行的动画。保存目标帧，供中途再次触发时先「跳到终点」再判定。
    /// `onFinish` 在动画真正到位后调用（含被 `finishPendingAnimation` 提前收尾的情况），
    /// 用于回读并记忆有效布局帧。
    private static var pendingAnimation: (window: AXUIElement, target: CGRect, timer: Timer,
                                          onFinish: (() -> Void)?)?

    /// 按开关决定立即设置还是平滑过渡；两种方式到位后都强制做一次收尾居中（兜底）。
    /// - Parameters:
    ///   - mode / bundleID: 提供时，布局到位（含收尾居中）后回读系统实际呈现的帧，
    ///     记忆为该 App 在该模式下的有效布局，供下一次「已摆正」判定兜底
    ///     （App 夹断尺寸时目标帧永远不可达）。
    private static func applyFrame(_ window: AXUIElement, from: CGRect, to: CGRect,
                                   mode: WindowMode? = nil, bundleID: String? = nil) {
        let rememberEffective: () -> Void = {
            guard let mode, let bundleID, let actual = getFrame(window) else { return }
            Preferences.setEffectiveFrame(actual, mode: mode, for: bundleID)
        }
        if Preferences.smoothAnimation {
            animateFrame(window, from: from, to: to,
                         durationMs: Preferences.animationDurationMs,
                         onFinish: rememberEffective)
        } else {
            setFrame(window, to)
            recenterAfterAdjust(window, target: to)
            rememberEffective()
        }
    }

    /// 若上一次动画尚未结束，立即结束并把窗口设到它的终点。
    /// 这样随后读到的帧是完整的目标布局，「是否已在目标」的判定不会被中间帧干扰。
    private static func finishPendingAnimation() {
        guard let pending = pendingAnimation else { return }
        pending.timer.invalidate()
        pendingAnimation = nil
        setFrame(pending.window, pending.target)
        pending.onFinish?()
    }

    /// 在 durationMs 内，用 ease-in-out 逐帧插值设置窗口的位置与尺寸。
    /// 进度按真实经过时间计算，即使掉帧也能在设定时长内完成。
    private static func animateFrame(_ window: AXUIElement,
                                     from: CGRect,
                                     to: CGRect,
                                     durationMs: Int,
                                     onFinish: (() -> Void)? = nil) {
        finishPendingAnimation()
        let duration = TimeInterval(durationMs) / 1000.0
        guard duration > 0 else {
            setFrame(window, to)
            recenterAfterAdjust(window, target: to)
            onFinish?()
            return
        }

        let startedAt = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { t in
            let progress = min(1, max(0, Date().timeIntervalSince(startedAt) / duration))
            let eased = easeInOut(CGFloat(progress))
            let step = CGRect(
                x: from.origin.x + (to.origin.x - from.origin.x) * eased,
                y: from.origin.y + (to.origin.y - from.origin.y) * eased,
                width: from.width + (to.width - from.width) * eased,
                height: from.height + (to.height - from.height) * eased
            )
            WindowManager.setFrame(window, step)
            if progress >= 1 {
                t.invalidate()
                WindowManager.setFrame(window, to)   // 保证终点精确
                // 动画走完后补最后一步：无条件把窗口按实际尺寸居中（兜底）。
                WindowManager.recenterAfterAdjust(window, target: to)
                WindowManager.pendingAnimation = nil
                onFinish?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingAnimation = (window, to, timer, onFinish)
    }

    /// ease-in-out 二次缓动：起步和收尾慢，中间快。
    private static func easeInOut(_ t: CGFloat) -> CGFloat {
        if t <= 0.5 { return 2 * t * t }
        let u = 1 - t
        return 1 - 2 * u * u
    }

    /// 保持原尺寸，在给定可用区域内居中（窗口比区域大时则左/上对齐，保证不超出边界）。
    private static func centeredFrame(keeping frame: CGRect, in visible: CGRect) -> CGRect {
        var f = frame
        if frame.width <= visible.width {
            f.origin.x = visible.midX - frame.width / 2
        } else {
            f.origin.x = visible.minX
        }
        if frame.height <= visible.height {
            f.origin.y = visible.midY - frame.height / 2
        } else {
            f.origin.y = visible.minY
        }
        return f
    }

    // MARK: - 坐标转换

    /// Cocoa 坐标（左下原点，y 向上）-> Accessibility 坐标（左上原点，y 向下）。
    private static func cocoaToAX(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens[0].frame.height
        return CGRect(x: rect.origin.x,
                      y: primaryHeight - (rect.origin.y + rect.height),
                      width: rect.width,
                      height: rect.height)
    }

    /// Accessibility 坐标 -> Cocoa 坐标。
    private static func axToCocoa(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens[0].frame.height
        return CGRect(x: rect.origin.x,
                      y: primaryHeight - (rect.origin.y + rect.height),
                      width: rect.width,
                      height: rect.height)
    }

}
