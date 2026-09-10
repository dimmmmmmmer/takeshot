import AppKit

/// **A footer glyph with its disclosure mark baked into one image.**
///
/// Three controls in the footer open something — the codec menu, the naming
/// menu and the volume popover — and each drew its own mark: the menus took
/// AppKit's own indicator, pointing DOWN, while the volume drew a chevron
/// pointing UP because its popover rises. Side by side that reads as three
/// different kinds of control (owner: "стрелочка вверх у звука отличается от
/// стрелочек вниз у соседних иконок; давай у всех стрелочки вверх сделаем и
/// пусть они будут одинаковые").
///
/// **The obvious fix does not draw.** Hiding the system indicator and giving
/// the `Menu` an `HStack` of glyph-plus-chevron as its label renders the FIRST
/// element and nothing else under `.menuStyle(.borderlessButton)` — measured as
/// ink: one shape where there should be two. Nothing throws; the mark is simply
/// absent.
///
/// So the two are composed into ONE image, the way `MirroredSymbol` flips one:
/// a label that is a single image is a label that style cannot take apart, and
/// the whole control stays clickable — which matters here, because a menu whose
/// mark is a non-hit-testing overlay is the "sometimes it opens" complaint this
/// row has already had once.
enum FooterMarkedSymbol {
    /// The chevron every one of them wears, and the gap before it.
    static let mark = "chevron.up"
    static let markSize: CGFloat = 8
    static let gap: CGFloat = 3

    /// `name` at `size`, with the mark beside it.
    @MainActor
    static func image(_ name: String, size: CGFloat) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: size,
                                                        weight: .regular)
        let markConfiguration = NSImage.SymbolConfiguration(
            pointSize: markSize, weight: .semibold)
        guard let glyph = NSImage(systemSymbolName: name,
                                  accessibilityDescription: name)?
            .withSymbolConfiguration(configuration),
            let chevron = NSImage(systemSymbolName: mark,
                                  accessibilityDescription: nil)?
            .withSymbolConfiguration(markConfiguration) else {
            return NSImage(size: CGSize(width: size, height: size))
        }
        let width = glyph.size.width + gap + chevron.size.width
        let height = max(glyph.size.height, chevron.size.height)
        let composed = NSImage(size: CGSize(width: width, height: height))
        composed.lockFocus()
        glyph.draw(at: CGPoint(x: 0, y: (height - glyph.size.height) / 2),
                   from: .zero, operation: .sourceOver, fraction: 1)
        chevron.draw(
            at: CGPoint(x: glyph.size.width + gap,
                        y: (height - chevron.size.height) / 2),
            from: .zero, operation: .sourceOver, fraction: 1)
        composed.unlockFocus()
        // Template, so it takes the control's own tint the way a plain symbol
        // does — including the half-opacity a locked codec picker draws at.
        composed.isTemplate = true
        return composed
    }
}
