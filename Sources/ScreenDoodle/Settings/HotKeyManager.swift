import Foundation
import Carbon

/// 全局快捷键管理器：使用 Carbon RegisterEventHotKey 注册系统级热键。
final class HotKeyManager {

    /// 已注册热键的回调闭包
    var onToggle: (() -> Void)?
    var onCapture: (() -> Void)?
    /// 紧急恢复回调：一键强制收起所有遮罩并归还激活权
    var onRecover: (() -> Void)?

    /// 已注册的热键引用（用于注销）
    private var toggleRef: EventHotKeyRef?
    private var captureRef: EventHotKeyRef?
    private var recoverRef: EventHotKeyRef?

    /// 事件处理器引用
    private var handlerRef: EventHandlerRef?

    /// 每个动作最近一次触发的时刻（systemUptime），用于去抖
    private var lastFireTimes: [Action: TimeInterval] = [:]
    /// 去抖间隔：按住快捷键会自动重复上报、快速连按也会产生多次事件，间隔内只唤起一次
    private let fireCooldown: TimeInterval = 0.3

    /// 固定的紧急恢复热键：⌘ + Option + Shift + E。
    /// 刻意不放进用户自定义设置——失控时用户可能已改乱自定义快捷键，
    /// 保留一个固定不变的「救命键」保证任何时候都能键盘自救。
    private static let recoverHotKey = HotKey(
        keyCode: UInt32(kVK_ANSI_E),
        modifiers: UInt32(cmdKey | optionKey | shiftKey)
    )

    /// 应用当前快捷键配置
    func apply(_ keys: (toggle: HotKey, capture: HotKey)) {
        unregisterAll()
        register(keys.toggle, ref: &toggleRef, action: .toggle)
        register(keys.capture, ref: &captureRef, action: .capture)
        register(Self.recoverHotKey, ref: &recoverRef, action: .recover)
    }

    // MARK: - 注册 / 注销

    private func register(_ hotKey: HotKey, ref: inout EventHotKeyRef?, action: Action) {
        // 先建立事件处理器（只需建立一次）
        if handlerRef == nil {
            installHandler()
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x53445257), id: UInt32(action.rawValue))
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status != noErr {
            NSLog("[ScreenDoodle] 快捷键注册失败: \(status) (\(action))")
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // 以 unmanaged self 作为 userData，回调里取回
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let userData = userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handle(event)
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    private func handle(_ event: EventRef?) -> OSStatus {
        guard let event = event else { return noErr }
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard let action = Action(rawValue: Int(hotKeyID.id)) else { return noErr }
        // 去抖：忽略去抖间隔内的重复触发（按键自动重复或快速连按）
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastFireTimes[action], now - last < fireCooldown {
            return noErr
        }
        lastFireTimes[action] = now
        DispatchQueue.main.async {
            switch action {
            case .toggle: self.onToggle?()
            case .capture: self.onCapture?()
            case .recover: self.onRecover?()
            }
        }
        return noErr
    }

    func unregisterAll() {
        if let toggleRef { UnregisterEventHotKey(toggleRef); self.toggleRef = nil }
        if let captureRef { UnregisterEventHotKey(captureRef); self.captureRef = nil }
        if let recoverRef { UnregisterEventHotKey(recoverRef); self.recoverRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }

    deinit {
        unregisterAll()
    }

    private enum Action: Int {
        case toggle = 1
        case capture = 2
        case recover = 3
    }
}