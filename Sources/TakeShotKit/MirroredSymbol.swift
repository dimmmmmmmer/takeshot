import AppKit

/// **An SF Symbol flipped left-to-right, as an image.**
///
/// `.scaleEffect(x: -1, y: 1)` is the obvious way to mirror a glyph and it does
/// not survive every host. A segmented `Picker` takes the CONTENT of each row
/// and re-hosts it, and a geometry transform applied outside the image is lost
/// on the way — so the compare bar's two diagonal wipes both drew "/" (owner:
/// "значок другой диагональной шторки показан в ту же сторону что и первый").
/// A picker cannot report that; it simply shows the same glyph twice.
///
/// Flipping the PIXELS cannot be dropped by anything downstream. The result is
/// a template image, so it still takes the control's own tint the way the
/// symbol beside it does.
enum MirroredSymbol {
    /// `line.diagonal` the other way: "\" against the plain symbol's "/".
    ///
    /// **Main-actor**, because `NSImage` is not `Sendable` and a `static let`
    /// of one is shared mutable state as far as Swift 6 is concerned. Built
    /// once, on the actor its only reader — a SwiftUI body — already runs on.
    /// The development compiler let this through and the CI toolchain did not,
    /// which is the gap `docs/ARCHITECTURE.md` describes: the runner is a
    /// second COMPILER, not only an older SDK.
    @MainActor static let diagonal: NSImage = flipped("line.diagonal")

    /// The SAME symbol the other way up, drawn through the SAME pipeline.
    ///
    /// **The two diagonals were different sizes** (owner: "а че у нас иконки
    /// диагональных палок разных размеров"), and that is what a mixed pipeline
    /// costs: one row was `Image(systemName:)`, which SwiftUI scales to the
    /// control's own font, and the other was an `NSImage` at the symbol's
    /// natural size. Nothing was wrong with either — they were simply not the
    /// same picture of the same glyph. Both come from here now, at one stated
    /// size, so they can only ever match.
    @MainActor static let diagonalPlain: NSImage = rendered("line.diagonal",
                                                            mirrored: false)

    /// What both diagonal rows are drawn at. Small, because the picker they
    /// sit in is `.mini` and a glyph that overflows its row is the other half
    /// of the same complaint.
    static let pointSize: CGFloat = 11

    /// One symbol, mirrored horizontally.
    ///
    /// A symbol this build has no glyph for comes back as an empty image of a
    /// stated size rather than as nothing: a picker row with no content at all
    /// collapses, and a collapsed row is a wipe direction the operator cannot
    /// click. `theMirrorIsNotTheOriginal` is what says the flip really happened.
    static func flipped(_ name: String) -> NSImage {
        rendered(name, mirrored: true)
    }

    /// One symbol at `pointSize`, optionally mirrored.
    static func rendered(_ name: String, mirrored: Bool) -> NSImage {
        guard let symbol = NSImage(systemSymbolName: name,
                                   accessibilityDescription: name) else {
            return NSImage(size: CGSize(width: 14, height: 14))
        }
        let base = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize,
                                        weight: .regular)) ?? symbol
        guard mirrored else {
            base.isTemplate = true
            return base
        }
        let size = base.size
        let mirror = NSImage(size: size)
        mirror.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: size.width, yBy: 0)
        transform.scaleX(by: -1, yBy: 1)
        transform.concat()
        base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        mirror.unlockFocus()
        mirror.isTemplate = true
        return mirror
    }

    /// Where the ink sits across the width of a rendered symbol, as the mean
    /// column weighted by how much was drawn in it — 0 at the left edge, 1 at
    /// the right.
    ///
    /// The measurement the suite needs and the only one that can tell "/" from
    /// "\": the two have identical bounding boxes, identical ink area and
    /// identical everything else. What differs is which side the ink is on in
    /// the TOP half, so that is what this reads.
    static func topHalfInkCentre(_ image: NSImage) -> Double? {
        guard let rep = image.representations.first as? NSBitmapImageRep
                ?? bitmap(of: image) else { return nil }
        var weight = 0.0
        var moment = 0.0
        for y in 0..<(rep.pixelsHigh / 2) {
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                let ink = Double(colour.alphaComponent)
                weight += ink
                moment += ink * Double(x)
            }
        }
        guard weight > 0, rep.pixelsWide > 1 else { return nil }
        return moment / weight / Double(rep.pixelsWide - 1)
    }

    private static func bitmap(of image: NSImage) -> NSBitmapImageRep? {
        guard let data = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: data)
    }
}
