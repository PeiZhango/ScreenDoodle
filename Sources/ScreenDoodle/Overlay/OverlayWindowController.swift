import AppKit
import Carbon
import CoreGraphics
import UniformTypeIdentifiers

/// 覆盖窗口：可成为 key window，以便接收键盘事件与文字输入焦点。
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// 多屏覆盖窗口控制器：为每块屏幕创建一个透明涂鸦窗口，并管理悬浮工具条。
final class OverlayWindowController: NSObject, ToolbarHost {

    /// 共享工具状态
    private let toolState = ToolState()
    /// 每块屏幕对应的涂鸦窗口
    private var screenWindows: [OverlayWindow] = []
    /// 画布视图列表
    private var canvasViews: [DoodleCanvasView] = []
    /// 悬浮工具条
    private var toolbarController: ToolbarController?
    /// 涂鸦层键盘监听（撤销/重做/Esc 双击退出）
    private var keyMonitor: Any?
    /// 当前是否显示
    private(set) var isVisible = false
    /// 上次按下 Esc 的时间戳
    private var lastEscapeTimestamp: TimeInterval = 0
    /// 自研取色器（进行中时非空）
    private var colorPickerOverlay: ColorPickerOverlay?

    // MARK: - 显示/隐藏

    /// 唤出涂鸦（若已显示则收起，否则显示）
    func toggle() {
        if isVisible {
            dismiss(action: .cancel)
        } else {
            show()
        }
    }

    /// 显示所有屏幕的涂鸦窗口并弹出工具条
    private func show() {
        // 每次重新唤出时重置为画笔工具，避免沿用上次关闭前的工具
        toolState.currentTool = .pen
        toolState.onStateChanged?()

        screenWindows.forEach { $0.orderOut(nil) }
        screenWindows.removeAll()
        canvasViews.removeAll()

        for screen in NSScreen.screens {
            let window = makeWindow(for: screen)
            let canvas = DoodleCanvasView(toolState: toolState, frame: window.contentView?.bounds ?? .zero)
            canvas.autoresizingMask = [.width, .height]
            canvas.onContentChanged = { [weak self] in self?.refreshUndoRedo() }
            canvas.onPickColor = { [weak self] in self?.startColorPicker() }
            window.contentView = canvas
            canvasViews.append(canvas)
            screenWindows.append(window)
            window.orderFrontRegardless()
        }

        // 激活应用并使覆盖窗口成为 key，以接收键盘事件（撤销/重做/Esc/文字输入）
        NSApp.activate(ignoringOtherApps: true)
        screenWindows.first?.makeKey()

        // 弹出工具条
        if toolbarController == nil {
            toolbarController = ToolbarController(toolState: toolState)
        }
        toolbarController?.host = self
        toolbarController?.show()
        installKeyMonitor()

        isVisible = true
    }

    /// 收起涂鸦；action 决定是否导出及导出方式
    func dismiss(action: DismissAction) {
        removeKeyMonitor()
        colorPickerOverlay?.stop()
        colorPickerOverlay = nil
        toolbarController?.hide()
        // 先收起涂鸦层，避免随后弹出的系统提示框（如导出提示）被覆盖层挡住无法点击
        screenWindows.forEach { $0.orderOut(nil) }
        screenWindows.removeAll()
        lastEscapeTimestamp = 0
        isVisible = false

        switch action {
        case .cancel:
            break
        case .copyOnly:
            copySnapshotsToPasteboard()
        case .saveToFile:
            saveSnapshotsToFile()
        }
        canvasViews.removeAll()
    }

    /// 创建某屏幕的透明覆盖窗口
    private func makeWindow(for screen: NSScreen) -> OverlayWindow {
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false // 需要接收鼠标绘制
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: - 键盘处理（撤销/重做/Esc 双击退出）

    /// 使用本地事件监听捕获按键。相对于拦截 window.keyDown，本地监听不依赖 firstResponder，
    /// 只要应用处于激活状态即可收到事件，能稳定实现 Esc 双击退出与撤销/重做。
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handleOverlayKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleOverlayKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // 取色进行中：按键交给取色器处理（Esc 取消取色），避免误触发退出/撤销
        if colorPickerOverlay != nil {
            return false
        }

        // 正在编辑文字时：Esc 提交文字，其余按键（含文本自身的撤销）交给输入视图
        if canvasViews.contains(where: { $0.isEditingText }) {
            if event.keyCode == UInt16(kVK_Escape) {
                finishTextEditing()
            }
            return event.keyCode == UInt16(kVK_Escape)
        }

        // 连按两次 Esc（0.35 秒内）退出涂鸦；带修饰键的 Esc 不处理
        if event.keyCode == UInt16(kVK_Escape) && !flags.contains(.command) {
            let now = event.timestamp
            if now - lastEscapeTimestamp < 0.35 {
                lastEscapeTimestamp = 0
                dismiss(action: .cancel)
            } else {
                lastEscapeTimestamp = now
            }
            return true
        }

        // 撤销/重做快捷键
        guard flags.contains(.command) else { return false }
        if !flags.contains(.shift) && event.keyCode == UInt16(kVK_ANSI_Z) {
            undo()
            return true
        }
        if flags.contains(.shift) && event.keyCode == UInt16(kVK_ANSI_Z) {
            redo()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_Y) {
            redo()
            return true
        }
        return false
    }

    // MARK: - 工具条状态联动

    private func refreshUndoRedo() {
        toolbarController?.refreshUndoRedo()
    }

    /// 切换工具等场景下，提交并关闭正在编辑的文字输入框
    func finishTextEditing() {
        canvasViews.forEach { $0.finishTextInput() }
    }

    /// 取色管入口：有屏幕录制权限则直接启动自研取色器，否则先引导授权。
    func startColorPicker() {
        guard isVisible, !canvasViews.isEmpty, colorPickerOverlay == nil else { return }
        if CGPreflightScreenCaptureAccess() {
            beginColorPicking()
        } else {
            requestScreenCaptureAccess()
        }
    }

    /// 启动自研取色器（小准星 + 紧凑放大镜）
    private func beginColorPicking() {
        let picker = ColorPickerOverlay()
        colorPickerOverlay = picker
        picker.onPicked = { [weak self] color in
            guard let self = self else { return }
            self.colorPickerOverlay = nil
            self.toolState.currentColor = color
            // 取色完成自动回到画笔（一次性行为，与之前的交互一致）
            if self.toolState.currentTool == .colorPicker {
                self.toolState.currentTool = .pen
            }
            self.toolState.onStateChanged?()
            // 取色期间应用可能失焦，恢复激活与 key
            NSApp.activate(ignoringOtherApps: true)
            self.screenWindows.first?.makeKey()
        }
        picker.onCancel = { [weak self] in
            guard let self = self else { return }
            self.colorPickerOverlay = nil
            if self.toolState.currentTool == .colorPicker {
                self.toolState.currentTool = .pen
            }
            self.toolState.onStateChanged?()
            NSApp.activate(ignoringOtherApps: true)
            self.screenWindows.first?.makeKey()
        }
        picker.start()
    }

    /// 请求屏幕录制权限：先收起涂鸦层避免系统授权弹窗被遮挡，授权成功后自动继续取色。
    private func requestScreenCaptureAccess() {
        // 收起涂鸦层与工具条，确保系统授权弹窗可见可点
        screenWindows.forEach { $0.orderOut(nil) }
        toolbarController?.hide()
        CGRequestScreenCaptureAccess()

        // 轮询等待授权（最多 20 秒），期间用户会跳转到系统设置勾选
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if CGPreflightScreenCaptureAccess() {
                    DispatchQueue.main.async {
                        self.redisplayOverlay()
                        self.beginColorPicking()
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            DispatchQueue.main.async {
                self.redisplayOverlay()
                self.showScreenRecordingHelp()
            }
        }
    }

    /// 恢复显示涂鸦层与工具条
    private func redisplayOverlay() {
        screenWindows.forEach { $0.orderFrontRegardless() }
        toolbarController?.show()
    }

    /// 未获得屏幕录制权限时的提示：引导去系统设置授权
    private func showScreenRecordingHelp() {
        // 先收起涂鸦层，避免提示框被覆盖层挡住
        screenWindows.forEach { $0.orderOut(nil) }
        toolbarController?.hide()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "取色笔需要读取屏幕颜色。请在“系统设置 → 隐私与安全性 → 屏幕录制”中勾选 ScreenDoodle，然后重新点选取色管。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
        }
        redisplayOverlay()
    }

    /// 供工具条查询撤销/重做可用状态
    var undoRedoState: (canUndo: Bool, canRedo: Bool) {
        let canUndo = canvasViews.contains { $0.canUndo }
        let canRedo = canvasViews.contains { $0.canRedo }
        return (canUndo, canRedo)
    }

    /// 撤销（作用于含内容的第一块画布）
    func undo() {
        canvasViews.first(where: { $0.canUndo })?.undo()
        refreshUndoRedo()
    }

    /// 重做
    func redo() {
        canvasViews.first(where: { $0.canRedo })?.redo()
        refreshUndoRedo()
    }

    /// 清空所有画布
    func clear() {
        canvasViews.forEach { $0.clear() }
        refreshUndoRedo()
    }

    // MARK: - 导出与剪贴板

    /// 收集所有非空画布渲染出的图片
    private func renderedSnapshots() -> [NSImage] {
        canvasViews.compactMap { canvas in
            guard !canvas.elements.isEmpty else { return nil }
            return canvas.renderToImage()
        }
    }

    /// 仅将截图复制到剪贴板（不落盘）
    private func copySnapshotsToPasteboard() {
        let images = renderedSnapshots()
        guard let first = images.first else { return }
        ExportManager.copyToPasteboard(first)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "已复制到剪贴板"
        alert.informativeText = images.count > 1 ? "共 \(images.count) 块屏幕，已复制第一张到剪贴板" : "涂鸦已复制到剪贴板，可直接粘贴"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 弹出保存面板，由用户确认文件名后保存到设置的导出目录
    private func saveSnapshotsToFile() {
        let images = renderedSnapshots()
        guard !images.isEmpty else { return }

        let format = Settings.shared.exportFormat
        let ext = format == "jpg" ? "jpg" : "png"
        let defaultName = String(format: "涂鸦-%@.%@", Self.timestampString(), ext)
        let dirURL = URL(fileURLWithPath: Settings.shared.exportDirectory)
        FileManager.default.tryCreateDirectory(at: Settings.shared.exportDirectory)

        let panel = NSSavePanel()
        panel.title = "保存涂鸦"
        panel.prompt = "保存"
        panel.nameFieldLabel = "文件名"
        panel.directoryURL = dirURL
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .png]
        panel.allowsOtherFileTypes = false

        guard panel.runModal() == .OK, let saveURL = panel.url else { return }

        // 多屏时保存第一张；若用户需要多屏可后续扩展
        if let first = images.first,
           let data = first.data(ext: ext) {
            do {
                try data.write(to: saveURL)
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "已保存"
                alert.informativeText = saveURL.path
                alert.addButton(withTitle: "好")
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "保存失败"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

extension FileManager {
    /// 递归创建目录（若不存在）
    func tryCreateDirectory(at path: String) {
        if !fileExists(atPath: path) {
            try? createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }
}