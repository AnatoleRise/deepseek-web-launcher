// make_icon_v2.swift - 合成应用图标：纯黑渐变底 + dsh 官方白色鲸鱼（项目内 favicon.svg 改色）
// 用法：swift make_icon_v2.swift 白鲸透明PNG 输出1024PNG

import AppKit

let args = CommandLine.arguments
let whalePath = args[1]
let outPath = args[2]

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 纯黑微渐变底（上浅下深，圆角由系统自动裁切）
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let gradient = NSGradient(colors: [
    NSColor(calibratedWhite: 0.12, alpha: 1),
    NSColor(calibratedWhite: 0.02, alpha: 1)
])
gradient?.draw(in: rect, angle: -90)

// 白鲸居中叠加，占画布 66%（图标四周留出呼吸边距）
// 直接矢量加载 SVG（AppKit 原生支持），绕开 qlmanage 的渲染问题
if let whale = NSImage(contentsOfFile: whalePath), whale.isValid {
    let side = size * 0.66
    let whaleRect = NSRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
    whale.draw(in: whaleRect)
} else {
    FileHandle.standardError.write("读取鲸鱼图形失败：\(whalePath)\n".data(using: .utf8)!)
    exit(1)
}

image.unlockFocus()

let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
print("图标已合成：\(outPath)")
