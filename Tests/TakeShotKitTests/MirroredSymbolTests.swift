import AppKit
import Testing

@testable import TakeShotKit

/// The compare bar's two diagonal wipes have to look like two directions.
///
/// They did not: the second was the first with `.scaleEffect(x: -1, y: 1)` on
/// it, and a segmented `Picker` drops that on the way to its own hosting, so
/// both rows drew "/". Nothing throws when that happens — the control simply
/// shows one glyph twice, which is why this is measured as INK rather than
/// asserted on the source.
@MainActor
struct MirroredSymbolTests {
    @Test func theMirrorIsNotTheOriginal() throws {
        // Both rows of the picker, through the one pipeline they both use now
        // — which is the other half of what the owner saw ("а че у нас иконки
        // диагональных палок разных размеров"): one row drawn by SwiftUI and
        // one by AppKit was the same glyph at two sizes.
        let plain = MirroredSymbol.diagonalPlain
        let mirror = MirroredSymbol.diagonal

        let plainCentre = try #require(MirroredSymbol.topHalfInkCentre(plain),
                                       "the plain symbol drew nothing")
        let mirrorCentre = try #require(MirroredSymbol.topHalfInkCentre(mirror),
                                        "the mirrored symbol drew nothing")
        // "/" carries its top ink on the RIGHT; "\" carries it on the left.
        // Held apart by a fifth of the width rather than by equality: the
        // rasterizer is not promised to be symmetric to the last subpixel.
        #expect(plainCentre - mirrorCentre > 0.2, """
            the two diagonals put their top ink at \(plainCentre) and \
            \(mirrorCentre) of the width — they are the same glyph
            """)
        #expect(mirror.isTemplate,
                "the mirrored glyph will not take the control's tint")
        #expect(mirror.size == plain.size, """
            the two diagonal rows are \(plain.size) and \(mirror.size) — one \
            picker, two sizes of one glyph
            """)
        #expect(plain.isTemplate,
                "the plain glyph will not take the control's tint")
        #expect(mirror.size.height <= MirroredSymbol.pointSize + 2, """
            the diagonals are drawn at \(mirror.size.height)pt in a mini \
            picker — a glyph that overflows its row is the same complaint
            """)
    }

    /// A symbol this build does not have comes back as an empty image with a
    /// size, not as nothing: a picker row with no content collapses, and a
    /// collapsed row is a wipe direction that cannot be clicked.
    @Test func anUnknownSymbolStillHasASize() {
        let missing = MirroredSymbol.flipped("no.such.symbol.exists.at.all")
        #expect(missing.size.width > 0 && missing.size.height > 0)
    }
}
