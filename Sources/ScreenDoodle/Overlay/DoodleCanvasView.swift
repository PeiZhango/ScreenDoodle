import AppKit

/// 单块屏幕的涂鸦画布。透明视图，捕获鼠标事件并维护元素列表与撤销栈。
final class DoodleCanvasView: NSView {

    /// 共享的工具状态
    let toolState: ToolState
    /// 当前屏幕缩放坐标系（点坐标）
    var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0 }

    /// 已完成的元素列表
    private(set) var elements: [DrawingElement] = []
    /// 撤销栈（存储每次操作前的元素快照）
    private var undoStack: [[DrawingElement]] = []
    /// 重做栈
    private var redoStack: [[DrawingElement]] = []

    /// 当前正在绘制的元素
    private var activeElement: DrawingElement?
    /// 鼠标按下时的起点
    private var startPoint: CGPoint = .zero
    /// 文字输入视图（多行，支持回车换行）
    private var textView: NSTextView?
    /// 取色入口回调（由覆盖控制器注入，触发自研取色器）
    var onPickColor: (() -> Void)?

    /// 内容有变化时回调（用于工具条更新撤销/重做按钮可用状态）
    var onContentChanged: (() -> Void)?

    /// 是否正在编辑文字（截图选区编辑会话用它把点击正确地路由给文本视图）
    var isEditingText: Bool { textView != nil }

    init(toolState: ToolState, frame: NSRect) {
        self.toolState = toolState
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 鼠标事件

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startPoint = p

        guard let tool = toolState.currentTool else {
            needsDisplay = true
            return
        }

        switch tool {
        case .pen, .highlighter, .eraser, .mosaic:
            let path = NSBezierPath()
            path.move(to: p)
            activeElement = makeElement(tool: tool, path: path, rect: nil)
            beginUndoSnapshot()
        case .line, .arrow:
            let path = NSBezierPath()
            path.move(to: p)
            path.line(to: p)
            var el = makeElement(tool: tool, path: path, rect: nil)
            el.arrowStart = p
            el.arrowEnd = p
            activeElement = el
            beginUndoSnapshot()
        case .rectangle, .ellipse:
            activeElement = makeElement(tool: tool, path: nil, rect: NSRect(origin: p, size: .zero))
            beginUndoSnapshot()
        case .text:
            if textView != nil {
                // 正在编辑文字，点击外部视为提交并退出文字模式（不新建输入框）
                finishTextInput()
            } else {
                // 弹出文字输入框
                beginTextInput(at: p)
            }
        case .colorPicker:
            // 取色模式兜底：直接触发自研取色器
            onPickColor?()
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        guard let tool = toolState.currentTool else {
            needsDisplay = true
            return
        }

        switch tool {
        case .pen, .highlighter, .eraser, .mosaic:
            activeElement?.path?.line(to: p)
        case .line, .arrow:
            if activeElement?.path != nil {
                let rebuilt = NSBezierPath()
                rebuilt.move(to: startPoint)
                rebuilt.line(to: p)
                var el = activeElement!
                el.path = rebuilt
                el.arrowEnd = p
                activeElement = el
            }
        case .rectangle, .ellipse:
            // activeElement 可能为空（如按下事件未被画布接收、仅收到拖拽），此处必须保护
            guard var el = activeElement else { return }
            el.rect = Self.normalizedRect(from: startPoint, to: p)
            activeElement = el
        default:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let tool = toolState.currentTool else {
            needsDisplay = true
            return
        }

        switch tool {
        case .pen, .highlighter, .eraser, .line, .arrow, .rectangle, .ellipse, .mosaic:
            if let el = activeElement, !el.isEmpty {
                elements.append(el)
            }
            activeElement = nil
            contentChanged()
        default:
            break
        }
        needsDisplay = true
    }

    // MARK: - 元素构造

    private func makeElement(tool: DrawingTool, path: NSBezierPath?, rect: NSRect?) -> DrawingElement {
        var color = toolState.currentColor
        var width = toolState.lineWidth
        if tool == .highlighter {
            color = color.withAlphaComponent(0.35)
            width = max(width * 3, 18)
        }
        if tool == .eraser {
            color = NSColor.clear
            width = max(width * 4, 20)
        }
        if tool == .mosaic {
            // 马赛克为涂抹笔刷，使用适中偏宽的刷头
            width = max(width * 3, 16)
        }
        return DrawingElement(
            tool: tool,
            color: color,
            lineWidth: width,
            path: path,
            rect: rect,
            text: nil,
            textOrigin: nil,
            arrowStart: nil,
            arrowEnd: nil
        )
    }

    /// 将任意方向拖拽标准化为正向矩形
    static func normalizedRect(from a: CGPoint, to b: CGPoint) -> NSRect {
        let x = min(a.x, b.x)
        let y = min(a.y, b.y)
        let w = abs(a.x - b.x)
        let h = abs(a.y - b.y)
        return NSRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - 文字输入

    private func beginTextInput(at point: CGPoint) {
        finishTextInput()

        // 多行输入视图：回车换行，随内容自动向下增高；点击空白处或 Esc 提交
        let font = NSFont.systemFont(ofSize: 20)
        let width: CGFloat = 300
        let initialHeight: CGFloat = 28
        // 水平方向夹取在画布内，避免输入框超出右边缘
        let x = min(max(point.x, 0), max(bounds.width - width, 0))
        let textView = NSTextView(frame: NSRect(x: x, y: point.y - 24, width: width, height: initialHeight))
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = toolState.currentColor
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: toolState.currentColor
        ]
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        // 内边距与行段留白清零，保证提交后按原框重绘时位置与编辑时一致
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // 宽度跟随视图、高度不限（由 textDidChange 按内容手动增高）
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.delegate = self
        addSubview(textView)
        self.textView = textView
        // 覆盖层已是 key window，此处需让输入视图成为第一响应者才能接收键盘输入
        window?.makeFirstResponder(textView)
    }

    /// 提交并关闭正在编辑的文字输入视图（若存在）
    func finishTextInput() {
        guard let textView = textView else { return }
        // 先取出内容并置空标记，防止 removeFromSuperview 触发 textDidEndEditing 重入导致重复提交
        let text = textView.string
        let color = textView.textColor ?? toolState.currentColor
        let origin = textView.frame.origin
        let size = textView.frame.size
        self.textView = nil

        if !text.isEmpty {
            var element = DrawingElement(
                tool: .text,
                color: color,
                lineWidth: 20,
                path: nil,
                rect: nil,
                text: text,
                textOrigin: origin,
                arrowStart: nil,
                arrowEnd: nil
            )
            // 记录编辑框尺寸，提交后按原框排版绘制，保证位置与编辑时完全一致
            element.textSize = size
            beginUndoSnapshot()
            elements.append(element)
            contentChanged()
        }
        textView.removeFromSuperview()
        needsDisplay = true

        // 文字为一次性工具：完成输入后不选中任何工具，等待用户重新选择
        if toolState.currentTool == .text {
            toolState.currentTool = nil
            toolState.onStateChanged?()
        }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 裁剪到画布范围（截图会话中即选区范围）：AppKit 不会自动把绘制裁剪到 bounds，
        // 粗笔触（高亮/马赛克/橡皮擦）靠近边缘时越界内容需要在这里裁掉
        NSBezierPath(rect: bounds).addClip()
        // 绘制已完成元素
        for element in elements {
            draw(element: element)
        }
        // 绘制进行中的元素
        if let element = activeElement {
            draw(element: element)
        }
    }

    private func draw(element: DrawingElement) {
        switch element.tool {
        case .pen, .highlighter, .eraser:
            if let path = element.path {
                element.color.setStroke()
                path.lineWidth = element.lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                if element.tool == .eraser {
                    // 橡皮擦使用 clear 混合模式擦除到透明
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current?.compositingOperation = .clear
                    path.stroke()
                    NSGraphicsContext.restoreGraphicsState()
                } else {
                    path.stroke()
                }
            }
        case .line:
            if let path = element.path {
                element.color.setStroke()
                path.lineWidth = element.lineWidth
                path.lineCapStyle = .round
                path.stroke()
            }
        case .arrow:
            drawArrow(element)
        case .rectangle:
            if let rect = element.rect {
                element.color.setStroke()
                let path = NSBezierPath(rect: rect)
                path.lineWidth = element.lineWidth
                path.stroke()
            }
        case .ellipse:
            if let rect = element.rect {
                element.color.setStroke()
                let path = NSBezierPath(ovalIn: rect)
                path.lineWidth = element.lineWidth
                path.stroke()
            }
        case .text:
            if let text = element.text, let origin = element.textOrigin {
                // 与编辑时同字号、同框架排版绘制（支持多行），保证提交后位置与编辑时一致
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: element.lineWidth),
                    .foregroundColor: element.color
                ]
                let size = element.textSize ?? NSSize(width: 300, height: 28)
                (text as NSString).draw(in: NSRect(origin: origin, size: size), withAttributes: attrs)
            }
        case .mosaic:
            drawMosaic(element)
        default:
            break
        }
    }

    private func drawArrow(_ element: DrawingElement) {
        guard let from = element.arrowStart, let end = element.arrowEnd else { return }

        element.color.setStroke()
        let angle = atan2(end.y - from.y, end.x - from.x)
        let headLen: CGFloat = max(element.lineWidth * 3, 14)
        // 直线终点内缩，停在三角形底边处，避免直线戳穿箭头头部
        let lineEnd = CGPoint(
            x: end.x - headLen * 0.8 * cos(angle),
            y: end.y - headLen * 0.8 * sin(angle)
        )
        let line = NSBezierPath()
        line.move(to: from)
        line.line(to: lineEnd)
        line.lineWidth = element.lineWidth
        line.lineCapStyle = .round
        line.stroke()

        // 箭头头部：两个短边
        let headAngle: CGFloat = .pi / 6
        let p1 = CGPoint(
            x: end.x - headLen * cos(angle - headAngle),
            y: end.y - headLen * sin(angle - headAngle)
        )
        let p2 = CGPoint(
            x: end.x - headLen * cos(angle + headAngle),
            y: end.y - headLen * sin(angle + headAngle)
        )
        element.color.setFill()
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: p1)
        head.line(to: p2)
        head.close()
        head.fill()
    }

    private func drawMosaic(_ element: DrawingElement) {
        guard let path = element.path else { return }
        // 马赛克：沿涂抹路径铺随机灰度色块，达到隐私遮挡效果
        // 色块大小取笔宽的 1/3 且不小于 6pt，让马赛克颗粒更细腻
        let blockSize = max(element.lineWidth / 3, 6)
        var centers: [CGPoint] = []
        var last = CGPoint.zero

        for i in 0..<path.elementCount {
            var pts: [CGPoint] = [.zero, .zero, .zero]
            let type = path.element(at: i, associatedPoints: &pts)
            switch type {
            case .moveTo:
                last = pts[0]
                centers.append(last)
            case .lineTo:
                let to = pts[0]
                let dist = hypot(to.x - last.x, to.y - last.y)
                let steps = max(Int(dist / (blockSize * 0.7)), 1)
                for s in 1...steps {
                    let t = CGFloat(s) / CGFloat(steps)
                    centers.append(CGPoint(
                        x: last.x + (to.x - last.x) * t,
                        y: last.y + (to.y - last.y) * t
                    ))
                }
                last = to
            default:
                break
            }
        }

        for (i, c) in centers.enumerated() {
            // 用确定性伪随机保证重绘时色块不闪烁
            let gray = 0.25 + 0.65 * deterministicUnit(i * 3)
            let jx = (deterministicUnit(i * 3 + 1) - 0.5) * blockSize * 0.5
            let jy = (deterministicUnit(i * 3 + 2) - 0.5) * blockSize * 0.5
            NSColor(calibratedWhite: gray, alpha: 1).setFill()
            NSRect(
                x: c.x - blockSize / 2 + jx,
                y: c.y - blockSize / 2 + jy,
                width: blockSize,
                height: blockSize
            ).fill()
        }
    }

    /// 确定性伪随机：整数种子 → [0,1) 稳定值
    private func deterministicUnit(_ seed: Int) -> CGFloat {
        var x = UInt64(seed &* 1_103_515_245 &+ 12_345) & 0x7FFF_FFFF
        x = (x &* 1_103_515_245 &+ 12_345) & 0x7FFF_FFFF
        x = (x &* 1_103_515_245 &+ 12_345) & 0x7FFF_FFFF
        return CGFloat(x % 1000) / 999.0
    }

    // MARK: - 撤销 / 重做

    private func beginUndoSnapshot() {
        undoStack.append(elements)
        redoStack.removeAll()
        contentChanged()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(elements)
        elements = last
        contentChanged()
        needsDisplay = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(elements)
        elements = next
        contentChanged()
        needsDisplay = true
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// 清空画布
    func clear() {
        beginUndoSnapshot()
        elements.removeAll()
        contentChanged()
        needsDisplay = true
    }

    /// 供导出时渲染到位图
    func renderToImage() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = backingScale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale),
            pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = bounds.size

        NSGraphicsContext.saveGraphicsState()
        let previousContext = NSGraphicsContext.current
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        // 透明背景
        NSColor.clear.setFill()
        bounds.fill()
        for element in elements {
            draw(element: element)
        }
        context?.flushGraphics()
        // 归还上下文指针，避免位图上下文泄漏成为后续绘制的 current
        NSGraphicsContext.current = previousContext
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func contentChanged() {
        onContentChanged?()
    }
}

extension DoodleCanvasView: NSTextViewDelegate {
    /// 输入视图失焦（点击空白处/切换工具）时提交文字
    func textDidEndEditing(_ notification: Notification) {
        finishTextInput()
    }

    /// 随内容自动增高：保持顶边不动，向下增长
    func textDidChange(_ notification: Notification) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let contentHeight = layoutManager.usedRect(for: container).height
        let newHeight = max(contentHeight, 28)
        guard abs(newHeight - textView.frame.height) > 0.5 else { return }
        textView.frame = NSRect(
            x: textView.frame.minX,
            y: textView.frame.maxY - newHeight,
            width: textView.frame.width,
            height: newHeight
        )
    }
}

// MARK: - DrawingElement 空判定

extension DrawingElement {
    var isEmpty: Bool {
        if let path = path, !path.isEmpty { return false }
        if let rect = rect, rect.width > 1 || rect.height > 1 { return false }
        return true
    }
}