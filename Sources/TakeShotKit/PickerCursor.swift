import AppKit
import SwiftUI

/// The eyedropper cursor, because AppKit has no such cursor and the crosshair
/// is a different promise.
///
/// `NSCursor` ships arrow, crosshair, I-beam, the hands and the resize family —
/// and nothing for "sample a colour". The chroma key's picker used the
/// crosshair, which on this app's own surfaces already means "draw a region"
/// (the visual-REC overlay draws one under exactly that cursor), so the same
/// pointer said two different things depending on which panel was open
/// (owner: "курсор хромакея на пипетке тоже становится крестиком, почему-то,
/// вместо пипетки").
///
/// Built from the SF Symbol the BUTTON already uses, so the pointer and the
/// control that armed it are the same picture. The hot spot is the tip of the
/// dropper — bottom-left of the glyph — because that is the pixel being
/// sampled, and a cursor whose hot spot is its centre samples a colour the
/// operator is not pointing at.
@MainActor
enum PickerCursor {
    /// Built once. `NSCursor` holds its image, and rasterizing a symbol on
    /// every hover is work in the middle of a gesture.
    static let eyedropper: NSCursor = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 18,
                                                        weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "eyedropper",
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            // A build whose SF Symbols lack it keeps the old pointer rather
            // than none: a missing cursor is an invisible mode.
            return .crosshair
        }
        // Drawn white with a dark rim: the picker floats over a PICTURE, and a
        // template symbol rendered in the system's label colour disappears
        // against half of them.
        let size = symbol.size
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.withAlphaComponent(0.8).set()
        symbol.draw(in: CGRect(origin: CGPoint(x: 0.5, y: -0.5), size: size),
                    from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        CGRect(origin: .zero, size: size).fill(using: .sourceAtop)
        image.unlockFocus()
        return NSCursor(image: image,
                        hotSpot: CGPoint(x: 1, y: size.height - 1))
    }()
}
