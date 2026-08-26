// ascii_art.swift - 把图片转为 ASCII 字符画，直接肉眼验证图案形状
// 用法：swift ascii_art.swift 图片.png

import AppKit

let path = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: path) else {
    print("读取失败")
    exit(1)
}

// 缩小到 80x40 网格再采样（保持宽高比：图标是正方形，40 行 80 列）
let cols = 80, rows = 40
let thumb = NSImage(size: NSSize(width: cols, height: rows))
thumb.lockFocus()
image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(cols), height: CGFloat(rows)),
           from: .zero, operation: .sourceOver, fraction: 1)
thumb.unlockFocus()

guard let tiff = thumb.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
    print("转换失败")
    exit(1)
}

// 逐行打印（NSBitmapImageRep 原点在左下，打印时倒序输出为屏幕直观的上→下）
for y in stride(from: rows - 1, through: 0, by: -1) {
    var line = ""
    for x in 0..<cols {
        if let c = rep.colorAt(x: x, y: y) {
            let brightness = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
            // 考虑 alpha：透明区域按黑处理（背景是黑的）
            let effective = brightness * c.alphaComponent
            line += effective > 0.5 ? "#" : (effective > 0.2 ? "+" : ".")
        }
    }
    print(line)
}
