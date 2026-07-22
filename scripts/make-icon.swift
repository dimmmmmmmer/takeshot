// Generate the app icon: a dark Blackmagic-style tile, a clapperboard with a
// slightly open striped bar and a red REC light.
// Run: swift scripts/make-icon.swift <output-folder.iconset>
import AppKit
import CoreGraphics

let space = CGColorSpaceCreateDeviceRGB()

func drawIcon(into ctx: CGContext, size: CGFloat) {
    let s = size / 1024.0
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)

    // --- background: dark rounded tile ---
    let margin: CGFloat = 100
    let rect = CGRect(x: margin, y: margin, width: 1024 - margin * 2, height: 1024 - margin * 2)
    let bg = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.addPath(bg)
    ctx.clip()
    let bgColors = [
        CGColor(red: 0.165, green: 0.173, blue: 0.184, alpha: 1),
        CGColor(red: 0.071, green: 0.075, blue: 0.082, alpha: 1),
    ] as CFArray
    if let g = CGGradient(colorsSpace: space, colors: bgColors, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924),
                               end: CGPoint(x: 512, y: 100), options: [])
    }
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.07))
    ctx.setLineWidth(4)
    ctx.addPath(bg)
    ctx.strokePath()

    // --- clapperboard body ---
    let bodyRect = CGRect(x: 232, y: 300, width: 560, height: 310)
    let body = CGPath(roundedRect: bodyRect, cornerWidth: 36, cornerHeight: 36, transform: nil)
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let bodyColors = [
        CGColor(red: 0.24, green: 0.25, blue: 0.27, alpha: 1),
        CGColor(red: 0.15, green: 0.155, blue: 0.17, alpha: 1),
    ] as CFArray
    if let g = CGGradient(colorsSpace: space, colors: bodyColors, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 610),
                               end: CGPoint(x: 512, y: 300), options: [])
    }
    // ruled "field" lines on the body
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    for y in [520, 448, 376] {
        ctx.fill(CGRect(x: 282, y: CGFloat(y), width: 320, height: 22))
    }
    // red REC light
    let dotCenter = CGPoint(x: 700, y: 531)
    let dot = [
        CGColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1),
        CGColor(red: 0.80, green: 0.10, blue: 0.07, alpha: 1),
    ] as CFArray
    if let g = CGGradient(colorsSpace: space, colors: dot, locations: [0, 1]) {
        ctx.saveGState()
        ctx.addArc(center: dotCenter, radius: 34, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.clip()
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: 692, y: 540), startRadius: 0,
                               endCenter: dotCenter, endRadius: 38,
                               options: [.drawsBeforeStartLocation])
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // --- top bar: slightly open, diagonal stripes ---
    ctx.saveGState()
    ctx.translateBy(x: 232, y: 622)
    ctx.rotate(by: 7 * .pi / 180)
    let barRect = CGRect(x: 0, y: 0, width: 560, height: 108)
    let bar = CGPath(roundedRect: barRect, cornerWidth: 24, cornerHeight: 24, transform: nil)
    ctx.addPath(bar)
    ctx.clip()
    ctx.setFillColor(CGColor(red: 0.16, green: 0.165, blue: 0.18, alpha: 1))
    ctx.fill(barRect)
    ctx.setFillColor(CGColor(red: 0.80, green: 0.81, blue: 0.83, alpha: 1))
    var x: CGFloat = -80
    while x < 640 {
        ctx.move(to: CGPoint(x: x, y: 0))
        ctx.addLine(to: CGPoint(x: x + 70, y: 0))
        ctx.addLine(to: CGPoint(x: x + 70 + 54, y: 108))
        ctx.addLine(to: CGPoint(x: x + 54, y: 108))
        ctx.closePath()
        ctx.fillPath()
        x += 140
    }
    ctx.restoreGState()

    ctx.restoreGState()
}

func writePNG(size: Int, scale: Int, name: String, dir: URL) {
    let pixels = size * scale
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("no context") }
    drawIcon(into: ctx, size: CGFloat(pixels))
    guard let image = ctx.makeImage() else { fatalError("no image") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
    do {
        try data.write(to: dir.appendingPathComponent(name))
    } catch {
        fatalError("write failed: \(error)")
    }
}

let args = CommandLine.arguments
guard args.count == 2 else {
    print("usage: swift make-icon.swift <out.iconset>")
    exit(1)
}
let dir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    writePNG(size: size, scale: 1, name: "icon_\(size)x\(size).png", dir: dir)
    writePNG(size: size, scale: 2, name: "icon_\(size)x\(size)@2x.png", dir: dir)
}
print("iconset written to \(dir.path)")
