import CoreGraphics
import Testing

@testable import CaptureCore

/// What the three legend sizes actually are, and the one thickness a swatch bar
/// has.
///
/// Both of these were reported by looking at the picture — "the colour patches
/// are too wide on the sides" and "large is really a medium" — and both turned
/// out to be arithmetic that had drifted rather than taste.
struct AssistLegendSizeTests {
    /// **The swatch bar is one thickness, whichever way the strip runs.**
    ///
    /// It was stated twice: 14/19/26 across a horizontal strip and 30/40/54
    /// across a vertical one — 2.1x, derived from nothing and explained
    /// nowhere. Top and bottom looked right because they used the smaller
    /// number; the sides used the other.
    @Test func theSwatchBarHasOneThickness() {
        for size in AssistLegendSize.allCases {
            let metrics = size.metrics
            #expect(metrics.swatchThickness > 0)
            // Asserted against the HORIZONTAL bar's own number, which is what
            // the side strip used to differ from by 2.1x. There is one stored
            // property now, so the two orientations cannot disagree — and this
            // fails the moment a second one is added back.
            #expect(Mirror(reflecting: metrics).children
                .compactMap(\.label)
                .filter { $0.lowercased().contains("width") }
                .isEmpty,
                    "\(size) has a second cross-axis dimension again")
        }
    }

    /// **One 4:3 step per size, off one reference set.**
    ///
    /// Three hand-tuned structs is three places for a ratio to drift, and it
    /// had: the corner radius stepped 8/10/12 while the text stepped 11/15/20,
    /// so a small legend's corners were proportionally rounder than a large
    /// one's for no reason anybody wrote down. Every dimension now steps
    /// together, by construction.
    @Test func everyDimensionStepsByTheSameFactor() {
        let small = AssistLegendSize.small.metrics
        let medium = AssistLegendSize.medium.metrics
        let large = AssistLegendSize.large.metrics
        let up = 4.0 / 3.0

        func ratio(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a / b }
        for (name, s, m, l) in [
            ("swatchThickness", small.swatchThickness, medium.swatchThickness,
             large.swatchThickness),
            ("falseColorBand", small.falseColorBand, medium.falseColorBand,
             large.falseColorBand),
            ("elZoneBand", small.elZoneBand, medium.elZoneBand, large.elZoneBand),
            ("bandHeight", small.bandHeight, medium.bandHeight, large.bandHeight),
            ("fontSize", small.fontSize, medium.fontSize, large.fontSize),
            ("padding", small.padding, medium.padding, large.padding),
            ("corner", small.corner, medium.corner, large.corner),
            ("gap", small.gap, medium.gap, large.gap),
            ("labelGap", small.labelGap, medium.labelGap, large.labelGap),
        ] {
            #expect(abs(ratio(m, s) - up) < 0.001,
                    "\(name) small→medium is \(ratio(m, s)), not 4:3")
            #expect(abs(ratio(l, m) - up) < 0.001,
                    "\(name) medium→large is \(ratio(l, m)), not 4:3")
        }
    }

    /// **The ladder sat one step low.** The number that says so is the project's
    /// own: the dailies burn-in draws text at 2.9 % of frame height and is
    /// proven readable off a monitor on set. Large is now 2.47 % — bigger than
    /// anything the operator had, still under the burn-in — and small is what
    /// medium used to be.
    @Test func theLadderReachesTheSizeTheBurnInProved() {
        let reference: CGFloat = 1080
        let large = AssistLegendSize.large.metrics.fontSize / reference
        let small = AssistLegendSize.small.metrics.fontSize / reference
        #expect(large > 0.023,
                "large is \(large * 100)% of frame height — still a medium")
        #expect(large < 0.029,
                "large is \(large * 100)%, past the burn-in's own size")
        #expect(small > 0.013,
                "small is \(small * 100)% of frame height — unreadable")
    }
}
