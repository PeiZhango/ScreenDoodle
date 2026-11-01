import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 自研轻量取色器：隐藏系统光标，改用「小准星 + 紧凑圆形放大镜」跟随鼠标，
/// 单击即可取到屏幕颜色（Esc 或右键取消）。
/// 依赖屏幕录制权限，由调用方在 start 之前确认授权。
///
/// 状态均在主线程访问（截屏结果通过 `DispatchQueue.main.async` 回主线程写回），
/// 跨线程 `Task`/`async` 闭包仅捕获 `self` 做异步调度，故标记为 unchecked Sendable。
final class ColorPickerOverlay: NSObject, @unchecked Sendable {

    /// 取到颜色回调
    var onPicked: ((NSColor) -> Void)?
    /// 取消回调
    var onCancel: (() -> Void)?

    /// 放大镜圆盘半径（点）
    private let loupeRadius: CGFloat = 34
    /// 放大倍数
    private let zoom: CGFloat = 2

    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    /// 每块屏幕对应的取色窗口（层级高于涂鸦层与工具条）
    private var windows: [NSPanel] = []
    private var views: [PickerView] = []
    /// 每块屏幕最近一次截图缓存（displayID → CGImage）
    private var snapshots: [CGDirectDisplayID: CGImage] = [:]
    /// 启动时缓存一次 SCDisplay 映射，避免每次截图都慢速枚举系统窗口
    private var cachedDisplays: [CGDirectDisplayID: SCDisplay] = [:]
    /// 正在截图的屏幕集合，避免任务堆积导致画面滞后
    private var capturesInFlight: Set<CGDirectDisplayID> = []
    private var lastRefresh: TimeInterval = 0
    /// 全局鼠标位置（主屏原点坐标系）
    private var mouseScreenPoint: NSPoint = .zero
    private var isRunning = false

    // MARK: - 生命周期

    func start() {
        stop()

        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let window = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .statusBar + 3
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.acceptsMouseMovedEvents = true
            let view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.displayID = displayID
            view.zoom = zoom
            view.loupeRadius = loupeRadius
            window.contentView = view
            windows.append(window)
            views.append(view)
            window.orderFrontRegardless()
        }

        isRunning = true
        // 隐藏系统光标，改由视图绘制小准星 + 放大镜
        NSCursor.hide()
        mouseScreenPoint = NSEvent.mouseLocation
        updateCursorViews()
        installMonitors()
        // 预热 SCDisplay 缓存后立即截第一帧，保证进入取色即有画面
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                var map: [CGDirectDisplayID: SCDisplay] = [:]
                for display in content.displays {
                    map[display.displayID] = display
                }
                self.cachedDisplays = map
                self.refreshSnapshots()
            } catch {
                // 缓存失败则退回逐次查询
            }
        }
    }

    func stop() {
        removeMonitors()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        snapshots.removeAll()
        NSCursor.unhide()
        isRunning = false
    }

    // MARK: - 事件监听

    private func installMonitors() {
        removeMonitors()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self = self, self.isRunning else { return event }
            let p = NSEvent.mouseLocation
            self.mouseScreenPoint = p
            switch event.type {
            case .mouseMoved, .leftMouseDragged:
                self.updateCursorViews()
                self.throttledRefresh()
            case .leftMouseDown:
                self.pick(at: p)
                return nil
            case .rightMouseDown:
                self.finish(with: nil)
                return nil
            default:
                break
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isRunning else { return event }
            if event.keyCode == 53 { // Esc 取消取色
                self.finish(with: nil)
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - 截图采样

    private func throttledRefresh() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRefresh > 0.06 else { return }
        lastRefresh = now
        refreshSnapshots()
    }

    /// 为每块屏幕异步截一张最新画面，供放大镜显示与取色采样。
    /// 缓存 SCDisplay 映射、并发去重，尽量降低画面滞后。
    private func refreshSnapshots() {
        for view in views {
            guard let displayID = view.displayID, let screen = view.window?.screen else { continue }
            // 同一屏上一张还没截完就跳过，防止任务堆积越来越滞后
            guard !capturesInFlight.contains(displayID) else { continue }
            let scDisplay: SCDisplay
            if let cached = cachedDisplays[displayID] {
                scDisplay = cached
            } else {
                // 缓存未就绪（首次），本次放弃，等预热完成后的触发
                continue
            }
            capturesInFlight.insert(displayID)
            Task {
                do {
                    let config = SCStreamConfiguration()
                    config.width = Int(screen.frame.width * screen.backingScaleFactor)
                    config.height = Int(screen.frame.height * screen.backingScaleFactor)
                    config.showsCursor = false
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(display: scDisplay, excludingWindows: []),
                        configuration: config
                    )
                    DispatchQueue.main.async {
                        self.capturesInFlight.remove(displayID)
                        guard self.isRunning else { return }
                        self.snapshots[displayID] = image
                        view.snapshot = image
                        view.needsDisplay = true
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.capturesInFlight.remove(displayID)
                    }
                }
            }
        }
    }

    /// 把全局鼠标位置换算到各屏视图，触发重绘
    private func updateCursorViews() {
        for view in views {
            guard let screen = view.window?.screen else { continue }
            let local = NSPoint(
                x: mouseScreenPoint.x - screen.frame.minX,
                y: mouseScreenPoint.y - screen.frame.minY
            )
            view.mouseLocal = local
            if let displayID = view.displayID {
                view.snapshot = view.snapshot ?? snapshots[displayID]
            }
            view.needsDisplay = true
        }
    }

    /// 在全局屏幕坐标处取色
    private func pick(at screenPoint: NSPoint) {
        for view in views {
            guard let screen = view.window?.screen else { continue }
            let local = NSPoint(
                x: screenPoint.x - screen.frame.minX,
                y: screenPoint.y - screen.frame.minY
            )
            guard local.x >= 0, local.y >= 0,
                  local.x <= screen.frame.width, local.y <= screen.frame.height else { continue }

            guard let cg = view.snapshot ?? snapshots[view.displayID ?? 0] else {
                finish(with: nil)
                return
            }
            let scaleX = CGFloat(cg.width) / screen.frame.width
            let scaleY = CGFloat(cg.height) / screen.frame.height
            let px = Int(local.x * scaleX)
            // CGImage 原点在左上，而 local 为左下原点坐标，需翻转 y
            let py = cg.height - 1 - Int(local.y * scaleY)
            guard let color = pixelColor(from: cg, x: px, y: py) else {
                finish(with: nil)
                return
            }
            finish(with: color)
            return
        }
        finish(with: nil)
    }

    private func finish(with color: NSColor?) {
        guard isRunning else { return }
        stop()
        if let color = color {
            onPicked?(color)
        } else {
            onCancel?()
        }
    }
}

// MARK: - 取色绘制视图

/// 单块屏幕上的取色视图：画放大镜圆盘与准星
final class PickerView: NSView {

    var displayID: CGDirectDisplayID?
    var snapshot: CGImage?
    var mouseLocal: NSPoint = .zero
    var zoom: CGFloat = 2
    var loupeRadius: CGFloat = 50

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let cg = snapshot else { return }

        let cursorCenter = mouseLocal
        let scaleX = CGFloat(cg.width) / bounds.width
        let scaleY = CGFloat(cg.height) / bounds.height

        // 放大镜圆心：光标上方偏移，并夹取保持在屏幕内
        var center = NSPoint(x: cursorCenter.x, y: cursorCenter.y + loupeRadius + 16)
        center.x = min(max(center.x, loupeRadius + 3), bounds.width - loupeRadius - 3)
        center.y = min(max(center.y, loupeRadius + 3), bounds.height - loupeRadius - 3)

        // 源区域（像素）：以光标点为中心的正方形，边长 = 直径 / 放大倍数
        let srcSide = loupeRadius * 2 / zoom
        let srcRect = NSRect(
            x: cursorCenter.x * scaleX - srcSide * scaleX / 2,
            y: cursorCenter.y * scaleY - srcSide * scaleY / 2,
            width: srcSide * scaleX,
            height: srcSide * scaleY
        )
        let destRect = NSRect(
            x: center.x - loupeRadius,
            y: center.y - loupeRadius,
            width: loupeRadius * 2,
            height: loupeRadius * 2
        )

        // 圆盘内放大显示：先裁剪出光标附近的小区域再做像素级放大，
        // 避免整张 5K 截图参与插值缩放，保证鼠标移动时重绘轻快顺滑
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .none
        let circle = NSBezierPath(ovalIn: destRect)
        circle.addClip()
        NSColor.black.setFill()
        destRect.fill()

        // CGImage 原点在左上，需翻转 y 换算裁剪区域
        let cropX = max(0, Int(srcRect.minX))
        let cropY = max(0, cg.height - Int(srcRect.maxY))
        let cropW = min(Int(srcRect.width), cg.width - cropX)
        let cropH = min(Int(srcRect.height), cg.height - cropY)
        if cropW > 0, cropH > 0,
           let cropped = cg.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH)) {
            let small = NSImage(cgImage: cropped, size: NSSize(width: cropW, height: cropH))
            small.draw(in: destRect, from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()

        // 圆盘描边
        NSColor(calibratedWhite: 1, alpha: 0.9).setStroke()
        let border = NSBezierPath(ovalIn: destRect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 2
        border.stroke()

        // 准星光标：白色圆环 + 中心当前颜色实点
        NSColor(calibratedWhite: 1, alpha: 0.95).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(
            x: cursorCenter.x - 5.5, y: cursorCenter.y - 5.5, width: 11, height: 11
        ))
        ring.lineWidth = 2
        ring.stroke()

        let px = Int(cursorCenter.x * scaleX)
        let py = cg.height - 1 - Int(cursorCenter.y * scaleY)
        let pointColor = pixelColor(from: cg, x: px, y: py) ?? .black
        pointColor.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: cursorCenter.x - 2.5, y: cursorCenter.y - 2.5, width: 5, height: 5
        )).fill()
    }
}

/// 用 1x1 上下文直接从 CGImage 采样单个像素（只栅格化目标像素附近，避免整图解码开销）
private func pixelColor(from cg: CGImage, x px: Int, y py: Int) -> NSColor? {
    guard px >= 0, py >= 0, px < cg.width, py < cg.height else { return nil }
    var pixel = [UInt8](repeating: 0, count: 4)
    guard let ctx = CGContext(
        data: &pixel,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .none
    ctx.translateBy(x: 0, y: 1)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(
        cg,
        in: CGRect(x: CGFloat(-px), y: CGFloat(-py), width: CGFloat(cg.width), height: CGFloat(cg.height))
    )
    guard pixel[3] > 0 else { return nil }
    return NSColor(
        calibratedRed: CGFloat(pixel[0]) / 255,
        green: CGFloat(pixel[1]) / 255,
        blue: CGFloat(pixel[2]) / 255,
        alpha: CGFloat(pixel[3]) / 255
    )
}

// MARK: - 屏幕扩展

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}