import AppKit
import Carbon
import ScreenCaptureKit
import UserNotifications

/// 应用主委托：负责菜单栏状态项、快捷键管理器、覆盖窗口控制器的创建与调度。
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 菜单栏状态项
    private var statusItem: NSStatusItem!
    /// 全局快捷键管理器
    let hotKeyManager = HotKeyManager()
    /// 多屏覆盖窗口控制器
    private var overlayController: OverlayWindowController?
    /// 设置窗口
    private var settingsWindow: SettingsWindowController?
    /// 截图控制器（进行中非空）
    private var screenshotController: ScreenshotController?
    /// 已钉在桌面上的截图窗口
    private var pinnedWindows: [PinnedImageWindowController] = []

    // MARK: - 应用生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 常驻菜单栏
        setupStatusItem()

        // 注册全局快捷键
        hotKeyManager.onToggle = { [weak self] in self?.toggleOverlay() }
        hotKeyManager.onCapture = { [weak self] in self?.captureScreen() }
        hotKeyManager.onRecover = { [weak self] in self?.forceRecover() }
        hotKeyManager.apply(Settings.shared.hotKeys)

        // 预热 ScreenCaptureKit：首次查询可分享内容需 1-2 秒，
        // 启动时异步触发一次，之后首次截图即可命中系统缓存，避免按快捷键后长时间等待
        Task { _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }

        // 每次启动给出提示：系统通知横幅
        showLaunchHint()
    }

    /// 启动时发送系统通知横幅，告知应用已常驻菜单栏
    private func showLaunchHint() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "ScreenDoodle已启动"
            content.body = "点击菜单栏铅笔图标即可进行快捷键设置"
            content.sound = .default
            let request = UNNotificationRequest(identifier: "launch-hint", content: content, trigger: nil)
            center.add(request)
        }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "pencil.tip.crop.circle",
                accessibilityDescription: "屏幕涂鸦"
            )
        }

        let menu = NSMenu()
        menu.addItem(
            withTitle: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "退出",
            action: #selector(quit),
            keyEquivalent: "q"
        ).target = self
        statusItem.menu = menu
    }

    // MARK: - 动作

    /// 唤出或收起涂鸦（切换模式：弹出工具条，覆盖层穿透/可绘）
    @objc private func toggleOverlay() {
        ensureOverlay().toggle()
    }

    /// 截图：仿微信的框选 + 编辑（移动/缩放/标注），图钉钉到桌面最顶层
    @objc private func captureScreen() {
        // 已有截图会话进行中，忽略重复触发，避免叠加多个截图
        if screenshotController != nil { return }
        // 若涂鸦层正在显示，先收起，避免层级与按键监听冲突
        overlayController?.dismiss(action: .cancel)

        let controller = ScreenshotController()
        screenshotController = controller
        controller.onFinish = { [weak self] in
            self?.screenshotController = nil
        }
        controller.onPin = { [weak self] image in
            guard let self = self else { return }

            let pin = PinnedImageWindowController(image: image)
            pin.onClose = { [weak self, weak pin] in
                guard let pin = pin else { return }
                self?.pinnedWindows.removeAll { $0 === pin }
            }
            self.pinnedWindows.append(pin)
            pin.show()
        }
        controller.start()
    }

    /// 强制恢复：收起所有覆盖层/截图会话并归还激活权。
    /// 用于失控（遮罩残留、激活未归还）导致整屏无法点击时自救。
    @objc private func forceRecover() {
        screenshotController?.stop()
        screenshotController = nil
        overlayController?.dismiss(action: .cancel)
        NSApp.deactivate()
    }

    @objc private func openSettings() {
        // 设置期间暂停全局快捷键，避免录制快捷键时误触发唤出涂鸦等动作
        hotKeyManager.unregisterAll()

        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 覆盖层懒加载

    /// 获取或创建多屏覆盖窗口控制器
    func ensureOverlay() -> OverlayWindowController {
        if let overlayController = overlayController {
            return overlayController
        }
        let controller = OverlayWindowController()
        overlayController = controller
        return controller
    }
}