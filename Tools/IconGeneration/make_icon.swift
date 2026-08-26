// make_icon.swift - 生成 1024x1024 应用图标：深蓝渐变底 + 居中鲸鱼 emoji
// 用法：swift make_icon.swift 输出.png

import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 深蓝渐变铺满整个画布（圆角由系统自动裁切）
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.04, green: 0.18, blue: 0.42, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.38, blue: 0.72, alpha: 1)
])
gradient?.draw(in: rect, angle: -60)

// 居中绘制鲸鱼
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 580)]
let str = NSAttributedString(string: "🐋", attributes: attrs)
let strSize = str.size()
str.draw(at: NSPoint(x: (size - strSize.width) / 2, y: (size - strSize.height) / 2))

image.unlockFocus()

let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("图标已生成：\(CommandLine.arguments[1])")
