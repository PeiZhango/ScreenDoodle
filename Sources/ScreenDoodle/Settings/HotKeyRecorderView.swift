import AppKit
import Carbon

/// 快捷键录制视图：点击后等待用户按下组合键并显示。
final class HotKeyRecorderView: NSView {

    private let titleLabel: NSTextField
    private let recordButton: NSButton
    private(set) var hotKey: HotKey

    private var isRecording = false
    private var localMonitor: Any?

    /// 当前正在录制的视图；同一时刻只允许一个录制器安装键盘监视器，避免串改其它快捷键。
    private static weak var activeRecorder: HotKeyRecorderView?

    init(title: String, hotKey: HotKey, labelWidth: CGFloat = 80) {
        self.hotKey = hotKey
        titleLabel = NSTextField(labelWithString: title)
        recordButton = NSButton(title: hotKey.displayString, target: nil, action: nil)
        recordButton.bezelStyle = .rounded
        super.init(frame: .zero)

        titleLabel.alignment = .right
        titleLabel.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        recordButton.widthAnchor.constraint(equalToConstant: 180).isActive = true
        recordButton.target = self
        recordButton.action = #selector(startRecording)

        let stack = NSStackView(views: [titleLabel, recordButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func startRecording() {
        // 先取消其它正在录制的视图，保证同一时刻只有一个键盘监视器，防止串改其它快捷键
        HotKeyRecorderView.activeRecorder?.stopRecording()
        HotKeyRecorderView.activeRecorder = self
        isRecording = true
        recordButton.title = "请按下组合键…"

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            self.handleKeyDown(event)
            return nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }

        let keyCode = UInt32(event.keyCode)

        // 按 Esc 取消本次录制（无修饰键时）
        if event.keyCode == UInt16(kVK_Escape) && modifiers == 0 {
            stopRecording()
            recordButton.title = hotKey.displayString
            return
        }

        // 要求至少一个修饰键 + 有效按键，否则继续等待
        guard modifiers != 0, keyCode != 0 else { return }

        stopRecording()
        hotKey = HotKey(keyCode: keyCode, modifiers: modifiers)
        recordButton.title = hotKey.displayString
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if HotKeyRecorderView.activeRecorder === self {
            HotKeyRecorderView.activeRecorder = nil
        }
    }

    deinit {
        stopRecording()
    }
}