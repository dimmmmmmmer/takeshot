import CoreGraphics
@preconcurrency import CoreImage
import CoreText
import Foundation

/// **The identity as pixels: one small unmanaged bitmap per distinct thing
/// there is to say, kept in a content-keyed cache.**
///
/// Text rendering per frame is the obvious trap in this whole change. A grid
/// composes on the main camera's clock, so at UHD it runs 25 times a second on
/// a machine that is recording, and laying out four names and four running
/// timecodes on every one of those passes would be real work added to a real
/// budget. `DailiesOverlay` already solved the same problem the same way and is
/// the precedent followed here: rasterize the strips that do not change ONCE
/// and blit them; build a line per frame only for the text that actually moves.
///
/// **The cache is keyed on everything drawn, so there is no invalidation step
/// at all.** A key that carries the words, the lamp, the type size and the
/// width the plate must fit in cannot produce a stale hit: a rename, a REC
/// press, a camera count that resizes the cells or a canvas that changes raster
/// all produce a key that was never in the table, and the old entry ages out of
/// the LRU on its own. That is deliberately not a `didSet` that clears a cache
/// — the thing this app keeps relearning is that a second answer to "has it
/// changed" is a second thing to get wrong, and a content key has no second
/// answer to give.
///
/// What that buys, per kind of thing drawn:
///
/// - a **nameplate** is a hit for the whole shift. Its key moves when the
///   operator renames a camera or a board starts or stops writing, which is a
///   handful of times a shift, so the 25-a-second restatement the wiring makes
///   costs a dictionary lookup and nothing else.
/// - a **clock** is a hit exactly when the timecode is not moving — which is
///   not a marginal case, it is the one `MultiviewComposer.Pacing.everyFrame`
///   exists for. A PAUSED comparison composes once per tile per step with every
///   tile's timecode frozen, so the case that composes most redundantly is the
///   case where the clock costs nothing. A rolling clock misses once per tick
///   per tile and pays for one short fixed-pitch line.
///
/// **The LRU bound matters more than it looks.** A rolling clock inserts a new
/// key per tile per frame forever, so an unbounded table is a leak measured in
/// hours. The limit is set above twice the largest tile count so that the
/// nameplates — touched on every compose and therefore always freshest — are
/// never the entries evicted by the clocks churning past them.
///
/// **What it measures**, in release on the development Mac, minimum of twenty
/// runs, two runs agreeing within 0.1 ms (`MultiviewIdentityTests`,
/// `TAKESHOT_BENCH=1`). `anonymous` is the pass exactly as it was before any of
/// this; `settled` is names and lamps up with the clocks frozen — every badge a
/// cache hit, so it is the composite alone; `rolling` is a clock changing on
/// every single compose, which is the worst case there is.
///
/// | canvas | tiles | anonymous | settled | rolling |
/// | --- | --- | --- | --- | --- |
/// | 1080p | 1 | 0.011 ms | 0.646 | 0.784 |
/// | 1080p | 2 | 0.614 | 0.882 | 0.972 |
/// | 1080p | 4 | 0.781 | 1.162 | 1.241 |
/// | UHD | 1 | 0.012 | 1.183 | 1.612 |
/// | UHD | 2 | 1.416 | 1.731 | 2.259 |
/// | UHD | 4 | 2.130 | 2.512 | 2.492 |
///
/// Three things to read out of that. **The cache does its job**: eight fresh
/// CoreText lines a frame (four names and four clocks at UHD) would be the
/// whole of the `settled` column again, and instead a settled four-up costs
/// 0.38 ms more than an anonymous one — that is the extra CoreImage layers, not
/// the type. **The clock's own share is small and shrinking**: 0.09 ms at two
/// tiles and inside the noise at four, where the compose dominates. And all of
/// it sits against the 6.0 ms (1080p) and 21.2 ms (UHD) the H.264 encode of the
/// very same frame costs, on a queue that is not the frame path.
///
/// **The one real bill is the single camera**, and it is not this file's doing:
/// an anonymous single camera is handed back uncomposed at 0.012 ms, and one
/// with a name has to be rendered like any other picture — 1.18 ms at UHD. That
/// is the price of the label on the commonest rig there is, and it is written
/// up where the decision is made, at `MultiviewComposer.compose`.
///
/// **CoreText, and the fonts built under the cache's own lock.** AppKit text
/// drawing is not thread-safe and this runs on the composer's queue; worse, two
/// composers can exist at once (the live grid and a comparison's), on two
/// queues. `MockCaptureBackend` records what that costs — reaching CoreText's
/// font machinery first, concurrently, from background threads returned a nil
/// font and `CTLineCreateWithAttributedString` raised
/// "attempt to insert nil object from objects[0]", killing the process on the
/// shipping `--demo` path. Every font here is created inside `rasterized`,
/// which only ever runs with `cacheLock` held, so the first touch is
/// serialized by construction rather than by luck.
enum TileBadge {
    /// What makes two badges the same picture. Everything drawn is in it —
    /// see the note above on why that is the whole invalidation story.
    private struct Key: Hashable {
        var text: String
        var lamp: Bool
        var fixedPitch: Bool
        /// Rounded to whole points: the type size is a fraction of the tile, so
        /// a canvas one pixel different would otherwise be a whole new bitmap.
        var pointSize: Int
        var maximumWidth: Int
    }

    nonisolated(unsafe) private static var cache: [Key: CIImage] = [:]
    nonisolated(unsafe) private static var order: [Key] = []
    private static let cacheLock = NSLock()
    /// Above twice the largest grid this app lays out, so the nameplates are
    /// never what a churning clock evicts. See the note above.
    private static let cacheLimit = 24

    nonisolated(unsafe) private static var drawn = 0

    /// **How many bitmaps have actually been drawn.**
    ///
    /// The caching rule is a claim about cost, and a claim about cost that
    /// nothing checks is a comment. `MultiviewIdentityCostTests` asks for the
    /// same badge over and over and asserts on this counter — that a still
    /// nameplate is drawn once however many frames go by, and that a moving
    /// clock is drawn once per distinct value and not once per compose. It
    /// counts misses, so it only ever rises.
    ///
    /// Read under the same lock the increment holds. Two composers can be
    /// rasterizing at once (the live grid's and a comparison's), so an unlocked
    /// read of a counter they both move is a race even though it would almost
    /// always answer correctly — and "almost always" is what makes that class
    /// of bug expensive to find later.
    static var rasterCount: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return drawn
    }

    /// Drop everything. For the suite alone: the cache is static, so one test's
    /// warm entries would otherwise be another test's `rasterCount` of zero.
    static func resetForTesting() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeAll()
        order.removeAll()
        drawn = 0
    }

    // MARK: - the two things a tile says

    /// The name, with the REC lamp in front of it when the tile is a camera
    /// that is writing.
    static func nameplate(for identity: TileIdentity,
                          metrics: TileTypeMetrics,
                          maximumWidth: CGFloat) -> CIImage? {
        guard !identity.label.isEmpty else { return nil }
        return badge(text: identity.label, lamp: identity.showsRecordingLamp,
                     fixedPitch: false, metrics: metrics,
                     maximumWidth: maximumWidth)
    }

    /// The running timecode. Fixed-pitch, like `DailiesStripMetrics.timecodeFont`
    /// and for the same reason — proportional digits make a running clock
    /// shimmer, and here they would also change the plate's width on every
    /// tick, which is a new cache key for every frame on top of it.
    static func clock(text: String, metrics: TileTypeMetrics,
                      maximumWidth: CGFloat) -> CIImage? {
        guard !text.isEmpty else { return nil }
        return badge(text: text, lamp: false, fixedPitch: true,
                     metrics: metrics, maximumWidth: maximumWidth)
    }

    // MARK: - the cache

    private static func badge(text: String, lamp: Bool, fixedPitch: Bool,
                              metrics: TileTypeMetrics,
                              maximumWidth: CGFloat) -> CIImage? {
        guard metrics.pointSize >= 1, maximumWidth >= 1 else { return nil }
        let key = Key(text: text, lamp: lamp, fixedPitch: fixedPitch,
                      pointSize: Int(metrics.pointSize.rounded()),
                      maximumWidth: Int(maximumWidth.rounded(.down)))
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return hit
        }
        guard let image = rasterized(text: text, lamp: lamp,
                                     fixedPitch: fixedPitch, metrics: metrics,
                                     maximumWidth: maximumWidth) else {
            return nil
        }
        drawn += 1
        cache[key] = image
        order.append(key)
        while order.count > cacheLimit {
            cache.removeValue(forKey: order.removeFirst())
        }
        return image
    }

    // MARK: - the bitmap

    /// Dark enough to hold white type over a blown-out window, transparent
    /// enough to leave the picture readable behind it — the same plate
    /// `DailiesStripMetrics` settled on, and the same alpha the `/cameras`
    /// page's tag uses.
    private static let plateColor =
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55)
    private static let textColor =
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    /// `#e0323c`, which is the `--rec` the `/cameras` page already paints its
    /// dot with, so the two surfaces light the same red.
    private static let lampColor =
        CGColor(srgbRed: 0.878, green: 0.196, blue: 0.235, alpha: 1)

    /// One badge as an unmanaged RGBA bitmap.
    ///
    /// **Unmanaged on purpose, exactly like `AssistLegend`'s strip.** Every
    /// stage of this display path works on raw code values — the composer reads
    /// its tiles with `colorSpace: NSNull()` and renders with a nil destination
    /// space — because these buffers hold 709-encoded codes and a managed
    /// render would shift a picture the operator is judging exposure on. A
    /// colour-managed badge would be converted into the working space and back,
    /// and the lamp would stop being the red the page paints.
    ///
    /// **A dot, and no word.** The `/cameras` page draws a pulsing dot AND the
    /// word "REC"; this draws the dot alone, for three reasons that all point
    /// the same way. The word is a UI string, so it would be localized, so the
    /// picture on a director's monitor would change language with the
    /// operator's Settings — and it would have to be re-rasterized when it did.
    /// At this type size the word also costs three or four characters of the
    /// width the camera's NAME needs, on the tile where names are shortest. And
    /// a red tally dot is what the same information already looks like on every
    /// other monitoring surface in the building. The dot does not pulse either:
    /// an animation is a new bitmap per frame for a fact that is not changing.
    private static func rasterized(text: String, lamp: Bool, fixedPitch: Bool,
                                   metrics: TileTypeMetrics,
                                   maximumWidth: CGFloat) -> CIImage? {
        let font = self.font(pointSize: metrics.pointSize,
                             fixedPitch: fixedPitch)
        let lampWidth = lamp ? metrics.lampDiameter + metrics.textInset : 0
        let room = maximumWidth - 2 * metrics.textInset - lampWidth
        guard room >= 1 else { return nil }
        let shown = truncated(text, font: font, to: room)
        let line = self.line(shown, font: font)
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let width = Int(min(maximumWidth,
                            (textWidth + lampWidth + 2 * metrics.textInset)
                                .rounded(.up)))
        let height = Int(metrics.plateHeight.rounded())
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: CGColorSpace(name: CGColorSpace.sRGB)
                          ?? CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.setFillColor(plateColor)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width),
                                height: CGFloat(height)))
            var textX = metrics.textInset
            if lamp {
                let diameter = metrics.lampDiameter
                context.setFillColor(lampColor)
                context.fillEllipse(in: CGRect(
                    x: textX, y: (CGFloat(height) - diameter) / 2,
                    width: diameter, height: diameter))
                textX += diameter + metrics.textInset
            }
            // Sat on its own metrics rather than on the plate's: centring the
            // typographic box puts a line with no descenders visibly high.
            let ascent = CTFontGetAscent(font)
            let descent = CTFontGetDescent(font)
            context.textPosition = CGPoint(
                x: textX,
                y: (CGFloat(height) - (ascent + descent)) / 2 + descent)
            CTLineDraw(line, context)
            return true
        }
        guard drawn else { return nil }
        return CIImage(bitmapData: data, bytesPerRow: bytesPerRow,
                       size: CGSize(width: width, height: height),
                       format: .RGBA8, colorSpace: nil)
    }

    private static func line(_ text: String, font: CTFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key:
                    textColor,
            ]))
    }

    /// The emphasized system face for a name, fixed pitch for a clock — the
    /// same two choices `DailiesStripMetrics` makes, with the same fallbacks
    /// for a system that answers nil.
    private static func font(pointSize: CGFloat, fixedPitch: Bool) -> CTFont {
        if fixedPitch {
            return CTFontCreateUIFontForLanguage(.userFixedPitch, pointSize, nil)
                ?? CTFontCreateWithName("Menlo" as CFString, pointSize, nil)
        }
        return CTFontCreateUIFontForLanguage(.emphasizedSystem, pointSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, pointSize, nil)
    }

    /// `text` shortened from the END until it fits `room`, with an ellipsis.
    ///
    /// Tail rather than middle, because these are names read left to right and
    /// the front is what tells two of them apart — "A-CAM WIDE" and
    /// "A-CAM TIGHT" differ at the end, but so would any middle truncation of
    /// them, and the front is where the camera letter is. Only ever runs on a
    /// cache miss.
    private static func truncated(_ text: String, font: CTFont,
                                  to room: CGFloat) -> String {
        guard width(of: text, font: font) > room else { return text }
        var shown = text
        while !shown.isEmpty {
            shown = String(shown.dropLast())
            if width(of: shown + "\u{2026}", font: font) <= room {
                return shown + "\u{2026}"
            }
        }
        return ""
    }

    private static func width(of text: String, font: CTFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return CGFloat(CTLineGetTypographicBounds(
            line(text, font: font), nil, nil, nil))
    }
}
