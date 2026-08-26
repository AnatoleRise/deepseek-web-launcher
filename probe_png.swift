// probe_png.swift - 采样 PNG 像素诊断渲染结果
// 用法：swift probe_png.swift 图片.png

import AppKit
import Foundation

let path = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: path),
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    print("读取失败")
    exit(1)
}

print("尺寸: \(rep.pixelsWide)x\(rep.pixelsHigh), 有alpha: \(rep.hasAlpha)")

// 采样若干关键点：中心、左上、右下、四分之一处
let points = [(512, 512), (300, 300), (700, 700), (100, 100), (900, 900), (512, 700)]
for (x, y) in points {
    if let c = rep.colorAt(x: x, y: y) {
        print("(\(x),\(y)) RGBA ≈ r:\(Int(round(c.redComponent*255))) g:\(Int(round(c.greenComponent*255))) b:\(Int(round(c.blueComponent*255))) a:\(String(format: "%.2f", c.alphaComponent))")
    }
}
