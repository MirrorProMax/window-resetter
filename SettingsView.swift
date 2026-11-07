import SwiftUI
import Foundation

struct SettingsView: View {
    /// 时长输入框只允许 16~60000 毫秒的整数。
    private let msFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = NSNumber(value: 16)
        f.maximum = NSNumber(value: 60000)
        return f
    }()

    /// 长度类输入框只允许 0~10000 的整数（「左右预留」/「最小宽度」共用，单位：逻辑分辨率）。
    private let pixelFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = NSNumber(value: 0)
        f.maximum = NSNumber(value: 10000)
        return f
    }()

    /// 单位说明：所有长度 / 面积数值都在 macOS 逻辑分辨率（点 pt）空间，不是物理像素。
    private static let unitNote = "本应用所有长度 / 面积数值均按 macOS 逻辑分辨率（点 pt）计算：Retina 屏上 1 点 = 2 物理像素，无需换算。"

    /// 「最小宽度」的悬停提示（标签与输入框共用，避免界面上出现常驻说明文字）。
    private let minimumWidthHelp = "宽模式的宽度下限，默认 1710（逻辑分辨率），范围 0~10000（0 = 不限制）。优先级高于「左右预留」：小屏幕上按预留算出的宽度不足此值时自动压缩预留，最小压缩到 0（窗口顶到左右两边）；可见宽本身不足时占满可见宽。竖屏自适应与窄模式不受影响。" + SettingsView.unitNote

    /// 「左右预留」的悬停提示（标签与输入框共用）。
    private let marginHelp = "整数，宽模式左右各预留该值（逻辑分辨率）；默认 245，范围 0~10000（0 = 不预留）。仅在「台前调度检测」开启且系统台前调度开启时生效；屏幕较小时会被「最小宽度」自动压缩，甚至减到 0。" + SettingsView.unitNote

    /// 最小窗口面积输入框只允许 0~100000000 的整数（0 = 不启用该规则）。
    private let areaFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = NSNumber(value: 0)
        f.maximum = NSNumber(value: 100_000_000)
        return f
    }()

    /// 「震动强度」的悬停提示。
    private let hapticStrengthHelp = "进入 / 离开中心磁吸范围时的触控板反馈强度。Apple 官方 API 没有强度参数，只有 3 种反馈模式，这里用「模式 + 脉冲数」组合：轻=对齐×1，中=通用×2，强=档位变化×2（默认，最明显）。实际力度由系统与触控板决定，无 Force Touch 硬件时完全无感。"

    /// 「最小窗口面积」的悬停提示（标签与输入框共用）。
    private let minimumAreaHelp = "窗口宽×高小于此值时不触发自适应居中（不居中、不补偿、不磁吸、不震动）。默认 200000（逻辑分辨率²，约 500×400），0 = 不启用。用于排除调度中心缩略窗口、系统小浮层、最小化窗口等；正常大窗口不受影响。" + SettingsView.unitNote

    // 按界面上的优先级顺序声明：启动 → 自适应居中（震动强度 / 最小窗口面积） → 竖屏自适应
    // → 窄窗口模式 → 最小宽度 → 台前调度 / 边距 → 动画。
    @AppStorage(Preferences.launchKey) private var launchAtLogin: Bool = false
    @AppStorage(Preferences.adaptiveCenterKey) private var adaptiveCenter: Bool = Preferences.adaptiveCenterDefault
    @AppStorage(Preferences.hapticStrengthKey) private var hapticStrengthRaw: Int = Preferences.hapticStrengthDefault
    @AppStorage(Preferences.minimumWindowAreaKey) private var minimumWindowArea: Int = Preferences.minimumWindowAreaDefault
    @AppStorage(Preferences.portraitAdaptiveKey) private var portraitAdaptive: Bool = false
    @AppStorage(Preferences.narrowWidthSourceKey) private var narrowWidthSourceRaw: Int = 0
    @AppStorage(Preferences.minimumWidthKey) private var minimumWidth: Int = Preferences.minimumWidthDefault
    @AppStorage(Preferences.stageManagerDetectKey) private var stageManagerDetect: Bool = Preferences.stageManagerDetectDefault
    @AppStorage(Preferences.marginKey) private var margin: Int = Preferences.marginDefault
    @AppStorage(Preferences.smoothAnimationKey) private var smoothAnimation: Bool = false
    @AppStorage(Preferences.animationDurationKey) private var animationDurationMs: Int = 1000

    var body: some View {
        // 排序原则：运行时逻辑链上越早参与判断、越能覆盖下游设置的项，位置越靠前。
        // 启动 → 自适应居中（震动强度 / 最小窗口面积） → 竖屏自适应 → 窄窗口模式
        // → 最小宽度 → 台前调度 / 边距 → 动画（只改到达方式）。
        // 最小宽度排在左右预留之前：它会覆盖后者计算出的宽度；
        // 自适应居中的两个子项只在开关打开时显示，与「时长」的条件显示保持一致。
        // 说明文字一律用 .help 挂在控件上：macOS 上光标悬停即显示 tooltip，界面只留控件本身。
        Form {
            Section {
                Toggle("开机自动启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        launchAtLogin = newValue
                        LoginItemManager.setLaunchAtLogin(newValue)
                    }
                ))
                .help("随 macOS 登录时自动启动本应用。")

                Toggle("自适应居中", isOn: Binding(
                    get: { adaptiveCenter },
                    set: { newValue in
                        adaptiveCenter = newValue
                        AdaptiveCenterManager.shared.setEnabled(newValue)
                    }
                ))
                .help("首次激活 / 跨屏自动居中（跨屏等松开鼠标后才生效，拖动中不打断）；居中时拉伸锁定中心；拖进 / 拖出中心 5% 范围各震动一下，进入后松手吸附到中心。\n双击窗口上 / 下边缘把一端顶到头后，自动把另一端也拉到对侧边缘（垂直铺满可见区）。\n固定在某一侧的窗口不再自动居中，拖回中心或磁吸后恢复。\n控制中心、通知中心、菜单栏菜单、系统搜索等临时浮层，以及面积过小的窗口不参与。")

                if adaptiveCenter {
                    Picker("震动强度", selection: $hapticStrengthRaw) {
                        Text("轻").tag(0)
                        Text("中").tag(1)
                        Text("强").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .help(hapticStrengthHelp)

                    HStack {
                        Text("最小窗口面积")
                        TextField("整数", value: $minimumWindowArea, formatter: areaFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .help(minimumAreaHelp)
                        Text("逻辑分辨率²")
                            .help(minimumAreaHelp)
                    }
                }
            } header: {
                Text("启动与自适应")
            }

            Section {
                Toggle("竖屏自适应", isOn: $portraitAdaptive)
                    .help("屏幕高 > 宽时优先：不分宽模式 / 窄模式，宽度取屏幕宽度、左右不预留；下方选项均不生效。")

                Picker("窄窗口模式", selection: $narrowWidthSourceRaw) {
                    Text("屏幕宽度的一半").tag(0)
                    Text("屏幕的高度").tag(1)
                }
                .pickerStyle(.segmented)
                .help("决定窄模式宽度。两种选项的高度都铺满可见区，上下顶到菜单栏下沿与 Dock 上沿。")

                HStack {
                    Text("最小宽度")
                    TextField("整数", value: $minimumWidth, formatter: pixelFormatter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .help(minimumWidthHelp)
                    Text("逻辑分辨率")
                        .help(minimumWidthHelp)
                }
            } header: {
                Text("窗口布局")
            }

            Section {
                Toggle("台前调度检测", isOn: $stageManagerDetect)
                    .help("开启：系统台前调度开启时左右预留，系统台前调度关闭时不预留。\n关闭：一律不预留，宽模式占满可用宽度。\n竖屏自适应生效时本选项不生效；预留值可能被「最小宽度」压缩。")

                HStack {
                    Text("左右预留")
                    TextField("整数", value: $margin, formatter: pixelFormatter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .help(marginHelp)
                    Text("逻辑分辨率")
                        .help(marginHelp)
                }
            } header: {
                Text("台前调度")
            }

            Section {
                Toggle("平滑变化", isOn: $smoothAnimation)
                    .help("窗口移动与拉伸在设定时长内平滑完成；只改变到达方式，不影响布局规则。")

                if smoothAnimation {
                    HStack {
                        Text("动画时长")
                        TextField("整数", value: $animationDurationMs, formatter: msFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .help("单位毫秒，默认 1000，有效范围 16~60000。")
                        Text("毫秒")
                            .help("单位毫秒，默认 1000，有效范围 16~60000。")
                    }
                }
            } header: {
                Text("窗口动画")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: windowHeight)
        .padding()
    }

    /// 设置窗口高度：两处条件显示的控件会改变行数。
    /// 基础 420（含「最小宽度」行）；自适应居中开 → 多两行（震动强度 / 最小窗口面积）；
    /// 平滑变化开 → 多一行「时长」。
    private var windowHeight: CGFloat {
        420 + (adaptiveCenter ? 60 : 0) + (smoothAnimation ? 50 : 0)
    }
}
