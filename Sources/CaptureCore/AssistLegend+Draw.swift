@preconcurrency import CoreImage
import CoreText
import Foundation

/// Rasterizing the legend and putting it on the frame. What the strip SAYS —
/// its bands, its sizes and which edge it lands against — is `AssistLegend`;
/// this file is how those become pixels.
///
/// The strip is drawn ONCE per (tool, size, orientation, pixel size) and kept:
/// this runs on the display queue on every frame, and rasterizing thirteen
/// bands and thirteen `CTLine`s per frame would be a GPU pass' worth of CPU
/// work for a picture that has not changed.
extension AssistLegend {
    /// The legend for `tool` over `image`, whose extent is the frame. The
    /// original image when there is nothing to draw or no room for it.
    ///
    /// Composited last, after the guides: the legend is the key to the picture
    /// and must not be dimmed by a frameline matte drawn over it.
    func drawn(over image: CIImage, tool: ViewAssist.ColorTool) -> CIImage {
        let extent = image.extent
        guard tool != .off, extent.width > 1, extent.height > 1,
              let layout = layout(for: tool, in: extent.size),
              let strip = strip(tool: tool, layout: layout) else { return image }
        return strip
            .transformed(by: CGAffineTransform(
                translationX: extent.minX + layout.rect.minX,
                y: extent.minY + layout.rect.minY))
            .composited(over: image)
            .cropped(to: extent)
    }

    // MARK: - the cache

    /// What makes two strips the same picture. The placement is in it only
    /// through `vertical`: a left strip and a right one are the same bitmap put
    /// in two places.
    private struct RasterKey: Hashable {
        var tool: String
        var size: String
        var vertical: Bool
        var width: Int
        var height: Int
        var labels: Bool
    }

    /// Capped like the zebra cube cache next door: a signal that changes format
    /// and two producers at two resolutions must not pin one bitmap each for
    /// the rest of the session.
    nonisolated(unsafe) private static var rasters: [RasterKey: CIImage] = [:]
    nonisolated(unsafe) private static var rasterOrder: [RasterKey] = []
    private static let rasterLock = NSLock()
    private static let rasterLimit = 4

    private func strip(tool: ViewAssist.ColorTool, layout: Layout) -> CIImage? {
        let key = RasterKey(tool: tool.rawValue, size: size.rawValue,
                            vertical: placement.isVertical,
                            width: Int(layout.rect.width),
                            height: Int(layout.rect.height),
                            labels: layout.showsLabels)
        Self.rasterLock.lock()
        defer { Self.rasterLock.unlock() }
        if let cached = Self.rasters[key] {
            Self.rasterOrder.removeAll { $0 == key }
            Self.rasterOrder.append(key)
            return cached
        }
        guard let image = rasterized(tool: tool, layout: layout) else {
            return nil
        }
        Self.rasters[key] = image
        Self.rasterOrder.append(key)
        while Self.rasterOrder.count > Self.rasterLimit {
            Self.rasters.removeValue(forKey: Self.rasterOrder.removeFirst())
        }
        return image
    }

    // MARK: - the bitmap

    /// The strip as an unmanaged RGBA bitmap.
    ///
    /// Wrapped with `colorSpace: nil`, exactly like the frame it is composited
    /// over: every stage of the display path works on raw code values, and a
    /// managed legend would be converted into the working space and back out
    /// again — the swatches would no longer be the colours the picture is
    /// painted with, which is the one thing a key has to be.
    private func rasterized(tool: ViewAssist.ColorTool,
                            layout: Layout) -> CIImage? {
        let width = Int(layout.rect.width)
        let height = Int(layout.rect.height)
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        let panel = CGSize(width: CGFloat(width), height: CGFloat(height))
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: CGColorSpace(name: CGColorSpace.sRGB)
                          ?? CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            let canvas = LegendCanvas(
                context: context, panel: panel,
                metrics: size.metrics.scaled(by: layout.scale),
                labels: layout.showsLabels)
            canvas.fillPanel()
            let entries = Self.entries(for: tool, transfer: transfer)
            if placement.isVertical {
                canvas.drawColumn(entries)
            } else {
                canvas.drawRow(entries, elZone: tool == .elZone)
            }
            return true
        }
        guard drawn else { return nil }
        return CIImage(bitmapData: data, bytesPerRow: bytesPerRow, size: panel,
                       format: .RGBA8, colorSpace: nil)
    }
}

/// The drawing state behind one legend bitmap: the context, the metrics in real
/// pixels, and the label font. Its own type for the reason
/// `OffloadReportCanvas` is one — the alternative is passing six arguments to
/// every draw call, and a strip of swatches should read as what is on it.
///
/// CoreText rather than AppKit, like the report card and the dailies burn-in
/// before it: CaptureCore has no AppKit dependency and is not going to grow one
/// for a strip of swatches.
private struct LegendCanvas {
    /// Dark enough to hold the swatches over a blown-out sky, transparent
    /// enough that the picture behind it is still readable.
    static let panelColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.65)
    static let labelColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.75)

    let context: CGContext
    let panel: CGSize
    let metrics: AssistLegendMetrics
    /// Labels are drawn only when they are big enough to be read; the swatches
    /// keep going below that (see `AssistLegend.minimumLabelSize`).
    let labels: Bool

    /// Fixed pitch: the labels are a column of stop numbers, and a
    /// proportional "+1" beside a "-6" is a column that wobbles.
    private var font: CTFont {
        CTFontCreateUIFontForLanguage(.userFixedPitch, metrics.fontSize, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, metrics.fontSize, nil)
    }

    func fillPanel() {
        let radius = min(metrics.corner, panel.height / 2)
        context.setFillColor(Self.panelColor)
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: panel),
                               cornerWidth: radius, cornerHeight: radius,
                               transform: nil))
        context.fillPath()
    }

    /// The bands across the strip, labels underneath, darkest on the LEFT — the
    /// direction the exposure scale reads.
    func drawRow(_ entries: [AssistLegend.Entry], elZone: Bool) {
        let band = elZone ? metrics.elZoneBand : metrics.falseColorBand
        let top = panel.height - metrics.verticalPadding - metrics.swatchThickness
        for (index, entry) in entries.enumerated() {
            let x = metrics.padding + CGFloat(index) * (band + metrics.gap)
            context.setFillColor(Self.color(of: entry))
            context.fill(CGRect(x: x, y: top, width: band,
                                height: metrics.swatchThickness))
            draw(entry.label,
                 in: CGRect(x: x, y: metrics.verticalPadding, width: band,
                            height: metrics.labelHeight), centered: true)
        }
    }

    /// The same bands stacked, labels alongside, DARKEST AT THE BOTTOM — the
    /// strip runs the way a light meter does, and the same way the horizontal
    /// one runs darkest-at-the-left.
    func drawColumn(_ entries: [AssistLegend.Entry]) {
        let labelX = metrics.padding + metrics.bandWidth + metrics.labelGap
        for (index, entry) in entries.enumerated() {
            let y = metrics.verticalPadding
                + CGFloat(index) * (metrics.bandHeight + metrics.gap)
            context.setFillColor(Self.color(of: entry))
            context.fill(CGRect(x: metrics.padding, y: y,
                                width: metrics.bandWidth,
                                height: metrics.bandHeight))
            draw(entry.label,
                 in: CGRect(x: labelX, y: y, width: metrics.labelWidth,
                            height: metrics.bandHeight), centered: false)
        }
    }

    /// One label inside `box`, vertically centered on it. A gray-ramp band
    /// carries no label at all, and neither does a strip too small to read.
    private func draw(_ text: String, in box: CGRect, centered: Bool) {
        guard labels, !text.isEmpty else { return }
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key:
                    Self.labelColor,
            ]))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent,
                                                       nil))
        context.textPosition = CGPoint(
            x: centered ? box.midX - width / 2 : box.minX,
            y: box.midY - (ascent - descent) / 2)
        CTLineDraw(line, context)
    }

    private static func color(of entry: AssistLegend.Entry) -> CGColor {
        CGColor(srgbRed: CGFloat(entry.color.red),
                green: CGFloat(entry.color.green),
                blue: CGFloat(entry.color.blue), alpha: 1)
    }
}

extension AssistLegendMetrics {
    /// The whole set in real pixels. Nothing is rounded on the way: the panel's
    /// own size already is, and rounding each band as well would leave a seam
    /// where the last one lands.
    func scaled(by scale: CGFloat) -> AssistLegendMetrics {
        AssistLegendMetrics(
            swatchThickness: swatchThickness * scale,
            falseColorBand: falseColorBand * scale,
            elZoneBand: elZoneBand * scale,
            bandHeight: bandHeight * scale, bandWidth: bandWidth * scale,
            fontSize: fontSize * scale, padding: padding * scale,
            verticalPadding: verticalPadding * scale, corner: corner * scale,
            gap: gap * scale, labelGap: labelGap * scale)
    }
}
