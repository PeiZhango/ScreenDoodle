import AppKit
import Carbon

/// 设置窗口：自定义快捷键（涂鸦、截图）、导出目录、导出格式、开机自启。
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private var toggleRecorder: HotKeyRecorderView!
    private var captureRecorder: HotKeyRecorderView!
    private var directoryLabel: NSTextField!
    private var formatPopup: NSPopUpButton!

    /// 统一的左侧标签宽度，保证所有设置项对齐
    private let labelWidth: CGFloat = 90

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "屏幕涂鸦设置"
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        guard let window = window else { return }
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = content

        // 主垂直 stack：分组组织，统一间距
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])

        // —— 快捷键分组 ——
        stack.addArrangedSubview(makeSectionTitle("快捷键"))
        let keys = Settings.shared.hotKeys
        toggleRecorder = makeRecorderRow(title: "涂鸦", hotKey: keys.toggle)
        captureRecorder = makeRecorderRow(title: "截图", hotKey: keys.capture)
        stack.addArrangedSubview(toggleRecorder)
        stack.addArrangedSubview(captureRecorder)

        // 分组间隔
        stack.addArrangedSubview(makeSpacer(height: 8))
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeSpacer(height: 4))

        // —— 导出生效分组 ——
        stack.addArrangedSubview(makeSectionTitle("导出"))

        // 导出目录（只读路径显示 + 浏览按钮）
        let dirRow = NSStackView()
        dirRow.orientation = .horizontal
        dirRow.spacing = 10
        dirRow.alignment = .centerY
        let dirLabel = makeFieldLabel("导出目录:")
        directoryLabel = NSTextField(labelWithString: Settings.shared.exportDirectory)
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.textColor = .secondaryLabelColor
        directoryLabel.toolTip = Settings.shared.exportDirectory
        directoryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        directoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let browse = NSButton(title: "浏览…", target: self, action: #selector(browseDirectory))
        browse.bezelStyle = .rounded
        dirRow.addArrangedSubview(dirLabel)
        dirRow.addArrangedSubview(directoryLabel)
        dirRow.addArrangedSubview(browse)
        stack.addArrangedSubview(dirRow)

        // 导出格式
        let fmtRow = NSStackView()
        fmtRow.orientation = .horizontal
        fmtRow.spacing = 10
        fmtRow.alignment = .centerY
        let fmtLabel = makeFieldLabel("导出格式:")
        formatPopup = NSPopUpButton()
        formatPopup.addItems(withTitles: ["PNG（无损）", "JPG（小体积）"])
        formatPopup.selectItem(at: Settings.shared.exportFormat == "jpg" ? 1 : 0)
        fmtRow.addArrangedSubview(fmtLabel)
        fmtRow.addArrangedSubview(formatPopup)
        stack.addArrangedSubview(fmtRow)

        stack.addArrangedSubview(makeSpacer(height: 8))
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeSpacer(height: 4))

        // —— 其他分组 ——
        stack.addArrangedSubview(makeSectionTitle("其他"))
        let launchBtn = NSButton(checkboxWithTitle: "开机自动启动", target: self, action: #selector(toggleLaunch))
        launchBtn.state = Settings.shared.launchAtLogin ? .on : .off
        stack.addArrangedSubview(launchBtn)

        // 保存按钮固定在窗口右下角，与内容保持恒定间距（不使用弹簧推挤）
        let save = NSButton(title: "保存设置", target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded
        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.alignment = .centerY
        btnRow.addArrangedSubview(NSView()) // 左侧弹簧
        btnRow.addArrangedSubview(save)
        btnRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(btnRow)
        NSLayoutConstraint.activate([
            btnRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            btnRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            btnRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
    }

    // MARK: - 辅助构造

    /// 分组标题：加粗、稍大字号
    private func makeSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 13)
        label.textColor = .labelColor
        return label
    }

    /// 统一的左侧字段标签
    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        return label
    }

    private func makeRecorderRow(title: String, hotKey: HotKey) -> HotKeyRecorderView {
        let view = HotKeyRecorderView(title: title, hotKey: hotKey, labelWidth: labelWidth)
        return view
    }

    private func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 452).isActive = true
        return box
    }

    private func makeSpacer(height: CGFloat) -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    // MARK: - 动作

    @objc private func browseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        // 中文化面板文案
        panel.title = "选择导出目录"
        panel.prompt = "选择"
        // 以当前路径为起点
        if let currentURL = URL(string: "file://" + directoryLabel.stringValue) {
            panel.directoryURL = currentURL
        }
        if panel.runModal() == .OK, let url = panel.url {
            directoryLabel.stringValue = url.path
            directoryLabel.toolTip = url.path
        }
    }

    @objc private func toggleLaunch(_ sender: NSButton) {
        do {
            try Settings.shared.setLaunchAtLogin(sender.state == .on)
        } catch {
            // 注册/注销失败：回滚到真实状态并提示，避免复选框与系统实际不一致
            sender.state = Settings.shared.launchAtLogin ? .on : .off
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "开机自启设置失败"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    @objc private func saveSettings() {
        Settings.shared.hotKeys = (
            toggleRecorder.hotKey,
            captureRecorder.hotKey
        )
        Settings.shared.exportDirectory = directoryLabel.stringValue
        Settings.shared.exportFormat = formatPopup.indexOfSelectedItem == 1 ? "jpg" : "png"

        // 通知菜单栏重新应用快捷键
        (NSApp.delegate as? AppDelegate)?.applyHotKeys()

        window?.close()
    }

    // MARK: - 窗口关闭

    /// 设置窗口关闭时恢复全局快捷键
    func windowWillClose(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.applyHotKeys()
    }
}

extension AppDelegate {
    /// 供设置窗口保存后重新应用快捷键
    func applyHotKeys() {
        hotKeyManager.apply(Settings.shared.hotKeys)
    }
}