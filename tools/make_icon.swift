// Generates the app icon: the Cygnus constellation (Northern Cross)
// as a node graph — white stars and thin edges on near-black, Deneb
// in HAL red. Run: swift tools/make_icon.swift
// Writes App/Assets.xcassets/AppIcon.appiconset/icon_<px>.png

import AppKit
import CoreGraphics

// Normalized star positions (x right, y up), approximating Cygnus.
let stars: [(x: CGFloat, y: CGFloat, r: CGFloat, red: Bool)] = [
    (0.50, 0.84, 0.040, true),   // Deneb — HAL red
    (0.50, 0.56, 0.030, false),  // Sadr
    (0.70, 0.43, 0.026, false),  // Gienah
    (0.86, 0.31, 0.018, false),  // zeta
    (0.30, 0.45, 0.026, false),  // delta
    (0.15, 0.58, 0.018, false),  // iota
    (0.47, 0.36, 0.016, false),  // eta
    (0.42, 0.13, 0.024, false),  // Albireo
]
let edges = [(0, 1), (1, 2), (2, 3), (1, 4), (4, 5), (1, 6), (6, 7)]

func draw(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon shape: rounded rect with margin.
    let margin = s * 0.09
    let rect = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225,
                      cornerHeight: rect.width * 0.225, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(CGColor(red: 0.055, green: 0.055, blue: 0.07, alpha: 1))
    ctx.fillPath()
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(gray: 1.0, alpha: 0.10))
    ctx.setLineWidth(max(s * 0.004, 1))
    ctx.strokePath()

    ctx.addPath(path)
    ctx.clip()

    func point(_ i: Int) -> CGPoint {
        CGPoint(x: rect.minX + stars[i].x * rect.width,
                y: rect.minY + stars[i].y * rect.height)
    }

    // Edges.
    ctx.setStrokeColor(CGColor(gray: 1.0, alpha: 0.42))
    ctx.setLineWidth(max(s * 0.008, 0.75))
    ctx.setLineCap(.round)
    for (a, b) in edges {
        ctx.move(to: point(a))
        ctx.addLine(to: point(b))
    }
    ctx.strokePath()

    // Stars with a soft glow.
    for (i, star) in stars.enumerated() {
        let p = point(i)
        let radius = star.r * rect.width
        let color = star.red
            ? CGColor(red: 0.90, green: 0.13, blue: 0.10, alpha: 1)
            : CGColor(gray: 0.97, alpha: 1)
        ctx.setFillColor(color.copy(alpha: 0.22)!)
        ctx.fillEllipse(in: CGRect(x: p.x - radius * 2.1, y: p.y - radius * 2.1,
                                   width: radius * 4.2, height: radius * 4.2))
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius,
                                   width: radius * 2, height: radius * 2))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = "App/Assets.xcassets/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = draw(size: size)
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(size).png"))
    print("icon_\(size).png")
}

let contents = """
{
  "images" : [
    { "filename" : "icon_16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try contents.write(toFile: "\(outDir)/Contents.json", atomically: true, encoding: .utf8)
print("Contents.json")
