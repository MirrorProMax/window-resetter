import Cocoa

/// 管理菜单栏图标：左键复位窗口，右键弹出菜单。
final class StatusBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "窗口复位器")
            button.image?.isTemplate = true
            button.toolTip = "左键：复位当前窗口  右键：菜单"
            button.target = self
            button.action = #selector(buttonClicked)
            // 同时监听左键与右键，在回调中根据事件类型区分。
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func buttonClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.type == .rightMouseDown {
            showContextMenu()
        } else {
            WindowManager.adjustCurrentWindow()
        }
    }

    private func showContextMenu() {
        let settings = NSMenuItem(title: "设置", action: #selector(AppDelegate.showSettings), keyEquivalent: "")
        let about = NSMenuItem(title: "关于", action: #selector(AppDelegate.showAbout), keyEquivalent: "")
        let quit = NSMenuItem(title: "退出", action: #selector(AppDelegate.quit), keyEquivalent: "q")

        [settings, about, quit].forEach { $0.target = appDelegate }

        let menu = NSMenu()
        menu.items = [settings, .separator(), about, .separator(), quit]

        if let button = statusItem.button {
            let point = NSPoint(x: 0, y: button.bounds.height + 4)
            menu.popUp(positioning: nil, at: point, in: button)
        }
    }
}
