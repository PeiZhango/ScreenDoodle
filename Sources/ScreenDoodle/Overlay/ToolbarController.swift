import AppKit

/// 收起涂鸦/截图时的导出行为。
enum DismissAction {
    case cancel      // 不导出，直接收起
    case copyOnly    // 仅复制到剪贴板，不落盘
    case saveToFile  // 弹出保存面板，由用户确认文件名后保存到设置目录
}

/// 工具条宿主协议：涂鸦覆盖层与截图选区编辑会话都遵循它，
/// 从而复用同一套工具条按钮与回调。
protocol ToolbarHost: AnyObject {
    func undo()
    func redo()
    func clear()
    func dismiss(action: DismissAction)
    func finishTextEditing()
    func startColorPicker()
    var undoRedoState: (canUndo: Bool, canRedo: Bool) { get }
    /// 图钉：把当前画面渲染后钉到桌面最顶层浮动窗（默认无实现，涂鸦覆盖层不使用）
    func pinCurrentImage()
}

extension ToolbarHost {
    func pinCurrentImage() {}
}

/// 不抢占 key 状态的面板：点击其上按钮时涂鸦覆盖窗仍保持 key，
/// 这样选中工具后可直接在画布上绘制，无需先点一下画布“唤醒”。
final class ToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 工具条背景视图：白色 → 浅蓝灰渐变 + 圆角 + 细描边，直接 draw 保证稳定渲染。
final class ToolbarBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 13, yRadius: 13)
        NSGradient(
            starting: NSColor(calibratedWhite: 1.0, alpha: 0.98),
            ending: NSColor(calibratedRed: 0.88, green: 0.92, blue: 1.0, alpha: 0.98)
        )?.draw(in: path, angle: -90)
        NSColor(calibratedWhite: 0.76, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// 支持悬停回调的按钮：自身作为 NSTrackingArea 的 owner（NSView 处于窗口 responder 链中，
/// 事件才能送达），并在 updateTrackingAreas 中随布局自动重建跟踪区域，
/// 保证无论在什么时机显示面板都能正确命中。
final class HoverTrackingButton: NSButton {
    var onHoverEnter: (() -> Void)?
    var onHoverExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHoverEnter?() }
    override func mouseExited(with event: NSEvent) { onHoverExit?() }
}

/// 支持悬停回调的滑块，原理同 HoverTrackingButton
final class HoverTrackingSlider: NSSlider {
    var onHoverEnter: (() -> Void)?
    var onHoverExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHoverEnter?() }
    override func mouseExited(with event: NSEvent) { onHoverExit?() }
}

/// 悬浮工具条控制器：一个无边框面板，展示工具按钮、颜色、笔宽、撤销/重做、清除与导出。
final class ToolbarController: NSObject {

    private let toolState: ToolState
    private var panel: NSPanel!
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var colorButton: NSButton!
    /// 悬停名称提示窗口与标签。
    /// 注意：macOS 26+ 的 Liquid Glass 会对 NSPanel 强制渲染玻璃材质背景（backgroundColor 清不掉），
    /// 必须改用 borderless 的 NSWindow（与涂鸦覆盖窗一致）才能保持完全透明。
    private var hoverPanel: NSWindow!
    private var hoverLabel: NSTextField!
    /// 所有工具按钮，用于刷新互斥选中态
    private var toolButtons: [NSButton] = []
    /// 延迟隐藏的任务：跨按钮移动时若在间隔内进入下一个按钮则取消隐藏，避免闪烁
    private var hideWorkItem: DispatchWorkItem?

    /// 撤销/重做/清除/导出等操作由外部宿主控制器处理
    weak var host: ToolbarHost?
    /// 是否显示图钉按钮（截图选区编辑会话显示，涂鸦覆盖层不显示）
    private let showsPinButton: Bool

    init(toolState: ToolState, showsPinButton: Bool = false) {
        self.toolState = toolState
        self.showsPinButton = showsPinButton
        super.init()
        // 状态变化（如取色、文字一次性完成后回退工具）时同步刷新工具条
        toolState.onStateChanged = { [weak self] in self?.refreshAll() }
        buildPanel()
    }

    private func buildPanel() {
        let panel = ToolbarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 60),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        // 固定浅色外观：工具条整体提亮，图标/按钮以深色呈现保证可读性
        panel.appearance = NSAppearance(named: .aqua)
        // 层级需高于涂鸦覆盖层(.statusBar)，否则工具条会被覆盖无法点选/拖动
        panel.level = .statusBar + 1
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        // 用固定尺寸创建背景视图，避免依赖面板初始 bounds，保证渐变背景一定渲染
        let content = ToolbarBackgroundView(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        panel.contentView = content

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        // 工具按钮区
        for tool in DrawingTool.allCases {
            let btn = makeToolButton(tool)
            stack.addArrangedSubview(btn)
        }

        stack.addArrangedSubview(makeSeparator())

        // 颜色选择
        stack.addArrangedSubview(makeColorButton())

        // 笔宽滑块
        stack.addArrangedSubview(makeWidthSlider())

        stack.addArrangedSubview(makeSeparator())

        // 撤销/重做
        undoButton = makeActionButton(symbol: "arrow.uturn.backward", title: "撤销") { [weak self] in
            self?.host?.undo()
        }
        redoButton = makeActionButton(symbol: "arrow.uturn.forward", title: "重做") { [weak self] in
            self?.host?.redo()
        }
        stack.addArrangedSubview(undoButton)
        stack.addArrangedSubview(redoButton)

        // 清除
        stack.addArrangedSubview(
            makeActionButton(symbol: "trash", title: "清除") { [weak self] in self?.host?.clear() }
        )

        // 保存到文件（弹出保存面板，可改文件名）
        let save = makeActionButton(symbol: "square.and.arrow.down", title: "保存") { [weak self] in
            self?.host?.dismiss(action: .saveToFile)
        }
        save.bezelColor = NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.85, alpha: 1)
        save.contentTintColor = .white
        stack.addArrangedSubview(save)

        // 图钉：把当前画面渲染后钉到桌面最顶层浮动窗（仅截图会话显示）
        if showsPinButton {
            let pin = makeActionButton(symbol: "pin.fill", title: "图钉") { [weak self] in
                self?.host?.pinCurrentImage()
            }
            pin.bezelColor = NSColor(calibratedRed: 0.85, green: 0.60, blue: 0.15, alpha: 1)
            pin.contentTintColor = .white
            stack.addArrangedSubview(pin)
        }

        // 完成（仅复制到剪贴板，不落盘）
        let done = makeActionButton(symbol: "checkmark.circle", title: "完成") { [weak self] in
            self?.host?.dismiss(action: .copyOnly)
        }
        done.bezelColor = NSColor(calibratedRed: 0.2, green: 0.6, blue: 0.3, alpha: 1)
        done.contentTintColor = .white
        stack.addArrangedSubview(done)

        // 取消（不导出，直接收起涂鸦）
        let cancel = makeActionButton(symbol: "xmark.circle", title: "取消") { [weak self] in
            self?.host?.dismiss(action: .cancel)
        }
        cancel.bezelColor = NSColor(calibratedRed: 0.75, green: 0.25, blue: 0.25, alpha: 1)
        cancel.contentTintColor = .white
        stack.addArrangedSubview(cancel)

        panel.setContentSize(content.frame.size)
        panel.center()
        self.panel = panel

        // 预创建提示面板：避免首次悬停时创建面板的开销，保证所有按钮提示速度一致
        precreateHoverPanel()
    }

    private func makeToolButton(_ tool: DrawingTool) -> NSButton {
        let btn = HoverTrackingButton()
        btn.bezelStyle = .texturedRounded
        btn.image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.title)
        btn.setButtonType(.pushOnPushOff)
        btn.state = (tool == toolState.currentTool) ? .on : .off
        // 未选中为深灰图标；选中后系统 aqua 高亮底 + 白色图标
        btn.contentTintColor = (tool == toolState.currentTool) ? .white : NSColor(calibratedWhite: 0.07, alpha: 1)
        btn.target = self
        btn.action = #selector(toolSelected(_:))
        btn.tag = DrawingTool.allCases.firstIndex(of: tool) ?? 0
        btn.widthAnchor.constraint(equalToConstant: 34).isActive = true
        toolButtons.append(btn)
        setupHover(for: btn, title: tool.title)
        return btn
    }

    @objc private func toolSelected(_ sender: NSButton) {
        let tool = DrawingTool.allCases[sender.tag]
        // 切换工具前提交并关闭正在编辑的文字输入框，避免残留
        host?.finishTextEditing()

        if tool == .colorPicker {
            // 取色为一次性工具：点选即弹出放大镜，取色完成后回到移动态（currentTool = nil）
            toolState.currentTool = .colorPicker
            DispatchQueue.main.async { [weak self] in
                self?.host?.startColorPicker()
            }
            toolState.onStateChanged?()
            return
        }

        // 再次点击已选中的普通标注工具 → 取消选中，回到移动态（currentTool = nil）
        if toolState.currentTool == tool {
            toolState.currentTool = nil
        } else {
            toolState.currentTool = tool
        }
        toolState.onStateChanged?()
    }

    private func refreshToolButtons() {
        // 仅当前工具保持选中态，其余全部取消，实现互斥单选
        let current = toolState.currentTool
        for btn in toolButtons {
            let tool = DrawingTool.allCases[btn.tag]
            let selected = tool == current
            btn.state = selected ? .on : .off
            btn.contentTintColor = selected ? .white : NSColor(calibratedWhite: 0.07, alpha: 1)
        }
    }

    private func refreshAll() {
        refreshToolButtons()
        refreshColorButtonImage()
    }

    private func makeColorButton() -> NSButton {
        let btn = HoverTrackingButton()
        btn.bezelStyle = .regularSquare
        btn.isBordered = false // 去掉按钮自带外框，只显示纯色正方形色块
        btn.imagePosition = .imageOnly
        btn.target = self
        btn.action = #selector(openColorPanel(_:))
        btn.widthAnchor.constraint(equalToConstant: 44).isActive = true
        colorButton = btn
        refreshColorButtonImage()
        setupHover(for: btn, title: "选择颜色")
        return btn
    }

    /// 用当前颜色绘制一个纯色正方形色块，供颜色按钮展示（无外框）
    private func refreshColorButtonImage() {
        let size = NSSize(width: 26, height: 26)
        let image = NSImage(size: size, flipped: false) { rect in
            let swatch = rect.insetBy(dx: 2, dy: 2)
            self.toolState.currentColor.setFill()
            NSBezierPath(rect: swatch).fill()
            return true
        }
        colorButton?.image = image
    }

    @objc private func openColorPanel(_ sender: NSButton) {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = toolState.currentColor
        panel.isContinuous = false
        // 手动抬高层级并改为可见即 key，避免被涂鸦覆盖层盖住无法点选
        panel.level = .statusBar + 2
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        toolState.currentColor = sender.color
        toolState.onStateChanged?()
        refreshColorButtonImage()
    }

    /// 抬高系统调色板层级，使其位于涂鸦层与工具条之上，避免被覆盖无法点选。
    private func prepareSystemPanels() {
        let colorPanel = NSColorPanel.shared
        colorPanel.level = .statusBar + 2
        colorPanel.becomesKeyOnlyIfNeeded = false
        colorPanel.hidesOnDeactivate = false
    }

    private func makeWidthSlider() -> NSSlider {
        let slider = HoverTrackingSlider(value: Double(toolState.lineWidth), minValue: 1, maxValue: 40, target: self, action: #selector(widthChanged(_:)))
        slider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        setupHover(for: slider, title: "笔宽")
        return slider
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        toolState.lineWidth = CGFloat(sender.doubleValue)
        toolState.onStateChanged?()
    }

    private func makeActionButton(symbol: String, title: String, action: @escaping () -> Void) -> NSButton {
        let btn = HoverTrackingButton()
        btn.bezelStyle = .texturedRounded
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        btn.target = self
        btn.action = #selector(runAction(_:))
        btn.title = title
        btn.imagePosition = .imageOnly
        btn.contentTintColor = NSColor(calibratedWhite: 0.07, alpha: 1)
        btn.widthAnchor.constraint(equalToConstant: 34).isActive = true
        // 保存 action 闭包到关联对象
        objc_setAssociatedObject(btn, "actionKey", action, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        setupHover(for: btn, title: title)
        return btn
    }

    @objc private func runAction(_ sender: NSButton) {
        if let action = objc_getAssociatedObject(sender, "actionKey") as? (() -> Void) {
            action()
        }
    }

    private func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    // MARK: - 悬停工具名称提示

    /// 给按钮/滑块绑定悬停回调：进入时显示提示气泡，移出时延迟隐藏（避免跨控件切换闪烁）。
    /// 跟踪区域由控件自身（HoverTrackingButton / HoverTrackingSlider）在 updateTrackingAreas 中维护，
    /// owner 必须是处于窗口 responder 链中的 NSView。
    /// 此前以 ToolbarController（纯 NSObject，不在 responder 链）作 owner，mouseEntered 事件永远收不到。
    private func setupHover(for view: NSView, title: String) {
        if let btn = view as? HoverTrackingButton {
            btn.onHoverEnter = { [weak self, weak btn] in
                guard let self = self, let btn = btn else { return }
                self.showHover(title, for: btn)
            }
            btn.onHoverExit = { [weak self] in self?.scheduleHideHover() }
        } else if let slider = view as? HoverTrackingSlider {
            slider.onHoverEnter = { [weak self, weak slider] in
                guard let self = self, let slider = slider else { return }
                self.showHover(title, for: slider)
            }
            slider.onHoverExit = { [weak self] in self?.scheduleHideHover() }
        }
    }

    /// 延迟隐藏提示：若鼠标在 60ms 内进入相邻控件，showHover 会取消此任务，避免先隐后显闪烁
    private func scheduleHideHover() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hoverPanel?.orderOut(nil)
            self?.hideWorkItem = nil
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    /// 预创建提示窗口，避免首次悬停时因创建窗口导致响应变慢，保证所有按钮提示速度一致。
    /// 样式极简：完全透明无背景、无阴影的纯文字提示；常规字重，蓝灰字色与工具栏浅色渐变基调协调。
    private func precreateHoverPanel() {
        let p = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 14),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.hasShadow = false
        p.backgroundColor = .clear
        p.level = .statusBar + 3
        // 提示窗口不拦截鼠标，避免鼠标进入提示区域触发 tracking 抖动
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = NSColor(calibratedRed: 0.32, green: 0.36, blue: 0.48, alpha: 1)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        p.contentView?.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: p.contentView!.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: p.contentView!.centerYAnchor)
        ])
        hoverPanel = p
        hoverLabel = label
    }

    /// 在控件上方展示一个小气泡，显示工具名称（面板已在 buildPanel 时预创建，此处仅更新内容与位置）
    private func showHover(_ title: String, for view: NSView) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        hoverLabel.stringValue = title
        hoverLabel.sizeToFit()
        let labelWidth = max(hoverLabel.frame.width + 16, 48)
        var frame = hoverPanel.frame
        frame.size = NSSize(width: labelWidth, height: 14)
        hoverPanel.setFrame(frame, display: false)

        // 定位：水平跟随控件中心；垂直把提示文字置于工具栏窗口顶边与工具图标顶边之间居中的位置。
        let viewFrameInWindow = view.convert(view.bounds, to: nil)
        let screenRect = panel.convertToScreen(viewFrameInWindow)
        let toolbarTop = panel.frame.maxY
        let iconTop = screenRect.maxY
        let centerY = (toolbarTop + iconTop) / 2
        let origin = NSPoint(x: screenRect.midX - frame.width / 2, y: centerY - frame.height / 2)
        hoverPanel.setFrameOrigin(origin)
        hoverPanel.orderFrontRegardless()
    }

    private func hideHover() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        hoverPanel?.orderOut(nil)
    }

    // MARK: - 显示/隐藏

    func show() {
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        refreshUndoRedo()
        prepareSystemPanels()
    }

    /// 截图模式：把工具条锚定到选区下方、与选区左对齐显示
    /// - Parameters:
    ///   - rect: 选区矩形（屏幕局部点坐标，原点左下）
    ///   - screen: 选区所在屏幕
    func show(anchoredTo rect: NSRect, on screen: NSScreen) {
        reposition(anchoredTo: rect, on: screen)
        panel?.makeKeyAndOrderFront(nil)
        refreshUndoRedo()
        prepareSystemPanels()
    }

    /// 跟随选区位置更新工具条位置（拖动/缩放选区时逐帧调用）。
    /// 优先放在选区下方并与选区左对齐；下方空间不足时改放到选区上方；整体夹取在屏幕内。
    func reposition(anchoredTo rect: NSRect, on screen: NSScreen) {
        guard let panel = panel else { return }
        let margin: CGFloat = 8
        let size = panel.frame.size
        // 选区矩形为屏幕局部坐标（原点左下），换算为全局坐标
        let globalRect = NSRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.minY + rect.minY,
            width: rect.width,
            height: rect.height
        )
        // 水平：与选区左对齐，越界时夹取回屏幕内
        let x = min(max(globalRect.minX, screen.frame.minX), screen.frame.maxX - size.width)
        // 垂直：优先放选区下方；下方空间不足则改放选区上方
        var y = globalRect.minY - margin - size.height
        if y < screen.frame.minY {
            y = globalRect.maxY + margin
        }
        y = min(max(y, screen.frame.minY), screen.frame.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func hide() {
        panel?.orderOut(nil)
        hideHover()
    }

    func refreshUndoRedo() {
        let state = host?.undoRedoState
        undoButton?.isEnabled = state?.canUndo ?? false
        redoButton?.isEnabled = state?.canRedo ?? false
    }
}