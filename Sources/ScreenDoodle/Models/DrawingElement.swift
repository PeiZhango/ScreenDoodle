import AppKit

/// 屏幕上的一次涂鸦元素。覆盖所有工具类型，统一建模后便于绘制、序列化与撤销。
struct DrawingElement {

    /// 使用何种工具绘制
    var tool: DrawingTool
    /// 颜色（含透明度分量）
    var color: NSColor
    /// 笔宽
    var lineWidth: CGFloat
    /// 路径（画笔/高亮/橡皮/直线/箭头用）
    var path: NSBezierPath?
    /// 形状的起点 / 终点（矩形、椭圆、马赛克用）
    var rect: NSRect?
    /// 文字内容（文字工具用）
    var text: String?
    /// 文字锚点
    var textOrigin: CGPoint?
    /// 文字编辑框尺寸（提交后按原框排版，保持与编辑时位置一致）
    var textSize: NSSize?
    /// 箭头起点
    var arrowStart: CGPoint?
    /// 箭头终点（用于头部三角形定位）
    var arrowEnd: CGPoint?
}