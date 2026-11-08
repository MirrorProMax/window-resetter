import Cocoa
import CoreGraphics
import ApplicationServices
import CoreFoundation
import Dispatch

/// 「自适应居中」常驻服务：模拟 iPad 多任务式的窗口自动居中。
///
/// 开关打开时：
/// 1. **首次**激活某个窗口 → 居中到所在屏幕可见区中心。每个窗口维护一份记录：
///    用户之后手动把窗口挪离中心（固定在某一侧），就不再因「激活」而居中；
///    拖回中心或触发磁吸吸附后恢复。窗口销毁后重新打开视为新的首次。
/// 2. 窗口中心所在屏幕变化 → **等光标松开后**才居中到新屏幕可见区中心。
///    拖动过程中一律不写 AXPosition，避免光标还按着时窗口被拽向新屏幕中心产生漂移。
/// 3. 已居中的窗口被手动拉伸 → 尺寸变化后把中心写回，等价于按住 Option 拉伸；
///    未居中的窗口不做任何补偿。**水平（左右）每轮补偿，垂直（上下）每 6 轮补偿一次**
///    （6 × 60ms ≈ 360ms）；窗口某一端已顶到可见区上 / 下边缘时不写垂直位置。
///    这层降频只作用于「用户按住鼠标拉伸」；系统自己的边缘动画见第 9 项，整段禁止写入。
/// 4. 拖动窗口**穿越**中心磁吸范围的边界 —— **进入或离开都震动一下**
///    （反馈强度在设置里三档可选：轻 / 中 / 强，默认「强」），让用户知道窗口刚进 / 刚出范围；
///    进入后松开鼠标 → 吸附到中心。判定只看窗口是否跨越边界，与窗口当前是否已居中、
///    是否被锁定、是否被记录为「用户定位」无关。
/// 5. **例外**：系统级临时浮层完全不参与 —— 菜单栏的控制中心 / 通知中心 / 各类菜单、
///    cmd+空格 呼出的系统级搜索（Spotlight / 聚焦）、Siri 面板等，位置一律由系统自管。
///    识别分三层：显式名单 / 系统自带且非 Dock 常驻进程（见 `isExcluded(_:)`）/
///    `AXSystemDialog` 窗口子角色；并在**取窗口之前**先判系统级 AX 焦点应用 ——
///    否则浮层切换瞬间读不到窗口时会绕过排除、清空状态，关掉浮层后把原窗口误判成首次激活居中。
/// 6. **判定「光标是否松开」**：以全局鼠标事件（down / dragged / up）为主，
///    叠加 `NSEvent.pressedMouseButtons` 的硬件左键状态兜底 —— 系统级拖移有时不给到
///    `leftMouseDown`，只看事件状态会误判成「已松手」而在拖动中提前居中。
/// 7. **贴边后拉伸另一面**：双击窗口上 / 下边缘后，系统只把那一端顶到可见区边缘，
///    另一端不会跟着到底。本服务在检测到「单侧贴边 + 光标已松开 + 帧稳定」后，
///    主动把另一端也拉到对侧边缘，使窗口垂直铺满可见区。
/// 8. **小窗口不参与**：面积不超过「最小窗口面积」阈值（默认 240000，约 iPhone 镜像
///    326×719 = 234394）的窗口，连同调度中心缩略窗口、系统小浮层、最小化窗口等一律透明跳过
///    （不居中、不补偿、不磁吸、不震动、不写位置），且**保持轮询状态** ——
///    退出调度中心回到原窗口时不会被误判为「首次激活」而居中。
///    判定与手动复位共用 `WindowManager.isSmallWindow`；阈值可在设置里改，0 = 不启用。
/// 9. **系统垂直动画会话内一律不写窗口几何**：双击上 / 下边缘后由系统自己跑的
///    「把一端顶到边」动画，特征是「光标已松开 + 高度逐轮变化」。这段会话内**整个轮询不写
///    AXPosition / AXSize**，而不是只跳过某个分支的 y —— 磁吸吸附、贴边补齐、激活/跨屏居中
///    都会写完整两轴位置，任意一个都能把动画拽住。
///    会话用「最近一次变化时刻 + 安静期」延续，覆盖动画缓动接近终点时高度差 <1px 的帧；
///    用户按住鼠标拉伸时 `isPointerHeld` 为真，不进门禁，中心锁定照常工作。
///    会话结束后帧稳定若干轮，再由第 7 项补齐另一端。
///
/// 技术边界：Accessibility API 不能拦截系统拖动 / 拉伸，只能观察结果后补偿，
/// 所以「锁定居中式拉伸」是事后把位置写回去，会有一个轮询间隔内的短暂位移。
/// 除第 7 项的贴边补齐（需要写 `AXSize`）外，本服务一律只写 `AXPosition`。
final class AdaptiveCenterManager {
    static let shared = AdaptiveCenterManager()

    /// 轮询间隔（秒）：检测窗口切换、跨屏、尺寸变化。
    private let pollInterval: TimeInterval = 0.06
    /// 磁吸半径由设置里的「吸附率」决定（见 `Preferences.snapRatio`），
    /// 按屏幕可见区宽 / 高的百分比实时读取，默认 8%。
    /// 判定「已居中」的容差（逻辑分辨率 / 点）。
    private let centerTolerance: CGFloat = 2
    /// 判定「用户手动移动过窗口」的位移阈值：小于它的抖动（如 AX 写入误差）不算。
    private let manualMoveTolerance: CGFloat = 12
    /// 垂直（上下）补偿相对水平（左右）的降频倍数：6 ⇒ 每 6 轮（6 × 60ms ≈ 360ms）才写一次 y。
    /// 这只作用于按住鼠标手动拉伸窗口的场景，
    /// 系统自己的边缘动画由下面的「垂直动画安静期」整段禁止写入。
    private let verticalCompensationDivisor = 6
    /// 「系统垂直动画会话」的安静期（秒）：最近一次「松手且高度在变」之后的这段时间内，
    /// 整轮不写任何窗口几何。0.35s 覆盖动画缓动收尾（高度差 <1px 的帧不再误判为动画结束），
    /// 也给贴边补齐留出稳定的帧。仅影响系统动画，不影响用户按住鼠标的拉伸。
    private let verticalAnimationQuietPeriod: TimeInterval = 0.35
    /// 判定窗口上 / 下端已顶到屏幕可见区边缘的容差（px）。
    private let verticalEdgeTolerance: CGFloat = 2
    /// 系统面板的 AX 子角色：Siri / 聚焦搜索框 / 权限弹窗等系统浮层都是 `AXSystemDialog`，
    /// 普通 App 窗口是 `AXStandardWindow` / `AXDialog`。cmd+空格 的搜索框即此类型。
    /// 这一层只看窗口本身、不依赖进程归属，是排除浮层最稳的兜底。
    private static let systemDialogSubrole = "AXSystemDialog"
    /// 连续多少轮读不到焦点窗口才真正清空状态（5 × 60ms = 300ms）。
    /// 浮层弹出 / 应用切换瞬间 `kAXFocusedApplicationAttribute` 会短暂返回 `cannotComplete`，
    /// 立刻清空状态会让焦点恢复后把原窗口误判成「窗口切换」而重新居中；
    /// 窗口真的关闭（持续读不到）仍按原语义清空。
    private let emptyFocusGrace = 5
    /// 松手事件丢失时的兜底（秒）：超过这么久没有任何拖拽事件就结束拖拽会话。
    /// 是否真的松手仍由 `isPointerHeld` 的硬件按键状态判定，按住不动不会被误判。
    private let dragSessionTimeout: TimeInterval = 5.0
    /// 松手后的稳定宽限（秒）：等系统把跨屏 / 边缘吸附动画的最终位置写完再居中，
    /// 避免用拖动结束瞬间的中间帧算位置。
    private let releaseGrace: TimeInterval = 0.1
    /// 「贴边补齐」要求窗口帧连续稳定的轮数：3 轮 × 60ms ≈ 180ms。
    /// 等系统把双击边缘的动作（可能带动画）跑完再补写尺寸，避免抢在动画中途把窗口拽住。
    private let edgeFillStableThreshold = 3

    /// 窗口在垂直方向贴边的情况（Cocoa 坐标，左下原点；`top` = 靠菜单栏一侧）。
    private enum VerticalEdge {
        case none, top, bottom, both
    }

    // MARK: - 磁吸震动（三档可选）
    /// 反馈模式与脉冲数由设置里的「震动强度」决定（见 `Preferences.hapticStrength` /
    /// `HapticStrength`）：轻 = `.alignment` × 1，中 = `.generic` × 2，
    /// 强 = `.levelChange` × 2（默认，即调强后的既有行为）。
    ///
    /// Apple 的 `perform(_:performanceTime:)` **没有强度参数**，只有 `generic` / `alignment` /
    /// `levelChange` 三种 `FeedbackPattern`，力度由系统按设备与用户偏好决定；这里用
    /// 「模式 + 脉冲数」组合成三档可感知强弱。`.alignment` 是 Apple 刻意最轻的对齐反馈，
    /// `.levelChange` 是更 firm 的离散档位 detent。不连发 3 次以上（Apple 警告过度反馈
    /// 会被当成故障、促使用户彻底关闭触觉反馈）。
    /// 脉冲间隔（秒）：80ms，两下连起来像一次更饱满的反馈，而不是两次独立提示。
    private let hapticPulseInterval: TimeInterval = 0.08
    /// 两次「边界穿越」反馈之间的最短间隔（秒）。窗口正好压在磁吸边界上手抖时，
    /// 会连续进 / 出范围；不加冷却会连震成一片（Apple 也警告过度反馈会被当成故障）。
    /// 0.15s 足够滤掉抖动，又不影响正常拖过边界再拖回来的两次独立反馈。
    private let hapticBoundaryCooldown: TimeInterval = 0.15

    /// 不参与自适应居中的「系统级临时浮层」显式名单。
    ///
    /// 这类窗口（菜单栏控制中心、通知中心、菜单栏下拉菜单、系统搜索、Siri 等）都是点开才创建、
    /// 关掉就消失的面板，位置由系统按菜单栏图标 / 屏幕边缘自管；强行居中会把它拖到可见区正中，
    /// 既挡住原内容又很突兀。名单里的条目依据 `NSRunningApplication` 的进程归属确定；
    /// 名单之外还有一条通用规则（见 `isExcluded(_:)`），不必逐个枚举每个系统后台进程。
    private static let excludedBundleIDs: Set<String> = [
        "com.apple.Spotlight",                          // cmd+空格 系统级搜索
        "com.apple.controlcenter",                      // 菜单栏「控制中心」
        "com.apple.controlcenter.helper",
        "com.apple.notificationcenterui",               // 通知中心
        "com.apple.UserNotificationCenter",             // 通知横幅
        "com.apple.SoftwareUpdateNotificationManager",  // 系统更新提示
        "com.apple.systemuiserver",                     // 菜单栏图标菜单
        "com.apple.MenuBarAgent",
        "com.apple.TextInputMenuAgent",                 // 输入法菜单
        "com.apple.WindowManager",                      // 台前调度侧边条
        "com.apple.dock",
        "com.apple.dock.extra",
        "com.apple.loginwindow",
        "com.apple.universalcontrol",                   // 通用控制
        "com.apple.campo",                              // Siri
    ]
    private static let excludedAppNames: Set<String> = [
        "Spotlight", "聚焦", "控制中心", "控制中心帮助程序", "通知中心",
        "Siri", "程序坞", "程序坞附加项", "登录窗口", "通用控制",
        "SystemUIServer", "MenuBarAgent", "TextInputMenuAgent", "WindowManager",
    ]

    private var enabled = false
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    /// 上一轮轮询的状态。
    private var lastWindow: AXUIElement?
    private var lastFrame: CGRect?
    private var lastScreenID: String = ""
    private var wasCentered = false

    /// 每个窗口一份记录：区分「首次 / 用户已手动定位」，避免把用户固定在一侧的窗口又居中。
    /// 记录只在内存中维护，窗口销毁后由 `pruneDeadRecords()` 清除（重新打开即视为首次）。
    private var records: [WindowRecord] = []
    private var pollCount = 0
    /// 最近一次由本服务写入 AXPosition 的时间；用于把「我们自己挪窗口」排除在用户手动移动之外。
    private var lastAutoWrite = Date.distantPast
    /// 最近一次观察到「系统垂直动画」（光标已松开且窗口高度在变）的时刻。
    /// 用它加安静期把整段动画串成一个会话，避免只看单轮高度差时漏掉缓动收尾的帧。
    private var lastVerticalChangeAt = Date.distantPast

    private var isDragging = false
    /// 最近一次「按下 / 拖动」事件时间；leftMouseUp 丢失时用于兜底结束拖拽会话。
    private var lastDragEventAt = Date.distantPast
    /// 最近一次明确收到松手事件的时刻；跨屏居中要等一小段稳定期再执行。
    private var releasedAt = Date.distantPast
    /// 拖动期间发生过跨屏：挂起居中动作，直到明确松手后再执行。
    /// 有了它，跨屏居中不再依赖「拖动中不更新 lastScreenID」这种隐式状态技巧。
    private var pendingCrossScreen = false
    /// 本次鼠标按下会话是否为「拉伸」（尺寸相对按下时变了），区别于「移动窗口」。
    private var isResizing = false
    private var dragStartFrame: CGRect?
    /// 一次拖拽松手后的待判定信息（哪个窗口、按下时的帧、是不是拉伸）。下一轮轮询再判定，
    /// 避免拖动过程中每一帧都被当成一次「用户手动移动」。
    private var pendingMoveCheck: MoveCheck?
    private var inSnapZone = false
    private var pendingSnap = false
    /// 「贴边补齐」状态机：帧连续稳定的轮数，以及本次贴边会话是否已补写过尺寸。
    /// 贴边状态消失（用户把窗口拖离边缘）后才重置，避免尺寸被 App 夹断时每轮重复写 `AXSize`。
    private var edgeFillStableCount = 0
    private var edgeFillHandled = false
    /// 最近一次「进 / 出磁吸范围」反馈的时间，用于边界抖动冷却。
    private var lastBoundaryHapticAt = Date.distantPast
    /// 连续读不到焦点窗口的轮数（配合 `emptyFocusGrace` 区分瞬时 AX 失败与窗口真的关闭）。
    private var emptyFocusCount = 0

    private init() {}

    // MARK: - 开关

    /// 由 App 启动（读偏好）和设置里的开关（即时）共同调用。
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { start() } else { stop() }
    }

    private func start() {
        if !AXIsProcessTrusted() {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as CFString
            let dict: [AnyHashable: Any] = [promptKey: kCFBooleanTrue!]
            AXIsProcessTrustedWithOptions(NSDictionary(dictionary: dict) as CFDictionary)
        }
        clearState()

        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // 全局鼠标事件（只读）：拖动中判磁吸、松开时判吸附。
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleMouse(event.type)
        }

        // 应用切换时立刻检查一次，不必等下一个轮询周期。
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.poll()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
        clearState()
    }

    private func clearState() {
        lastWindow = nil
        lastFrame = nil
        lastScreenID = ""
        wasCentered = false
        records.removeAll()
        pollCount = 0
        isDragging = false
        lastDragEventAt = Date.distantPast
        releasedAt = Date.distantPast
        pendingCrossScreen = false
        isResizing = false
        dragStartFrame = nil
        pendingMoveCheck = nil
        inSnapZone = false
        pendingSnap = false
        edgeFillStableCount = 0
        edgeFillHandled = false
        lastBoundaryHapticAt = Date.distantPast
        lastVerticalChangeAt = Date.distantPast
        emptyFocusCount = 0
    }

    /// 光标是否仍按着（拖拽会话进行中）——所有「自动居中」写入都用这个判据，不再直接用 `isDragging`。
    ///
    /// 1. 事件层：收到 `leftMouseDown` 到 `leftMouseUp` 之间为按住状态；
    ///    `leftMouseDragged` 会补记会话（系统级拖移可能不给到 down）。
    /// 2. 硬件层：`NSEvent.pressedMouseButtons` 的位 0 是左键，直接问系统当前是否真的按着。
    ///    这样即使 down / up 事件有遗漏，拖动中也不会被误判成「已松手」而提前居中。
    private var isPointerHeld: Bool {
        if isDragging { return true }
        return (NSEvent.pressedMouseButtons & 1) != 0
    }

    // MARK: - 焦点窗口与排除名单

    /// 取当前焦点窗口；系统浮层、以及「小窗口」都返回 nil。
    /// 先在应用级判一次，保证鼠标事件路径（磁吸 / 震动）在浮层期间同样不参与；
    /// 鼠标路径也必须跳过小窗口，否则调度中心里仍会写位置 / 误震动。
    /// 判定与手动复位共用 `WindowManager.isSmallWindow`，避免两条路径口径漂移。
    private func trackedWindow() -> AXUIElement? {
        if isExcludedFocusedApp() { return nil }
        guard let window = WindowManager.focusedWindow(), !isExcludedApp(window) else { return nil }
        if let frame = WindowManager.getFrame(window), WindowManager.isSmallWindow(frame) { return nil }
        return window
    }

    /// **前置**判定：当前「系统级 AX 焦点应用」是否属于排除名单。
    /// 必须在取窗口之前做 —— 浮层弹出 / 消失时可能拿不到焦点窗口，若只依赖窗口归属，
    /// `poll` 会走「读不到窗口」分支清空状态，焦点恢复后原窗口就被误判为「首次激活」而居中。
    private func isExcludedFocusedApp() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
           let appRef {
            var pid: pid_t = 0
            if AXUIElementGetPid(appRef as! AXUIElement, &pid) == .success,
               let app = NSRunningApplication(processIdentifier: pid), isExcluded(app) {
                return true
            }
        }
        // 前台 App 兜底：某些浮层不改变 AX 焦点应用，但会短暂成为前台 App。
        if let front = NSWorkspace.shared.frontmostApplication, isExcluded(front) {
            return true
        }
        return false
    }

    /// 按「窗口子角色」+「窗口 AX 元素所属进程」+「前台 App」三层识别。
    /// 说明：cmd+空格 的搜索框 `subrole = AXSystemDialog`、所属进程是 `com.apple.campo`（Siri），
    /// 而 `frontmostApplication` 仍是原 App —— 所以单看前台 App、或只列 `com.apple.Spotlight` 都会漏判。
    private func isExcludedApp(_ window: AXUIElement) -> Bool {
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let sub = subroleRef as? String, sub == Self.systemDialogSubrole {
            return true
        }
        var pid: pid_t = 0
        if AXUIElementGetPid(window, &pid) == .success,
           let app = NSRunningApplication(processIdentifier: pid), isExcluded(app) {
            return true
        }
        if let front = NSWorkspace.shared.frontmostApplication, isExcluded(front) {
            return true
        }
        return false
    }

    /// 浮层 / AX 瞬时读不到窗口时对状态机保持透明：只丢弃待处理的鼠标动作，
    /// `lastWindow` / `lastFrame` / `wasCentered` / `records` 一律不动。
    private func skipTransiently() {
        pendingSnap = false
        pendingMoveCheck = nil
        inSnapZone = false
    }

    private func isExcluded(_ app: NSRunningApplication) -> Bool {
        let id = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? ""
        if Self.excludedBundleIDs.contains(id) || Self.excludedAppNames.contains(name) { return true }

        let lowerID = id.lowercased()
        let lowerName = name.lowercased()
        // 模糊兜底：不同 macOS 版本里这些浮层的进程名 / bundle ID 可能带后缀，或改成中文名。
        if lowerID.contains("spotlight") || lowerName.contains("spotlight") || name.contains("聚焦")
            || lowerID.contains("controlcenter") || lowerID.contains("notificationcenter")
            || name.contains("控制中心") || name.contains("通知中心") {
            return true
        }

        // 通用规则（覆盖名单之外）：系统自带、且「不出现在 Dock」的进程
        // （activationPolicy = accessory / prohibited），一律按系统级临时浮层处理。
        // 排除依据：控制中心、通知中心、SystemUIServer、MenuBarAgent、Dock、Siri、
        // WindowManager、TextInputMenuAgent 等全部命中；访达 / 系统设置等 regular 系统 App
        // 不受影响；装在 /Applications 的第三方菜单栏工具也不受影响，仍按普通窗口居中。
        if app.activationPolicy != .regular,
           let path = app.bundleURL?.path, path.hasPrefix("/System/") {
            return true
        }
        return false
    }

    // MARK: - 轮询：激活 / 跨屏 / 锁定居中式拉伸

    private func poll() {
        guard enabled else { return }
        // 万一 leftMouseUp 丢失（系统级拖移 / 拖动锁定），结束拖拽会话；
        // 是否真的松手仍由 isPointerHeld 的硬件按键状态判定，按住不动不会被误判。
        if isDragging && Date().timeIntervalSince(lastDragEventAt) > dragSessionTimeout {
            isDragging = false
            isResizing = false
            dragStartFrame = nil
        }
        // 前置判定：浮层（控制中心 / 通知中心 / 聚焦 / Siri 等）在取窗口之前就跳过。
        // 命中时对状态机完全透明 —— 只丢弃待处理的鼠标动作，其它状态一律不动，
        // 关掉浮层回到原窗口时不会被误判为「窗口切换」而重新居中。
        if isExcludedFocusedApp() {
            // 浮层期间视为「焦点正常存在」，不要把之前的瞬时 AX 失败累计进清空计数。
            emptyFocusCount = 0
            skipTransiently()
            return
        }

        guard let window = WindowManager.focusedWindow() else {
            // 浮层切换 / 应用切换瞬间系统级 AX 焦点应用会短暂读不到（返回 cannotComplete）。
            // 连续 emptyFocusGrace 轮都读不到才按「窗口真的关了」清空状态；
            // 否则短暂失败也清空，焦点恢复后就会把原窗口当成首次激活居中。
            emptyFocusCount += 1
            if emptyFocusCount >= emptyFocusGrace {
                lastWindow = nil
                lastFrame = nil
                wasCentered = false
            }
            skipTransiently()
            return
        }
        emptyFocusCount = 0

        // 第二层：窗口本身是系统面板，或属于排除进程时同样透明跳过。
        guard !isExcludedApp(window) else {
            skipTransiently()
            return
        }

        guard let frame = WindowManager.getFrame(window),
              let screen = screen(for: frame) else {
            lastWindow = nil
            lastFrame = nil
            wasCentered = false
            return
        }

        // 小窗口（iPhone 镜像 326×719、调度中心缩略窗口 / 系统小浮层 / 最小化窗口等）：
        // 整个服务透明跳过 —— 不写位置、不补偿、不吸附、不震动；
        // lastWindow / lastFrame / records 一律不动，退出调度中心回到原窗口时
        // 不会被误判为「首次激活」而居中。
        if WindowManager.isSmallWindow(frame) {
            skipTransiently()
            return
        }

        let center = visibleCenter(of: screen)
        let sid = screenID(screen)
        let centeredNow = isCentered(frame, center: center)
        let rec = record(for: window)

        // 定期清理已销毁窗口的记录。活跃窗口的记录一直保留（不管多久没激活），
        // 否则「用户固定在一侧」的窗口会被时间清掉、下次又被当成首次。
        pollCount += 1
        if pollCount % 50 == 0 { pruneDeadRecords() }
        // 水平（左右）补偿每轮都允许；垂直（上下）每 6 轮才允许写一次 y（≈360ms）。
        // 降频只服务于「用户按住鼠标拉伸」；系统自己的边缘动画由下面的整轮门禁接管。
        let allowVerticalCompensation = pollCount % verticalCompensationDivisor == 0
        // 相对上一轮高度是否在变：系统双击边缘把窗口拉到顶的过程带动画，每轮高度都在变。
        // 用 lastFrame（上一轮帧，本轮 commit 尚未写入）判定，不新增持久状态。
        let heightChanging = lastFrame.map { abs($0.height - frame.height) > 1 } ?? false
        // 系统垂直动画 = 光标确实已松开 + 高度在变。
        // 以硬件左键状态 isPointerHeld 为准，不再依赖 isResizing：双击边缘时它可能残留 true，
        // 会让基于 !isResizing 的判据失效；用户按住鼠标拉伸时 isPointerHeld 必为真，不进门禁。
        let systemVerticalAnimation = !isPointerHeld && heightChanging
        if systemVerticalAnimation { lastVerticalChangeAt = Date() }
        // 安静期把动画全程（含缓动收尾时高度差 <1px 的帧）串成一个会话；
        // 会话内整轮不写任何窗口几何，见下面的门禁。
        let verticalAnimationActive =
            Date().timeIntervalSince(lastVerticalChangeAt) < verticalAnimationQuietPeriod

        // 松手后判定「用户是否手动把窗口挪离了中心」：以按下时的帧为基准，
        // 且只认被拖动的那一个窗口；拉伸不改变定位意图，不参与判定。
        if let check = pendingMoveCheck, !isPointerHeld {
            pendingMoveCheck = nil
            let sizeSame = abs(check.start.width - frame.width) <= 1
                && abs(check.start.height - frame.height) <= 1
            let movedFar = abs(check.start.origin.x - frame.origin.x) > manualMoveTolerance
                || abs(check.start.origin.y - frame.origin.y) > manualMoveTolerance
            if sameWindow(check.window, window), !check.resizing, sizeSame, movedFar {
                // 停在中心或磁吸范围内 ⇒ 用户仍想要居中；停在一侧 ⇒ 尊重这个位置。
                let nearCenter = centeredNow || isInSnapZone(frame, center: center, screen: screen)
                rec.userPositioned = !nearCenter
            }
        }

        // ── 系统垂直动画会话门禁 ──────────────────────────────────────
        // 双击上 / 下边缘后，系统自己跑动画把那一端顶到可见区边缘。只在「锁定居中式
        // 拉伸」分支跳过 y，但下面这些分支都会写完整两轴 AXPosition / AXSize：
        //   · pendingSnap（双击松手时窗口本就在中心范围内 → 被误判为吸附）
        //   · pendingCrossScreen、分支 1 / 2 的激活 / 跨屏居中
        //   · setVerticalFill 贴边补齐（写 AXSize）
        // 任意一个都能把系统动画拽住。
        // 因此会话内整轮不写几何，只更新轮询状态；挂起的吸附是双击误触发，直接丢弃；
        // 跨屏挂起保留到会话结束后的下一轮再执行。
        if verticalAnimationActive {
            pendingSnap = false
            commit(window: window, frame: frame, screenID: sid, center: center)
            return
        }

        // 拖动中跨屏被挂起 → 只有明确松手（并等一小段稳定期）后才补一次居中。
        // 用松手后重新读到的最终帧，而不是拖动中的中间帧；这是「跨屏居中」的唯一执行点。
        if pendingCrossScreen, !isPointerHeld,
           Date().timeIntervalSince(releasedAt) >= releaseGrace {
            pendingCrossScreen = false
            // 松手时窗口确实停在另一块屏幕才居中；又拖回原屏则尊重用户摆好的位置。
            if sid != lastScreenID {
                pendingSnap = false
                pendingMoveCheck = nil
                rec.userPositioned = false
                let moved = moveToCenter(window, frame: frame, center: center)
                commit(window: window, frame: moved, screenID: sid, center: center)
                return
            }
        }

        // 松开时落在磁吸范围：下一轮再吸附，等 AX 写入最终位置后更准。
        if pendingSnap && !isPointerHeld {
            pendingSnap = false
            pendingMoveCheck = nil
            pendingCrossScreen = false
            rec.userPositioned = false   // 用户主动吸附到中心 ⇒ 恢复「允许激活居中」
            let moved = moveToCenter(window, frame: frame, center: center)
            commit(window: window, frame: moved, screenID: sid, center: center)
            return
        }

        // 「贴边后拉伸另一面」：双击窗口上 / 下边缘后，系统只把那一端顶到可见区边缘，
        // 另一端仍停在原处（顶部已顶到头、底部没拉到最下面）。
        // 这里在单侧贴边、光标已松开、且窗口帧连续稳定若干轮后，主动把另一端也拉到
        // 对侧边缘，使窗口垂直铺满 visibleFrame；x / width 保持不变，不打扰水平布局。
        //   · 帧稳定是为了等系统的边缘动作（可能带动画）跑完，不抢在动画中途写尺寸；
        //   · 每个贴边会话只补一次，直到窗口离开贴边状态才重置，避免尺寸被 App 夹断时反复写。
        let edgeState = verticalEdgeState(frame, screen: screen)
        let frameStable = lastFrame.map {
            abs($0.origin.x - frame.origin.x) <= 1
                && abs($0.origin.y - frame.origin.y) <= 1
                && abs($0.width - frame.width) <= 1
                && abs($0.height - frame.height) <= 1
        } ?? false
        if edgeState == .none {
            edgeFillHandled = false
            edgeFillStableCount = 0
        } else if edgeFillHandled || edgeState == .both || isPointerHeld || !frameStable
                    || Date().timeIntervalSince(releasedAt) < releaseGrace {
            edgeFillStableCount = 0
        } else {
            edgeFillStableCount += 1
            if edgeFillStableCount >= edgeFillStableThreshold {
                edgeFillStableCount = 0
                edgeFillHandled = true
                // 清掉可能互相打架的挂起动作；这次写入是本服务自己的，不算用户手动移动。
                pendingSnap = false
                pendingCrossScreen = false
                pendingMoveCheck = nil
                inSnapZone = false
                let filled = WindowManager.setVerticalFill(window, frame: frame,
                                                           visible: screen.visibleFrame)
                lastAutoWrite = Date()
                commit(window: window, frame: filled, screenID: sid, center: center)
                return
            }
        }

        let windowChanged = !sameWindow(lastWindow, window)
        let screenChanged = lastWindow != nil && sid != lastScreenID
        let sizeChanged = lastFrame.map {
            abs($0.width - frame.width) > 1 || abs($0.height - frame.height) > 1
        } ?? false

        // 光标还按着且已跨到另一块屏幕：只挂起，不写任何位置。
        // 拖动全程（包括停在半空对准位置）都不写，避免窗口跟着被拽向新屏中心。
        if isPointerHeld && !windowChanged && screenChanged {
            pendingCrossScreen = true
        }

        // 兜底：键盘快捷键 / 窗口管理工具造成的移动没有鼠标拖拽事件。
        // 同一窗口尺寸不变却明显偏离中心，也视为用户手动定位；排除本服务刚写入位置的
        // 短时间内，避免把 AX 写入误差或系统夹断当成用户移动；跨屏交给下面的分支处理。
        if !windowChanged, let prev = lastFrame,
           abs(prev.width - frame.width) <= 1, abs(prev.height - frame.height) <= 1,
           !isPointerHeld, !centeredNow, sid == lastScreenID,
           (abs(prev.origin.x - frame.origin.x) > manualMoveTolerance
            || abs(prev.origin.y - frame.origin.y) > manualMoveTolerance),
           Date().timeIntervalSince(lastAutoWrite) > 0.3 {
            rec.userPositioned = true
        }

        var result = frame
        if windowChanged {
            // 1) 首次激活（记录里 userPositioned 为 false）→ 自动居中。
            // 用户已把这个窗口固定在某一侧时，再怎么切换激活都不打扰它；拖动中不打断。
            if !rec.userPositioned && !centeredNow && !isPointerHeld {
                result = moveToCenter(window, frame: frame, center: center)
            }
        } else if screenChanged {
            // 2) 移动到另一块屏幕：只在光标松开后居中。拖动中由 pendingCrossScreen 挂起，
            //    这里既不写位置、也不改「用户定位」标记（避免拖动中被清掉）。
            //    换屏是新的布局意图，松手后清掉上一块屏上「固定在一侧」的标记。
            if !isPointerHeld {
                if !centeredNow {
                    result = moveToCenter(window, frame: frame, center: center)
                }
                rec.userPositioned = false
            }
        } else if wasCentered && (sizeChanged || isResizing) && (!isPointerHeld || isResizing) {
            // 3) 锁定居中式拉伸：只有「变化前是居中的」才补偿中心。
            // 拉伸本身就是按住鼠标拖动，所以 isResizing 为 true 时照常补偿（保持上一轮的行为）；
            // 纯移动窗口（尺寸没变、isResizing=false）在光标按着时一律不补偿，避免拖动中被写回中心。
            // isResizing 让拉伸过程中「某一帧尺寸恰好没变」也持续补偿。
            //
            // 垂直方向两层保护（此处只会是「用户按住鼠标的拉伸」；系统边缘动画已在上面的
            // 会话门禁整轮 return，根本走不到这里）：
            //   ① 降频：每 6 轮（≈360ms）才允许写一次 y，水平仍每轮补偿；
            //   ② 贴边保护：某一端已顶到可见区边缘时这一轮连 y 都不写，只保持水平居中。
            // !systemVerticalAnimation 保留作双保险，防止门禁边界条件被改动后漏判。
            // 用户按住鼠标拉伸时 isPointerHeld 为真，不进门禁，中心锁定照常工作。
            let adjustVertical = allowVerticalCompensation
                && !systemVerticalAnimation
                && !isVerticallyEdgeSnapped(frame, screen: screen)
            result = moveToCenter(window, frame: frame, center: center,
                                  adjustVertical: adjustVertical)
        }

        commit(window: window, frame: result, screenID: sid, center: center)
    }

    private func commit(window: AXUIElement, frame: CGRect, screenID: String, center: CGPoint) {
        lastWindow = window
        lastFrame = frame
        // 光标按着时保留旧的屏幕 ID：松手后仍能判定为「跨屏」，供挂起的居中动作补上。
        if !isPointerHeld { lastScreenID = screenID }
        wasCentered = isCentered(frame, center: center)
    }

    // MARK: - 每窗口记录

    /// 按 AX 元素查找记录；首次遇到该窗口时创建一份（userPositioned 默认 false ⇒ 允许首次居中）。
    /// 用 `CFEqual` 而不是对象地址：同一个窗口每次取到的 AXUIElement 可能是不同实例。
    private func record(for window: AXUIElement) -> WindowRecord {
        if let rec = records.first(where: { CFEqual($0.window, window) }) {
            return rec
        }
        let rec = WindowRecord(window)
        records.append(rec)
        return rec
    }

    /// 只清理「窗口已销毁」的记录；仍然活着的窗口（哪怕很久没激活）一律保留，
    /// 否则「固定在一侧」的窗口会被时间清掉、下次激活又被当成首次。
    private func pruneDeadRecords() {
        records.removeAll { rec in
            var value: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(rec.window, kAXRoleAttribute as CFString, &value)
            // 只在明确判定「元素已失效」时清除；App 忙 / 权限临时失败等其它错误一律保留。
            return err == .invalidUIElement
        }
        // 记录异常增长时，把所有「读不到属性」的一并清掉，但保留仍能正常读取的活跃窗口。
        if records.count > 200 {
            records.removeAll { rec in
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(rec.window, kAXRoleAttribute as CFString, &value) != .success
            }
        }
    }

    // MARK: - 鼠标：磁吸与震动

    private func handleMouse(_ type: NSEvent.EventType) {
        guard enabled else { return }
        switch type {
        case .leftMouseDown:
            isDragging = true
            lastDragEventAt = Date()
            isResizing = false
            let start = currentFrame()
            dragStartFrame = start
            // 以「按下这一刻窗口是否已在范围内」为基准，而不是硬置 false：
            // 只有真正跨越边界才震动，否则在范围内按下鼠标的第一次 dragged 会误报「进入」。
            inSnapZone = snapZoneBaseline(start)
        case .leftMouseDragged:
            // 系统级拖移（触控板三指拖移、拖动锁定等）可能不给到 leftMouseDown：
            // 补记拖拽会话，否则整个拖动过程会被当成「已松手」而提前居中、产生漂移。
            if !isDragging {
                isDragging = true
                isResizing = false
                let start = currentFrame()
                dragStartFrame = start
                inSnapZone = snapZoneBaseline(start)
            }
            lastDragEventAt = Date()
            updateSnapZone()
        case .leftMouseUp:
            // 拉伸会话不算「吸附到中心」：窗口本来就在中心范围内时 inSnapZone 为 true，
            // 双击边缘松手会误设 pendingSnap，下一轮就在系统动画刚开始时把 y 写回中心
            // （这是动画被打断的原因之一）。无 dragged 的纯双击由 poll 里的动画门禁再兜一层。
            if inSnapZone && !isResizing { pendingSnap = true }
            // 把这次拖拽的起点留给下一轮轮询判定「用户是否手动挪离中心」。
            if let start = dragStartFrame, let w = trackedWindow() {
                pendingMoveCheck = MoveCheck(window: w, start: start, resizing: isResizing)
            }
            isDragging = false
            lastDragEventAt = Date.distantPast
            releasedAt = Date()   // 挂起的跨屏居中等这一刻之后再稳定一小段时间执行
            isResizing = false
            // 会话结束就重置；下次按下会用窗口当时的实际位置重新取基准。
            inSnapZone = false
            dragStartFrame = nil
        default:
            break
        }
    }

    /// 拖动过程中实时判断窗口是否**跨越**中心磁吸范围的边界。
    /// 进入或离开都触发一次触控板反馈（强度由设置里的三档决定）—— 用户要的是「知道现在它离开范围了」，
    /// 而不是只在靠近中心时有提示。判定只看窗口帧，与窗口是否已居中、是否被锁定、
    /// 是否被记录为「用户定位」都无关。
    private func updateSnapZone() {
        guard let frame = currentFrame(), let screen = screen(for: frame) else { return }
        // 尺寸相对按下时变了 ⇒ 这是拉伸窗口，不是「拖动窗口靠近中心」，不做磁吸 / 震动。
        let baseline = dragStartFrame ?? lastFrame
        if let start = baseline,
           abs(start.width - frame.width) > 1 || abs(start.height - frame.height) > 1 {
            isResizing = true
            return
        }
        isResizing = false
        let inside = isInSnapZone(frame, center: visibleCenter(of: screen), screen: screen)
        if inside != inSnapZone {
            // 冷却只挡边界抖动造成的连震；状态无论是否震动都跟着更新，
            // 否则下一次判定会基于过期状态，出现漏报或重复报。
            let now = Date()
            if now.timeIntervalSince(lastBoundaryHapticAt) >= hapticBoundaryCooldown {
                fireSnapHaptic()
                lastBoundaryHapticAt = now
            }
        }
        inSnapZone = inside
    }

    /// 拖拽开始时的范围基准：窗口此刻是否已落在中心磁吸范围内。
    private func snapZoneBaseline(_ frame: CGRect?) -> Bool {
        guard let frame, let screen = screen(for: frame) else { return false }
        return isInSnapZone(frame, center: visibleCenter(of: screen), screen: screen)
    }

    /// 触发一次范围边界反馈（进入或离开磁吸范围各一次）。
    ///
    /// 模式与脉冲数来自设置里的「震动强度」三档（见 `HapticStrength`），默认「强」。
    /// 每次都重新取 `defaultPerformer`（Apple 要求：它会随输入设备 / 辅助功能设置 / 用户偏好变化）；
    /// 只在状态翻转（进 / 出边界）时调用一次，并受 `hapticBoundaryCooldown` 冷却。
    /// 进 / 出用同一个模式，不区分方向；拉伸窗口、系统级浮层与过小窗口不会误触发。
    /// - Note: Apple 文档提醒系统可能覆盖该调用 —— 例如用户没有触摸触控板时，
    ///   Force Touch 触控板不会提供反馈；无 Force Touch 硬件时完全无感，属正常降级。
    private func fireSnapHaptic() {
        let strength = Preferences.hapticStrength
        let pattern = strength.pattern
        for i in 0..<strength.pulseCount {
            let delay = hapticPulseInterval * Double(i)
            if delay == 0 {
                NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
                }
            }
        }
    }

    private func currentFrame() -> CGRect? {
        guard let window = trackedWindow() else { return nil }
        return WindowManager.getFrame(window)
    }

    // MARK: - 几何与屏幕

    /// 按窗口中心找到它所在的屏幕（与 `WindowManager` 一致的规则）。
    private func screen(for frame: CGRect) -> NSScreen? {
        let p = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
    }

    private func screenID(_ screen: NSScreen) -> String {
        NSStringFromRect(screen.frame)
    }

    /// 居中锚点：屏幕可见区中心（避开菜单栏 / Dock），与复位布局的中心一致。
    private func visibleCenter(of screen: NSScreen) -> CGPoint {
        CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
    }

    private func isCentered(_ frame: CGRect, center: CGPoint) -> Bool {
        abs(frame.midX - center.x) <= centerTolerance
            && abs(frame.midY - center.y) <= centerTolerance
    }

    private func isInSnapZone(_ frame: CGRect, center: CGPoint, screen: NSScreen) -> Bool {
        let v = screen.visibleFrame
        let ratio = Preferences.snapRatio
        return abs(frame.midX - center.x) <= v.width * ratio
            && abs(frame.midY - center.y) <= v.height * ratio
    }

    /// 窗口上 / 下端与可见区边缘的贴合情况（Cocoa 坐标，左下原点）。
    /// `.top` = 顶边顶到菜单栏下沿，`.bottom` = 底边顶到 Dock 上沿，`.both` = 已垂直铺满。
    private func verticalEdgeState(_ frame: CGRect, screen: NSScreen) -> VerticalEdge {
        let v = screen.visibleFrame
        let top = abs(frame.maxY - v.maxY) <= verticalEdgeTolerance
        let bottom = abs(frame.minY - v.minY) <= verticalEdgeTolerance
        switch (top, bottom) {
        case (true, true): return .both
        case (true, false): return .top
        case (false, true): return .bottom
        case (false, false): return .none
        }
    }

    /// 是否已有一端贴到可见区边缘。命中说明系统正在执行「双击窗口边缘把那一端顶到边」，
    /// 此时「锁定居中式拉伸」这一轮连 y 都不写，让系统动作完整保留。
    private func isVerticallyEdgeSnapped(_ frame: CGRect, screen: NSScreen) -> Bool {
        verticalEdgeState(frame, screen: screen) != .none
    }

    /// 保持窗口实际尺寸，把中心移到锚点；只在位置真的不同时写 AXPosition。
    /// - Parameter adjustVertical: false 时只做水平（左右）补偿，y 保持系统当前值不动，
    ///   用于垂直降频 / 贴边保护；默认 true（激活居中、跨屏居中、磁吸吸附都完整居中）。
    /// - Returns: 调整后的帧（供状态记录用，避免下一轮重复触发）。
    @discardableResult
    private func moveToCenter(_ window: AXUIElement, frame: CGRect, center: CGPoint,
                              adjustVertical: Bool = true) -> CGRect {
        let moved = CGRect(x: center.x - frame.width / 2,
                           y: adjustVertical ? center.y - frame.height / 2 : frame.origin.y,
                           width: frame.width,
                           height: frame.height)
        guard abs(moved.origin.x - frame.origin.x) > 1
                || abs(moved.origin.y - frame.origin.y) > 1 else { return frame }
        WindowManager.setPosition(window, moved)
        lastAutoWrite = Date()
        return moved
    }

    private func sameWindow(_ a: AXUIElement?, _ b: AXUIElement) -> Bool {
        guard let a else { return false }
        return CFEqual(a, b)
    }
}

/// 一个窗口的「自动居中」状态记录（仅内存，随 app 退出 / 关闭开关清空）。
private final class WindowRecord {
    let window: AXUIElement
    /// 用户已手动把窗口挪离中心（固定在某一侧）：此后不再因「激活」而自动居中。
    /// 只有拖回中心附近、触发磁吸吸附、或换到另一块屏幕时才恢复。
    var userPositioned = false
    init(_ window: AXUIElement) { self.window = window }
}

/// 一次拖拽松手后待判定的信息：哪个窗口、按下时的帧、这次是不是拉伸。
private struct MoveCheck {
    let window: AXUIElement
    let start: CGRect
    let resizing: Bool
}
