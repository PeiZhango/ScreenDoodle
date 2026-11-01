import AppKit

/// 导出管理器：负责图片格式转换与剪贴板复制。
enum ExportManager {

    /// 将 NSImage 复制到系统剪贴板
    static func copyToPasteboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // 同时写入 PNG 与 TIFF，保证在图片编辑/聊天/文档等各类应用中粘贴都能识别
        if let png = image.data(ext: "png") {
            pasteboard.setData(png, forType: .png)
        }
        pasteboard.writeObjects([image])
    }
}

extension NSImage {
    /// 将图片转换为指定格式的二进制数据
    /// - Parameter ext: "png" 或 "jpg"
    func data(ext: String) -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        if ext == "jpg" {
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}