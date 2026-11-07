import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var settingsWindowController: NSWindowController?
    private var aboutWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(appDelegate: self)

        // 应用保存的“开机自动启动”偏好。
        let launch = UserDefaults.standard.bool(forKey: Preferences.launchKey)
        LoginItemManager.setLaunchAtLogin(launch)

        // 「自适应居中」默认开启：首次启动把默认值固化到偏好，再按偏好启动常驻监听服务。
        // 设置里的开关可即时启停；用户显式关闭后不会再被重新打开。
        Preferences.registerAdaptiveCenterDefault()
        AdaptiveCenterManager.shared.setEnabled(Preferences.adaptiveCenter)
    }

    @objc func showSettings() {
        if settingsWindowController == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAbout() {
        if aboutWindowController == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            window.title = "关于"
            window.styleMask = [.titled, .closable]
            window.center()
            aboutWindowController = NSWindowController(window: window)
        }
        aboutWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
