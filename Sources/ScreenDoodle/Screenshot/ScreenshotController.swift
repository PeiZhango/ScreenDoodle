import AppKit
import Carbon
import CoreGraphics
import ScreenCaptureKit
import UniformTypeIdentifiers

/// 截图控制器：仿微信的截图流程。
///
/// 阶段 A：全屏冻结压暗 + 十字准星，拖拽拉出矩形选区，选区内亮/外暗并实时显示宽高，Esc/右键取消。
/// 阶段 B：松手后选区进入编辑态 —— 鼠标在框内变手型可拖动整框、8 个边角手柄可缩放、
/// 双击任意框内位置完成并复制到剪贴板；同时浮出与涂鸦一致的工具栏进行标注，图钉按钮钉到桌面最顶层。
///
/// UI 状态均在主线程访问，截屏任务的异步结果通过 `DispatchQueue.main.async` 回主线程，
/// `Task`/`async` 闭包仅捕获 `self` 做调度，故标记为 unchecked Sendable。
final class ScreenshotController: NSObject, ToolbarHost, @unchecked Sendable {

    /// 图钉回调：把最终渲染图片交给 AppDelegate 钉到桌面最顶层
    var onPin: ((NSImage) -> Void)?
    /// 会话结束回调（取消/复制/保存/图钉均触发），用于释放控制器引用
    var onFinish: (() -> Void)?

    // MARK: - 阶段 A 状态

    private var overlayWindows: [NSWindow] = []
    /// 每块屏幕的全屏快照（displayID → CGImage）
    private var snapshots: [CGDirectDisplayID: CGImage] = [:]
    private var keyMonitor: Any?
    private var isRunning = false

    // MARK: - 阶段 B 状态

    private var editWindow: NSWindow?
    private var editView: ScreenshotEditView?
    /// 共享工具状态（与工具条、画布共用）
    let toolState = ToolState()
    private var toolbarController: ToolbarController?
    private var canvas: DoodleCanvasView?
    private var colorPickerOverlay: ColorPickerOverlay?
    /// 选区所在屏幕
    private var editScreen: NSScreen?
    /// 选区所在屏幕的全屏快照（整屏、点尺寸，供绘制选区背景用，拖动时避免逐帧裁剪）
    private var fullScreenImage: NSImage?
    /// 当前选区（屏幕局部点坐标，原点左下）
    private(set) var selectionRect: NSRect = .zero

    // MARK: - 生命周期

    func start() {
        stop()
        isRunning = true
        installKeyMonitor()

        // 必须先抓帧、后弹覆盖层：SCScreenshotManager 会连 .statusBar 覆盖层一起拍进去，
        // 若覆盖层已显示再抓帧，快照会变成暗色覆盖层本身，导致黑屏
        Task { [weak self] in
            await self?.captureAllScreens()
            DispatchQueue.main.async {
                guard let self, self.isRunning else { return }
                self.showPhaseA()
            }
        }
    }

    func stop() {
        removeKeyMonitor()
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        snapshots.removeAll()
        colorPickerOverlay?.stop()
        colorPickerOverlay = nil
        toolbarController?.hide()
        toolbarController = nil
        editWindow?.orderOut(nil)
        editWindow = nil
        editView = nil
        canvas = nil
        editScreen = nil
        fullScreenImage = nil
        selectionRect = .zero
        NSCursor.arrow.set()
        isRunning = false
    }

    // MARK: - 全屏截图

    private func captureAllScreens() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ) else { return }

        let displayByID = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })

        for screen in NSScreen.screens {
            guard
                let displayID = Self.displayID(of: screen),
                let scDisplay = displayByID[displayID]
            else { continue }

            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false

            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: scDisplay, excludingWindows: []),
                configuration: config
            ) else { continue }

            snapshots[displayID] = image
        }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    // MARK: - 阶段 A：框选

    private func showPhaseA() {
        guard isRunning else { return }

        // 未获取到任何屏幕快照，说明缺少屏幕录制权限
        if snapshots.isEmpty {
            finishCancel()
            showScreenRecordingHelp()
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        for screen in NSScreen.screens {
            // 复用 OverlayWindow：可成为 key window，阶段 B 的文字输入框才能接收键盘事件
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
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.acceptsMouseMovedEvents = true

            let snapshot = Self.displayID(of: screen).flatMap { snapshots[$0] }
            let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.snapshot = snapshot
            view.onSelect = { [weak self] rect in
                guard let self = self, let snapshot = snapshot else { return }
                self.showPhaseB(selection: rect, screen: screen, snapshot: snapshot)
            }
            view.onCancel = { [weak self] in self?.finishCancel() }
            window.contentView = view

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }

        NSCursor.crosshair.set()
    }

    /// 无屏幕录制权限时的提示
    private func showScreenRecordingHelp() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "截图功能需要读取屏幕内容。请在“系统设置 → 隐私与安全性 → 屏幕录制”中勾选 ScreenDoodle，然后重新截屏。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
        }
    }

    // MARK: - 阶段 B：选区编辑

    private func showPhaseB(selection: NSRect, screen: NSScreen, snapshot: CGImage) {
        guard isRunning else { return }

        editScreen = screen
        fullScreenImage = NSImage(cgImage: snapshot, size: screen.frame.size)
        // 默认移动态（不选中任何标注工具）
        toolState.currentTool = nil
        toolState.onStateChanged?()

        // 阶段 B 复用选区所在屏幕的全屏覆盖窗口：窗口本身始终静止，
        // 拖动/缩放只重绘选区框（微信截图同款做法），彻底避免窗口移动与重绘不同步造成的抖动。
        // 其余屏幕的覆盖层转为不可交互的暗色冻结态，非选区位置无法操作。
        var targetWindow: NSWindow?
        for window in overlayWindows {
            if window.screen == screen || window.frame == screen.frame {
                targetWindow = window
            } else if let view = window.contentView as? SelectionOverlayView {
                view.isFrozen = true
                view.needsDisplay = true
            }
        }
        guard let window = targetWindow else { return }

        let view = ScreenshotEditView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.controller = self
        view.backgroundImage = fullScreenImage

        let canvasView = DoodleCanvasView(toolState: toolState, frame: selection)
        canvasView.onContentChanged = { [weak self] in self?.canvasContentChanged() }
        canvasView.onPickColor = { [weak self] in self?.startColorPicker() }
        view.canvas = canvasView
        view.addSubview(canvasView)

        window.contentView = view
        editWindow = window
        editView = view
        canvas = canvasView

        // 应用初始选区（夹取 + 定位画布 + 重绘选区框）
        applySelectionRect(selection)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if toolbarController == nil {
            toolbarController = ToolbarController(toolState: toolState, showsPinButton: true)
        }
        toolbarController?.host = self
        toolbarController?.show(anchoredTo: selectionRect, on: screen)

        NSCursor.openHand.set()
        canvasContentChanged()
    }

    /// 选区改变（移动/缩放）后的统一下发：夹取边界、移动画布子视图、只重绘选区脏区（窗口保持静止）
    func applySelectionRect(_ rect: NSRect) {
        guard let screen = editScreen, let view = editView else { return }
        let maxW = screen.frame.width
        let maxH = screen.frame.height
        let minW: CGFloat = 10
        let minH: CGFloat = 10

        var r = rect
        r.size.width = min(max(r.size.width, minW), maxW)
        r.size.height = min(max(r.size.height, minH), maxH)
        r.origin.x = min(max(r.origin.x, 0), maxW - r.size.width)
        r.origin.y = min(max(r.origin.y, 0), maxH - r.size.height)

        // 脏区 = 新旧选区并集外扩手柄尺寸，拖动时只重绘这一块，不重绘全屏
        let dirty = selectionRect.union(r).insetBy(dx: -12, dy: -12)
        selectionRect = r
        canvas?.frame = r
        view.selectionRect = r
        view.setNeedsDisplay(dirty)
        // 工具条跟随选区：始终锚定在选区下方并左对齐
        toolbarController?.reposition(anchoredTo: r, on: screen)
    }

    /// 全局鼠标位置换算成选区屏幕的局部点（原点左下），拖动/缩放据此计算，避免依赖窗口相对坐标产生抖动
    func mouseInScreen() -> NSPoint {
        let global = NSEvent.mouseLocation
        guard let screen = editScreen else { return global }
        return NSPoint(x: global.x - screen.frame.minX, y: global.y - screen.frame.minY)
    }

    func canvasContentChanged() {
        toolbarController?.refreshUndoRedo()
        let hasAnnotation = !(canvas?.elements.isEmpty ?? true)
        editView?.isLocked = hasAnnotation
        editView?.setNeedsDisplay(selectionRect.insetBy(dx: -12, dy: -12))
    }

    // MARK: - ToolbarHost

    var undoRedoState: (canUndo: Bool, canRedo: Bool) {
        (canvas?.canUndo ?? false, canvas?.canRedo ?? false)
    }

    func undo() {
        canvas?.undo()
        canvasContentChanged()
    }

    func redo() {
        canvas?.redo()
        canvasContentChanged()
    }

    func clear() {
        canvas?.clear()
        canvasContentChanged()
    }

    func finishTextEditing() {
        canvas?.finishTextInput()
    }

    func startColorPicker() {
        guard colorPickerOverlay == nil else { return }
        let picker = ColorPickerOverlay()
        colorPickerOverlay = picker

        picker.onPicked = { [weak self] color in
            guard let self = self else { return }
            self.colorPickerOverlay = nil
            self.toolState.currentColor = color
            if self.toolState.currentTool == .colorPicker {
                self.toolState.currentTool = nil
            }
            self.toolState.onStateChanged?()
            // 取色期间应用可能失焦，恢复激活与 key，保证文字输入/快捷键可用
            NSApp.activate(ignoringOtherApps: true)
            self.editWindow?.makeKey()
        }
        picker.onCancel = { [weak self] in
            guard let self = self else { return }
            self.colorPickerOverlay = nil
            if self.toolState.currentTool == .colorPicker {
                self.toolState.currentTool = nil
            }
            self.toolState.onStateChanged?()
            NSApp.activate(ignoringOtherApps: true)
            self.editWindow?.makeKey()
        }
        picker.start()
    }

    func dismiss(action: DismissAction) {
        switch action {
        case .cancel:
            finishCancel()
        case .copyOnly:
            completeByCopy()
        case .saveToFile:
            saveToFile()
        }
    }

    /// 图钉：渲染当前画面（含标注）交给 AppDelegate 钉住
    func pinCurrentImage() {
        guard isRunning else { return }
        let image = renderCompositeImage()
        finishSession()
        if let image = image {
            onPin?(image)
        }
    }

    // MARK: - 完成 / 保存 / 取消

    /// 双击或“完成”按钮：复制到剪贴板并结束
    func completeByCopy() {
        guard isRunning else { return }
        let image = renderCompositeImage()
        finishSession()
        if let image = image {
            ExportManager.copyToPasteboard(image)
        }
    }

    func saveToFile() {
        guard isRunning else { return }
        guard let image = renderCompositeImage() else {
            finishCancel()
            return
        }

        // 隐去选区编辑窗、冻结覆盖层与工具条，避免高层级窗口盖住保存面板；同时暂停按键监听，避免干扰文件名输入
        removeKeyMonitor()
        editWindow?.orderOut(nil)
        overlayWindows.forEach { $0.orderOut(nil) }
        toolbarController?.hide()

        let format = Settings.shared.exportFormat
        let ext = format == "jpg" ? "jpg" : "png"
        let defaultName = String(format: "截图-%@.%@", Self.timestampString(), ext)
        let dirURL = URL(fileURLWithPath: Settings.shared.exportDirectory)
        FileManager.default.tryCreateDirectory(at: Settings.shared.exportDirectory)

        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.prompt = "保存"
        panel.nameFieldLabel = "文件名"
        panel.directoryURL = dirURL
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .png]
        panel.allowsOtherFileTypes = false

        let response = panel.runModal()
        guard response == .OK, let saveURL = panel.url, let data = image.data(ext: ext) else {
            // 取消保存：恢复编辑态
            restoreEdit()
            return
        }

        do {
            try data.write(to: saveURL)
            finishSession()
        } catch {
            restoreEdit()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "保存失败"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    func finishCancel() {
        guard isRunning else { return }
        finishSession()
    }

    /// 保存被取消/失败时恢复编辑态
    private func restoreEdit() {
        // 先恢复冻结覆盖层，再恢复编辑窗与工具条，保证层级正确（覆盖层 < 编辑窗 < 工具条）
        overlayWindows.forEach { $0.orderFrontRegardless() }
        editWindow?.orderFrontRegardless()
        editWindow?.makeKey()
        if let screen = editScreen {
            toolbarController?.show(anchoredTo: selectionRect, on: screen)
        } else {
            toolbarController?.show()
        }
        installKeyMonitor()
    }

    // MARK: - 收尾

    /// 统一清理会话（不触发 onCancel/onPin）：复用 stop() 的清理逻辑，再额外归还激活权并通知外部释放引用
    private func finishSession() {
        stop()
        // 取消/完成后把激活权交还之前的前台应用，避免无窗口的 accessory 应用阻塞整屏点击
        NSApp.deactivate()
        onFinish?()
    }

    // MARK: - 键盘监听

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isRunning else { return event }
            // 取色进行中交给取色器处理 Esc
            if self.colorPickerOverlay != nil { return event }
            // 正在编辑文字时：Esc 提交文字，其余按键（含 Cmd+Z 文本撤销）交给输入视图
            if self.canvas?.isEditingText == true {
                if event.keyCode == UInt16(kVK_Escape) {
                    self.finishTextEditing()
                    return nil
                }
                return event
            }

            if event.keyCode == UInt16(kVK_Escape) {
                self.finishCancel()
                return nil
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) else { return event }
            if !flags.contains(.shift) && event.keyCode == UInt16(kVK_ANSI_Z) {
                self.undo()
                return nil
            }
            if flags.contains(.shift) && event.keyCode == UInt16(kVK_ANSI_Z) {
                self.redo()
                return nil
            }
            if event.keyCode == UInt16(kVK_ANSI_Y) {
                self.redo()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - 最终渲染

    /// 合并背景截图（不透明）与标注层（透明）为一张最终图片
    private func renderCompositeImage() -> NSImage? {
        let size = selectionRect.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = editScreen?.backingScaleFactor ?? 2.0

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        let previousContext = NSGraphicsContext.current
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        let rect = NSRect(origin: .zero, size: size)

        // 背景：不透明截图
        if let bg = editView?.backgroundImage {
            bg.draw(in: rect, from: selectionRect, operation: .copy, fraction: 1)
        } else {
            NSColor.black.setFill()
            rect.fill()
        }
        // 标注层
        if let annotation = canvas?.renderToImage() {
            annotation.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        context?.flushGraphics()
        // 归还上下文指针，避免位图上下文泄漏成为后续绘制的 current
        NSGraphicsContext.current = previousContext
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - 阶段 A：框选覆盖视图

/// 单块屏幕上的框选视图：显示全屏截图 + 半透明遮罩 + 白色选框 + 实时宽高，拖拽框出选区。
final class SelectionOverlayView: NSView {

    /// 全屏截图（CGImage，绘制时一次性转换为 NSImage 缓存，避免拖拽每帧重复构造）
    var snapshot: CGImage? {
        didSet { snapshotImage = snapshot.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } }
    }
    var onSelect: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    /// 冻结态：阶段 B（选区编辑）期间整屏只作暗色底，不再响应框选交互；区域高亮由编辑窗口独立呈现
    var isFrozen = false

    /// 全屏截图的 NSImage 缓存：拖动选框时 draw 每帧被调用，避免反复 CGImage→NSImage 装箱
    private var snapshotImage: NSImage?

    private var startPoint: NSPoint = .zero
    private var currentPoint: NSPoint = .zero
    private var isDragging = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // 冻结态：仅显示整屏截图并统一压暗，不再绘制选框/尺寸提示，也不凸显选区
        if isFrozen {
            if let image = snapshotImage {
                image.draw(in: bounds)
            } else {
                NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
                bounds.fill()
            }
            NSColor(calibratedWhite: 0, alpha: 0.4).setFill()
            bounds.fill()
            return
        }

        // 1. 背景：全屏截图（未就绪给深色底）
        if let image = snapshotImage {
            image.draw(in: bounds)
        } else {
            NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
            bounds.fill()
        }

        // 2. 半透明遮罩压暗全屏
        NSColor(calibratedWhite: 0, alpha: 0.4).setFill()
        bounds.fill()

        // 3. 选区：还原亮度 + 白框 + 尺寸提示
        if isDragging {
            let selection = normalizedSelection()
            if let image = snapshotImage {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: selection).addClip()
                image.draw(in: bounds)
                NSGraphicsContext.restoreGraphicsState()
            }

            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 1.5
            border.stroke()

            drawSizeLabel(for: selection)
        } else if snapshot == nil {
            drawHint()
        }
    }

    private func normalizedSelection() -> NSRect {
        let x = min(startPoint.x, currentPoint.x)
        let y = min(startPoint.y, currentPoint.y)
        let w = abs(currentPoint.x - startPoint.x)
        let h = abs(currentPoint.y - startPoint.y)
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func drawHint() {
        let message = "拖拽选择截图区域，Esc/右键取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (message as NSString).size(withAttributes: attrs)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height * 0.5)
        (message as NSString).draw(at: origin, withAttributes: attrs)
    }

    private func drawSizeLabel(for selection: NSRect) {
        let text = "\(Int(selection.width)) × \(Int(selection.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var origin = NSPoint(x: selection.minX, y: selection.maxY - size.height - 6)
        origin.x = min(max(origin.x, selection.minX + 4), selection.maxX - size.width - 4)
        origin.y = max(origin.y, selection.minY + 4)
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }

    /// 覆盖层刚弹出时应用可能尚未激活：直接接收首次点击，
    /// 避免 macOS 把第一次按下当作「激活点击」吞掉导致首次拖拽拉不出选框
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isFrozen { return }
        let p = convert(event.locationInWindow, from: nil)
        startPoint = p
        currentPoint = p
        isDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if isFrozen { return }
        let p = convert(event.locationInWindow, from: nil)
        currentPoint = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !isFrozen, isDragging else { return }
        isDragging = false
        let selection = normalizedSelection()
        if selection.width >= 4, selection.height >= 4 {
            onSelect?(selection)
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if isFrozen { return }
        onCancel?()
    }
}

// MARK: - 阶段 B：选区编辑视图

/// 选区编辑视图：全屏静止视图（与屏幕同大），负责绘制整屏压暗背景、选区亮区、
/// 白色选区边框与 8 个缩放手柄，并把鼠标事件分流为移动 / 缩放 / 双击完成 / 标注绘制。
/// 拖动/缩放只更新 selectionRect 并局部重绘，窗口本身不动，因此不会抖动。
final class ScreenshotEditView: NSView {

    /// 缩放手柄位置
    enum Handle: CaseIterable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
    }

    private enum DragMode {
        case none
        case move
        case resize(Handle)
    }

    weak var controller: ScreenshotController?
    var canvas: DoodleCanvasView!
    /// 背景大图（整屏、点尺寸）
    var backgroundImage: NSImage?
    /// 当前选区（屏幕局部点坐标，原点左下；与画布子视图 frame 一致）
    var selectionRect: NSRect = .zero
    /// 锁定后禁止移动/缩放（已产生标注时锁定，避免标注坐标错乱）
    var isLocked = false

    private let handleSize: CGFloat = 8
    private let hitInset: CGFloat = 4
    private var dragMode: DragMode = .none
    /// 标注会话标记：mouseDown 真正转发给画布后置真，拖动/抬起仅在会话中转发，
    /// 防止「选区外按下、随后拖动」让画布在缺少按下事件的情况下收到拖拽而崩溃
    private var isAnnotating = false
    /// 拖动起点：选区矩形与鼠标（选区屏幕局部坐标），整个拖动始终以起点 + 全局鼠标为基准，避免反馈抖动
    private var dragStartRect: NSRect = .zero
    private var dragStartMouse: NSPoint = .zero

    private var currentTool: DrawingTool? { controller?.toolState.currentTool }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // 1. 整屏背景截图 + 压暗（与阶段 A 冻结态一致，非选区不可操作）
        if let bg = backgroundImage {
            bg.draw(in: dirtyRect, from: dirtyRect, operation: .copy, fraction: 1)
        } else {
            NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
            dirtyRect.fill()
        }
        NSColor(calibratedWhite: 0, alpha: 0.4).setFill()
        dirtyRect.fill()

        // 2. 选区亮区：裁剪到选区后重绘背景截图还原亮度
        let selection = selectionRect
        if let bg = backgroundImage, selection.width > 0, selection.height > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            bg.draw(in: selection, from: selection, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }

        // 3. 白色选区边框
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        // 4. 手柄：仅移动态且未锁定时显示
        if !isLocked && currentTool == nil {
            for h in Handle.allCases {
                drawHandle(h)
            }
        }
    }

    private func drawHandle(_ h: Handle) {
        let rect = handleRect(h)
        NSColor.white.setFill()
        NSBezierPath(rect: rect).fill()
        NSColor(calibratedWhite: 0.35, alpha: 1).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    private func handleRect(_ h: Handle) -> NSRect {
        let r = selectionRect
        let s = handleSize
        func centered(_ x: CGFloat, _ y: CGFloat) -> NSRect {
            NSRect(x: x - s / 2, y: y - s / 2, width: s, height: s)
        }
        switch h {
        case .topLeft: return centered(r.minX, r.maxY)
        case .top: return centered(r.midX, r.maxY)
        case .topRight: return centered(r.maxX, r.maxY)
        case .left: return centered(r.minX, r.midY)
        case .right: return centered(r.maxX, r.midY)
        case .bottomLeft: return centered(r.minX, r.minY)
        case .bottom: return centered(r.midX, r.minY)
        case .bottomRight: return centered(r.maxX, r.minY)
        }
    }

    private func handle(at p: NSPoint) -> Handle? {
        guard !selectionRect.isEmpty else { return nil }
        for h in Handle.allCases where handleRect(h).insetBy(dx: -hitInset, dy: -hitInset).contains(p) {
            return h
        }
        return nil
    }

    // MARK: - 命中与鼠标跟踪

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 文字编辑中优先命中画布内的文本框；点击文本框外则落到本视图，用于提交文字
        if canvas.isEditingText, let hit = canvas.hitTest(point) {
            return hit
        }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    private func updateCursor(at p: NSPoint) {
        if currentTool != nil {
            // 标注工具：选区内十字准星，选区外箭头（不可绘制）
            (selectionRect.contains(p) ? NSCursor.crosshair : NSCursor.arrow).set()
        } else if isLocked {
            NSCursor.arrow.set()
        } else if let h = handle(at: p) {
            cursor(for: h).set()
        } else if selectionRect.contains(p) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func cursor(for h: Handle) -> NSCursor {
        switch h {
        case .top, .bottom: return NSCursor.resizeUpDown
        case .left, .right: return NSCursor.resizeLeftRight
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return NSCursor.crosshair
        }
    }

    // MARK: - 鼠标事件分流

    override func mouseDown(with event: NSEvent) {
        guard let controller = controller else { return }
        let p = convert(event.locationInWindow, from: nil)

        // 快速左键双击任意位置 → 完成并复制（文字编辑中除外，避免与选词/光标定位冲突）
        if event.clickCount == 2, !canvas.isEditingText {
            controller.completeByCopy()
            return
        }

        // 标注模式：仅选区内点击转发给画布绘制；文字编辑中点击选区外则提交文字
        if currentTool != nil {
            if selectionRect.contains(p) || canvas.isEditingText {
                isAnnotating = true
                canvas.mouseDown(with: event)
            }
            return
        }

        if isLocked { return }

        dragStartRect = controller.selectionRect
        dragStartMouse = controller.mouseInScreen()

        if let h = handle(at: p) {
            dragMode = .resize(h)
            cursor(for: h).set()
        } else if selectionRect.contains(p) {
            dragMode = .move
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller = controller else { return }

        if currentTool != nil {
            // 仅标注会话内的拖拽才转发（按下事件确实被画布接收过）
            if isAnnotating {
                canvas.mouseDragged(with: event)
            }
            return
        }

        let mouse = controller.mouseInScreen()
        switch dragMode {
        case .move:
            let dx = mouse.x - dragStartMouse.x
            let dy = mouse.y - dragStartMouse.y
            var r = dragStartRect
            r.origin = NSPoint(x: dragStartRect.origin.x + dx, y: dragStartRect.origin.y + dy)
            controller.applySelectionRect(r)
            NSCursor.closedHand.set()
        case .resize(let h):
            let rect = resizedRect(handle: h, base: dragStartRect, mouse: mouse)
            controller.applySelectionRect(rect)
            cursor(for: h).set()
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if currentTool != nil {
            // 与 mouseDragged 对应：仅会话内的抬起才转发，并重置会话标记
            if isAnnotating {
                canvas.mouseUp(with: event)
                controller?.canvasContentChanged()
            }
            isAnnotating = false
            return
        }
        dragMode = .none
        controller?.canvasContentChanged()
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.finishCancel()
    }

    // MARK: - 缩放几何

    private func resizedRect(handle: Handle, base r: NSRect, mouse: NSPoint) -> NSRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        let minW: CGFloat = 10
        let minH: CGFloat = 10

        switch handle {
        case .topLeft:
            minX = min(r.maxX - minW, mouse.x)
            maxY = max(r.minY + minH, mouse.y)
        case .top:
            maxY = max(r.minY + minH, mouse.y)
        case .topRight:
            maxX = max(r.minX + minW, mouse.x)
            maxY = max(r.minY + minH, mouse.y)
        case .left:
            minX = min(r.maxX - minW, mouse.x)
        case .right:
            maxX = max(r.minX + minW, mouse.x)
        case .bottomLeft:
            minX = min(r.maxX - minW, mouse.x)
            minY = min(r.maxY - minH, mouse.y)
        case .bottom:
            minY = min(r.maxY - minH, mouse.y)
        case .bottomRight:
            maxX = max(r.minX + minW, mouse.x)
            minY = min(r.maxY - minH, mouse.y)
        }

        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}