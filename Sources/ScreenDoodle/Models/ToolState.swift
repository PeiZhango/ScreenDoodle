import AppKit

/// 共享的绘图状态：当前工具、颜色、笔宽。各屏画布共用同一实例，保证工具选择一致。
final class ToolState {
    /// 当前选择的工具；nil 表示未选中任何工具
    var currentTool: DrawingTool? = .pen
    /// 当前画笔颜色
    var currentColor: NSColor = NSColor(calibratedRed: 1.0, green: 0.20, blue: 0.20, alpha: 1.0)
    /// 当前笔宽
    var lineWidth: CGFloat = 4.0

    /// 撤销/重做回调（由各屏画布独立实现，这里仅作为事件触发点，供工具条获取状态）
    var onStateChanged: (() -> Void)?
}