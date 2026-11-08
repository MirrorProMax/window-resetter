import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers

/// 「忽略的 App」列表的共享状态。
/// - Note: 本项目用命令行 `swiftc` 编译（不经 Xcode），而新版 SwiftUI 的 `@State` 是需要
///   宏插件的 macro，命令行下会报 `SwiftUIMacros ... not found`。这里改用
///   `ObservableObject` + `@ObservedObject`（普通 property wrapper），行为等价且不依赖宏。
///   单例保证 SwiftUI 重建视图值时状态与偏好不丢失。
final class IgnoredAppsStore: ObservableObject {
    static let shared = IgnoredAppsStore()

    @Published var apps: [IgnoredApp] = Preferences.ignoredApps

    /// 从设置窗口重新打开时同步一次外部写入（`defaults write` 等）。
    func reload() {
        apps = Preferences.ignoredApps
    }

    /// 勾选 / 取消某一行的某个复选框，并立即落盘。
    func set(_ feature: IgnoreFeature, value: Bool, for bundleID: String) {
        guard let idx = apps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        switch feature {
        case .adaptiveCenter: apps[idx].skipAdaptiveCenter = value
        case .reset: apps[idx].skipReset = value
        }
        persist()
    }

    func add(_ app: IgnoredApp) {
        guard !apps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        apps.append(app)
        persist()
    }

    func remove(_ id: String) {
        apps.removeAll { $0.bundleID == id }
        persist()
    }

    /// 不依赖 @Published 的 didSet：数组下标修改是否触发观察不确定，显式写盘最稳。
    private func persist() {
        Preferences.setIgnoredApps(apps)
    }
}

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

    /// 「吸附率」输入框只允许 1~20 的整数（百分数）。
    private let ratioFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = NSNumber(value: 1)
        f.maximum = NSNumber(value: 20)
        return f
    }()

    /// 「震动强度」的悬停提示。
    private let hapticStrengthHelp = "进入 / 离开中心磁吸范围时的触控板反馈强度。Apple 官方 API 没有强度参数，只有 3 种反馈模式，这里用「模式 + 脉冲数」组合：轻=对齐×1，中=通用×2，强=档位变化×2（默认，最明显）。实际力度由系统与触控板决定，无 Force Touch 硬件时完全无感。"

    /// 「吸附率」的悬停提示（标签与输入框共用）。
    private let snapRatioHelp = "中心磁吸范围占屏幕可见区宽 / 高的百分比（整数，默认 8，范围 1~20）。窗口中心同时落在水平 ±吸附率×可见宽、垂直 ±吸附率×可见高内时：进 / 出边界各震动一次，进入后松手吸附到中心，并让固定在侧边的窗口恢复自动居中。数值越大越容易吸住，但也越容易把刻意放偏的窗口拉回中心；想保留旧版手感可填 5。"

    /// 「最小窗口面积」的悬停提示（标签与输入框共用）。
    private let minimumAreaHelp = "窗口宽×高不超过此值即视为「小窗口」：手动复位与自适应居中都不参与（不居中、不补偿、不磁吸、不震动、不写位置）。默认 240000（逻辑分辨率²），基准是 iPhone 镜像窗口 326×719 = 234394；0 = 不启用。也用于排除调度中心缩略窗口、系统小浮层、最小化窗口等；正常大窗口不受影响。注意：本规则只对「忽略的 App」列表之外的 App 生效，列表里的条目完全由复选框决定，改这里不会影响它们（想让 iPhone 镜像重新参与复位，取消它在列表里的「复位」勾选即可）。" + SettingsView.unitNote

    // 按界面上的优先级顺序声明：启动 → 自适应居中（吸附率 / 震动强度 / 最小窗口面积） → 竖屏自适应
    // → 窄窗口模式 → 最小宽度 → 台前调度 / 边距 → 动画。
    @AppStorage(Preferences.launchKey) private var launchAtLogin: Bool = false
    @AppStorage(Preferences.adaptiveCenterKey) private var adaptiveCenter: Bool = Preferences.adaptiveCenterDefault
    @AppStorage(Preferences.snapRatioKey) private var snapRatioPercent: Int = Preferences.snapRatioPercentDefault
    @AppStorage(Preferences.hapticStrengthKey) private var hapticStrengthRaw: Int = Preferences.hapticStrengthDefault
    @AppStorage(Preferences.minimumWindowAreaKey) private var minimumWindowArea: Int = Preferences.minimumWindowAreaDefault
    @AppStorage(Preferences.portraitAdaptiveKey) private var portraitAdaptive: Bool = false
    @AppStorage(Preferences.narrowWidthSourceKey) private var narrowWidthSourceRaw: Int = 0
    @AppStorage(Preferences.minimumWidthKey) private var minimumWidth: Int = Preferences.minimumWidthDefault
    @AppStorage(Preferences.stageManagerDetectKey) private var stageManagerDetect: Bool = Preferences.stageManagerDetectDefault
    @AppStorage(Preferences.marginKey) private var margin: Int = Preferences.marginDefault
    @AppStorage(Preferences.smoothAnimationKey) private var smoothAnimation: Bool = false
    @AppStorage(Preferences.animationDurationKey) private var animationDurationMs: Int = 1000

    /// 「忽略的 App」列表（自定义类型不能用 @AppStorage，统一走共享 store）。
    @ObservedObject private var ignoredStore = IgnoredAppsStore.shared

    /// 某一行某个复选框的绑定（勾选 = 该功能对该 App 不生效）。
    private func ignoredBinding(for item: IgnoredApp, feature: IgnoreFeature) -> Binding<Bool> {
        Binding(
            get: {
                guard let current = ignoredStore.apps.first(where: { $0.bundleID == item.bundleID }) else { return false }
                switch feature {
                case .adaptiveCenter: return current.skipAdaptiveCenter
                case .reset: return current.skipReset
                }
            },
            set: { ignoredStore.set(feature, value: $0, for: item.bundleID) }
        )
    }

    /// 「添加 App」菜单的可选项：正在运行、有 Dock 图标、且尚未加入列表的 App。
    private var addCandidates: [IgnoredApp] {
        let existing = Set(ignoredStore.apps.map(\.bundleID))
        let selfID = Bundle.main.bundleIdentifier ?? ""
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> IgnoredApp? in
                guard let id = app.bundleIdentifier, !id.isEmpty, id != selfID,
                      !existing.contains(id) else { return nil }
                return IgnoredApp(bundleID: id,
                                  name: app.localizedName ?? id,
                                  skipAdaptiveCenter: true,
                                  skipReset: true)
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private func add(_ app: IgnoredApp) {
        ignoredStore.add(app)
    }

    private func remove(_ id: String) {
        ignoredStore.remove(id)
    }

    /// 也允许添加当前没运行的 App：从磁盘选 .app，读它的 Bundle ID 与显示名。
    private func addFromFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "选择一个 App，把它加入忽略列表"
        panel.prompt = "添加"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? FileManager.default.displayName(atPath: url.path)
        add(IgnoredApp(bundleID: id, name: name, skipAdaptiveCenter: true, skipReset: true))
    }

    var body: some View {
        // 排序原则：运行时逻辑链上越早参与判断、越能覆盖下游设置的项，位置越靠前。
        // 启动（独立分组）→ 忽略的 App（优先级高于面积规则）→ 自适应居中（吸附率 / 震动强度 / 最小窗口面积）
        // → 竖屏自适应 → 窄窗口模式 → 最小宽度 → 台前调度 / 边距 → 动画（只改到达方式）。
        // 最小宽度排在左右预留之前：它会覆盖后者计算出的宽度；
        // 自适应居中的三个子项只在开关打开时显示，与「时长」的条件显示保持一致。
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
            } header: {
                Text("启动")
            }

            Section {
                // 表头：两列复选框的含义是「勾选 = 该功能不生效」，与下方每行对齐。
                HStack(spacing: 0) {
                    Text("App").frame(width: 190, alignment: .leading)
                    Text("自适应居中").frame(width: 100)
                    Text("复位").frame(width: 70)
                    Spacer()
                    Color.clear.frame(width: 24)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(ignoredStore.apps) { item in
                    HStack(spacing: 0) {
                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 190, alignment: .leading)
                            .help(item.bundleID)
                        Toggle("", isOn: ignoredBinding(for: item, feature: .adaptiveCenter))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .frame(width: 100)
                            .accessibilityLabel("\(item.name)：忽略自适应居中")
                            .help("勾选后，自适应居中对该 App 不生效")
                        Toggle("", isOn: ignoredBinding(for: item, feature: .reset))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .frame(width: 70)
                            .accessibilityLabel("\(item.name)：忽略复位")
                            .help("勾选后，点菜单栏图标复位对该 App 不生效")
                        Spacer()
                        Button {
                            remove(item.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 24)
                        .help("从列表移除")
                    }
                }

                Menu {
                    if addCandidates.isEmpty {
                        Text("当前没有可添加的运行中 App")
                    } else {
                        ForEach(addCandidates) { app in
                            Button(app.name) { add(app) }
                        }
                    }
                    Divider()
                    Button("从 .app 文件选择…") { addFromFile() }
                } label: {
                    Label("添加 App", systemImage: "plus")
                }
                .help("从当前运行的 App 里选，或从磁盘选一个 .app；新加入的条目默认两项都勾选")
            } header: {
                Text("忽略的 App")
            } footer: {
                Text("勾选哪个，哪个功能就对该 App 不生效。列表里的 App 是显式设定，不受「最小窗口面积」限制；未列出的仍按面积规则跳过。默认 iPhone 镜像只忽略复位，自适应居中照常生效。")
            }

            Section {
                Toggle("自适应居中", isOn: Binding(
                    get: { adaptiveCenter },
                    set: { newValue in
                        adaptiveCenter = newValue
                        AdaptiveCenterManager.shared.setEnabled(newValue)
                    }
                ))
                .help("首次激活 / 跨屏自动居中（跨屏等松开鼠标后才生效，拖动中不打断）；居中时拉伸锁定中心；拖进 / 拖出中心磁吸范围各震动一下（范围由下方「吸附率」设定），进入后松手吸附到中心。\n双击窗口上 / 下边缘把一端顶到头后，自动把另一端也拉到对侧边缘（垂直铺满可见区）。\n固定在某一侧的窗口不再自动居中，拖回中心或磁吸后恢复。\n控制中心、通知中心、菜单栏菜单、系统搜索等临时浮层，以及未列入「忽略的 App」列表的小窗口（面积不超过下方「最小窗口面积」）不参与；在列表里勾了「自适应居中」的 App 也不参与。")

                if adaptiveCenter {
                    HStack {
                        Text("吸附率")
                        TextField("整数", value: $snapRatioPercent, formatter: ratioFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .help(snapRatioHelp)
                        Text("%")
                            .help(snapRatioHelp)
                    }

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
                Text("自适应居中")
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
        .frame(width: 560, height: windowHeight)
        .padding()
    }

    /// 设置窗口高度：两处条件显示的控件与「忽略的 App」列表行数都会改变行数。
    /// 基础 450（含「最小宽度」行，且「启动」拆成独立分组后多一个 Section 标题）；
    /// 自适应居中开 → 多三行（吸附率 / 震动强度 / 最小窗口面积）；
    /// 平滑变化开 → 多一行「时长」；忽略列表另加表头 / 添加按钮 / 说明与每行高度。
    /// 封顶 760：Form 自带滚动容器，列表很长时滚动查看即可，避免窗口高过屏幕被系统裁切。
    private var windowHeight: CGFloat {
        let content = 450 + (adaptiveCenter ? 90 : 0) + (smoothAnimation ? 50 : 0)
            + 150 + CGFloat(ignoredStore.apps.count) * 32
        return min(content, 760)
    }
}
