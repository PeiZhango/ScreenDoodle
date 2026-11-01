import Foundation
import Carbon
import ServiceManagement

/// 自定义快捷键模型：由修饰键组合 + 大写字母按键码构成。
struct HotKey: Codable, Equatable {
    /// Carbon 按键码（kVK_ANSI_*）
    var keyCode: UInt32
    /// 修饰键标志位（cmdKey / optionKey / controlKey / shiftKey）
    var modifiers: UInt32

    /// 默认：Command + Shift + D（涂鸦）
    static let defaultToggle = HotKey(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | shiftKey))
    /// 默认：Command + Shift + A（截图）
    static let defaultCapture = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey))

    /// 用于显示的可读字符串
    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    /// 按键码转可读字符
    static func keyName(for keyCode: UInt32) -> String {
        // 字母与数字键码均不连续，统一从映射表取显示字符
        if let name = Self.keyNameMap[keyCode] {
            return name
        }
        switch keyCode {
        case UInt32(kVK_Return): return "↩"
        case UInt32(kVK_Tab): return "⇥"
        case UInt32(kVK_Space): return "空格"
        case UInt32(kVK_Delete): return "⌫"
        case UInt32(kVK_Escape): return "⎋"
        case UInt32(kVK_UpArrow): return "↑"
        case UInt32(kVK_DownArrow): return "↓"
        case UInt32(kVK_LeftArrow): return "←"
        case UInt32(kVK_RightArrow): return "→"
        default: return "键\(keyCode)"
        }
    }

    /// 键码到显示字符的完整映射：字母 A–Z 与数字 0–9 的键码均不连续，需逐键对应
    private static let keyNameMap: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
    ]
}

/// 应用设置：持久化到 UserDefaults。
final class Settings {
    static let shared = Settings()

    private enum Keys {
        static let hotKeys = "hotKeys"
        static let exportDirectory = "exportDirectory"
        static let exportFormat = "exportFormat"
    }

    private let defaults = UserDefaults.standard

    /// 两个全局快捷键：涂鸦（唤出/收起）与截图
    var hotKeys: (toggle: HotKey, capture: HotKey) {
        get {
            guard
                let data = defaults.data(forKey: Keys.hotKeys),
                let decoded = try? JSONDecoder().decode([HotKey].self, from: data),
                decoded.count == 2
            else {
                return (.defaultToggle, .defaultCapture)
            }
            return (decoded[0], decoded[1])
        }
        set {
            let array = [newValue.toggle, newValue.capture]
            if let data = try? JSONEncoder().encode(array) {
                defaults.set(data, forKey: Keys.hotKeys)
            }
        }
    }

    /// 截图导出目录，默认 ~/Pictures/涂鸦截图/
    var exportDirectory: String {
        get {
            defaults.string(forKey: Keys.exportDirectory)
                ?? (NSHomeDirectory() as NSString).appendingPathComponent("Pictures/涂鸦截图")
        }
        set { defaults.set(newValue, forKey: Keys.exportDirectory) }
    }

    /// 导出格式：png 或 jpg
    var exportFormat: String {
        get { defaults.string(forKey: Keys.exportFormat) ?? "png" }
        set { defaults.set(newValue, forKey: Keys.exportFormat) }
    }

    /// 开机自启：以系统登录项注册状态为准（无需 UserDefaults 另存）
    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 设置开机自启。注册/注销失败（未签名、缺 bundle 等）时抛出错误供 UI 提示。
    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}