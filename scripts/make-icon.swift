// Генерация иконки приложения в стиле Blackmagic: тёмная плашка,
// металлическое кольцо-объектив с рисками, красная точка REC с свечением.
// Запуск: swift scripts/make-icon.swift <выходная-папка.iconset>
import AppKit
import CoreGraphics

func drawIcon(into ctx: CGContext, size: CGFloat) {
    let s = size / 1024.0
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)

    // --- фон: тёмная скруглённая плашка ---
    let margin: CGFloat = 100
    let rect = CGRect(x: margin, y: margin, width: 1024 - margin * 2, height: 1024 - margin * 2)
    let bg = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.addPath(bg)
    ctx.clip()
    let bgColors = [
        CGColor(red: 0.165, green: 0.173, blue: 0.184, alpha: 1), // верх — чуть светлее
        CGColor(red: 0.071, green: 0.075, blue: 0.082, alpha: 1), // низ — почти чёрный
    ] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(colorsSpace: space, colors: bgColors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 512, y: 1024 - margin),
                               end: CGPoint(x: 512, y: margin),
                               options: [])
    }
    // тонкая светлая кромка сверху
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.07))
    ctx.setLineWidth(4)
    ctx.addPath(bg)
    ctx.strokePath()

    let center = CGPoint(x: 512, y: 512)

    // --- риски вокруг кольца (шкала объектива / таймкода) ---
    ctx.setLineCap(.round)
    for i in 0..<24 {
        let angle = CGFloat(i) / 24 * 2 * .pi + .pi / 2
        let isMajor = i % 2 == 0
        let r0: CGFloat = 352
        let r1: CGFloat = isMajor ? 384 : 372
        ctx.setStrokeColor(CGColor(red: 0.36, green: 0.375, blue: 0.40,
                                   alpha: isMajor ? 0.9 : 0.5))
        ctx.setLineWidth(isMajor ? 9 : 6)
        ctx.move(to: CGPoint(x: center.x + cos(angle) * r0, y: center.y + sin(angle) * r0))
        ctx.addLine(to: CGPoint(x: center.x + cos(angle) * r1, y: center.y + sin(angle) * r1))
        ctx.strokePath()
    }

    // --- металлическое кольцо ---
    let ringPath = CGMutablePath()
    ringPath.addArc(center: center, radius: 322, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.saveGState()
    ctx.addPath(ringPath.copy(strokingWithWidth: 66, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
    ctx.clip()
    let ringColors = [
        CGColor(red: 0.52, green: 0.54, blue: 0.57, alpha: 1),
        CGColor(red: 0.26, green: 0.27, blue: 0.30, alpha: 1),
        CGColor(red: 0.42, green: 0.44, blue: 0.47, alpha: 1),
        CGColor(red: 0.20, green: 0.21, blue: 0.235, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: space, colors: ringColors,
                                 locations: [0, 0.4, 0.7, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 512 - 322, y: 512 + 322),
                               end: CGPoint(x: 512 + 322, y: 512 - 322),
                               options: [])
    }
    ctx.restoreGState()

    // внутренняя тёмная линза
    ctx.setFillColor(CGColor(red: 0.043, green: 0.047, blue: 0.055, alpha: 1))
    ctx.addArc(center: center, radius: 289, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.fillPath()

    // --- свечение вокруг REC-точки ---
    let glowColors = [
        CGColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 0.72),
        CGColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 0.0),
    ] as CFArray
    if let glow = CGGradient(colorsSpace: space, colors: glowColors, locations: [0, 1]) {
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 40,
                               endCenter: center, endRadius: 275, options: [])
    }

    // --- красная точка REC ---
    let dotColors = [
        CGColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1),
        CGColor(red: 0.86, green: 0.13, blue: 0.09, alpha: 1),
        CGColor(red: 0.62, green: 0.06, blue: 0.04, alpha: 1),
    ] as CFArray
    if let dot = CGGradient(colorsSpace: space, colors: dotColors, locations: [0, 0.7, 1]) {
        ctx.saveGState()
        ctx.addArc(center: center, radius: 150, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.clip()
        ctx.drawRadialGradient(dot,
                               startCenter: CGPoint(x: 512 - 40, y: 512 + 50), startRadius: 0,
                               endCenter: center, endRadius: 160,
                               options: [.drawsBeforeStartLocation])
        ctx.restoreGState()
    }

    // блик на точке
    let specColors = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.5),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray
    if let spec = CGGradient(colorsSpace: space, colors: specColors, locations: [0, 1]) {
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: 512 - 95, y: 512 + 10, width: 130, height: 95))
        ctx.clip()
        ctx.drawRadialGradient(spec,
                               startCenter: CGPoint(x: 512 - 35, y: 512 + 62), startRadius: 0,
                               endCenter: CGPoint(x: 512 - 35, y: 512 + 62), endRadius: 90,
                               options: [])
        ctx.restoreGState()
    }

    ctx.restoreGState()
}

func writePNG(size: Int, scale: Int, name: String, dir: URL) {
    let pixels = size * scale
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("no context") }
    drawIcon(into: ctx, size: CGFloat(pixels))
    guard let image = ctx.makeImage() else { fatalError("no image") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
    try! data.write(to: dir.appendingPathComponent(name))
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
