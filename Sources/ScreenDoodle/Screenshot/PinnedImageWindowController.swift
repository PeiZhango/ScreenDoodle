import AppKit

/// 可拖动视图：点击其背景即可拖动所在的无边框窗口。
class PinnedDraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// 可拖动的图片视图：点击图片即可拖动窗口。
final class PinnedDraggableImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// 图片窗口顶部的工具条：与工具条一致的浅色渐变底，承载图钉与关闭按钮，同时可拖动。
final class PinnedTopBar: PinnedDraggableView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 与工具栏 ToolbarBackgroundView 保持一致的白色 → 浅蓝灰渐变
        NSGradient(
            starting: NSColor(calibratedWhite: 1.0, alpha: 0.98),
            ending: NSColor(calibratedRed: 0.88, green: 0.92, blue: 1.0, alpha: 0.98)
        )?.draw(in: bounds, angle: -90)
    }
}

/// 钉在桌面上的截图窗口：无边框、可拖动、带图钉（置顶）与关闭按钮。
final class PinnedImageWindowController: NSObject {

    /// 关闭回调（由外部移除持有引用）
    var onClose: (() -> Void)?

    /// 图钉生效（钉住）时图钉线条颜色：浅绿色
    private static let pinActiveColor = NSColor(calibratedRed: 0.36, green: 0.82, blue: 0.45, alpha: 1)

    private let image: NSImage
    private var window: NSWindow!
    private var pinButton: NSButton!
    /// 是否钉在最上层
    private var pinned = true

    init(image: NSImage) {
        self.image = image
        super.init()
    }

    // MARK: - 显示

    func show() {
        buildWindow()
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 构建窗口

    private func buildWindow() {
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        let maxW = visibleFrame.width * 0.7
        let maxH = visibleFrame.height * 0.7

        // 初始显示尺寸：按图片本身大小等比缩放，超大图限制在屏幕 70% 内
        var displaySize = image.size
        displaySize.width = max(displaySize.width, 40)
        displaySize.height = max(displaySize.height, 40)
        let scale = min(1, min(maxW / displaySize.width, maxH / displaySize.height))
        displaySize = NSSize(width: displaySize.width * scale, height: displaySize.height * scale)

        let topBarHeight: CGFloat = 26
        let contentSize = NSSize(width: displaySize.width, height: displaySize.height + topBarHeight)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.level = pinned ? .floating : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()

        let container = PinnedDraggableView(frame: NSRect(origin: .zero, size: contentSize))
        // 圆角 + 细描边：让钉住的截图呈现圆角卡片外观，替代原先的方形直角边框
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(calibratedWhite: 0.55, alpha: 0.8).cgColor
        window.contentView = container

        // 图片区域
        let imageView = PinnedDraggableImageView(
            frame: NSRect(x: 0, y: 0, width: displaySize.width, height: displaySize.height)
        )
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        // 图片区域右键菜单：复制到剪贴板 / 关闭图钉
        let contextMenu = NSMenu()
        let copyItem = NSMenuItem(title: "复制", action: #selector(copyPinnedImage), keyEquivalent: "")
        copyItem.target = self
        contextMenu.addItem(copyItem)
        let closeItem = NSMenuItem(title: "关闭", action: #selector(closeWindow), keyEquivalent: "")
        closeItem.target = self
        contextMenu.addItem(closeItem)
        imageView.menu = contextMenu
        container.addSubview(imageView)

        // 顶部工具条
        let topBar = PinnedTopBar(
            frame: NSRect(x: 0, y: displaySize.height, width: contentSize.width, height: topBarHeight)
        )
        container.addSubview(topBar)

        // 图钉按钮（置顶切换）
        pinButton = makeSymbolButton(
            symbol: "pin",
            tint: Self.pinActiveColor,
            action: #selector(togglePin(_:))
        )
        pinButton.frame = NSRect(x: 4, y: 1, width: topBarHeight - 2, height: topBarHeight - 2)
        topBar.addSubview(pinButton)

        // 关闭按钮
        let closeButton = makeSymbolButton(
            symbol: "xmark",
            tint: NSColor(calibratedWhite: 0.07, alpha: 1),
            action: #selector(closeWindow)
        )
        closeButton.frame = NSRect(
            x: contentSize.width - topBarHeight,
            y: 1,
            width: topBarHeight - 2,
            height: topBarHeight - 2
        )
        topBar.addSubview(closeButton)

        self.window = window
    }

    private func makeSymbolButton(symbol: String, tint: NSColor, action: Selector) -> NSButton {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.contentTintColor = tint
        button.target = self
        button.action = action
        return button
    }

    // MARK: - 动作

    /// 切换图钉：钉住时浮动在所有普通窗口之上，取消后回到普通层级
    @objc private func togglePin(_ sender: NSButton) {
        pinned.toggle()
        window.level = pinned ? .floating : .normal
        updatePinButton()
    }

    @objc private func closeWindow() {
        window.orderOut(nil)
        onClose?()
    }

    /// 将钉住的图片复制到系统剪贴板
    @objc private func copyPinnedImage() {
        ExportManager.copyToPasteboard(image)
    }

    private func updatePinButton() {
        // 两态均用空心图钉，仅以颜色区分：钉住（生效）为浅绿，未钉住为深灰
        pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        pinButton.contentTintColor = pinned ? Self.pinActiveColor : NSColor(calibratedWhite: 0.07, alpha: 1)
    }
}