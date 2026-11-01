import AppKit

/// 绘图工具类型枚举。
enum DrawingTool: CaseIterable {
    case pen          // 画笔（自由绘制，不透明）
    case highlighter  // 高亮笔（半透明宽笔迹）
    case eraser       // 橡皮擦
    case line         // 直线
    case arrow        // 箭头
    case rectangle    // 矩形
    case ellipse      // 椭圆
    case text         // 文字标注
    case mosaic       // 马赛克（隐私遮挡）
    case colorPicker  // 取色器

    /// 菜单/工具条显示名
    var title: String {
        switch self {
        case .pen: return "画笔"
        case .highlighter: return "高亮笔"
        case .eraser: return "橡皮擦"
        case .line: return "直线"
        case .arrow: return "箭头"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        case .colorPicker: return "取色器"
        }
    }

    /// SF Symbol 图标名
    var symbolName: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .text: return "text.cursor"
        case .mosaic: return "square.grid.3x3"
        case .colorPicker: return "eyedropper"
        }
    }
}