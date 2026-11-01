import AppKit

// 屏幕涂鸦：菜单栏常驻应用入口。
// 不依赖 storyboard/xib，纯代码构建，运行后常驻菜单栏（无 Dock 图标）。

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 隐藏 Dock 图标，仅菜单栏常驻
app.run()