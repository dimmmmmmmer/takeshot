import SwiftUI

/// When a fullscreen window's chrome is showing.
///
/// A fullscreen surface hides everything but the picture and brings a strip
/// back when the pointer visits an edge. There are three of those strips — the
/// top badges over both windows, the live window's footer, the playback
/// window's transport — and each spelled the rule out for itself. Worse, they
/// spelled it in two different SHAPES: the top one compared the pointer against
/// a bare number while the two bottom ones measured a band off the view's own
/// height, so nothing showed that they were the same rule at all.
///
/// The comment on `BottomHoverReveal` already said why that matters: the band
/// is "how far up the operator has to move the mouse before the controls
/// appear, and two different answers on two windows reads as one of them being
/// broken". Stated once, the three bands are three arguments and comparable at
/// a glance.
enum ChromeReveal {
    /// How near the top edge the pointer has to come for the badge row.
    static let topBand: CGFloat = 140
    /// The live window's footer.
    static let footerBand: CGFloat = 150
    /// The playback window's transport.
    static let transportBand: CGFloat = 130

    // The three differ, and they differ by twenty points — which is the answer
    // to the question `BottomHoverReveal` was asking: near enough that no
    // window feels different to reach into, and each one sized to the strip it
    // brings back. `ViewChromeRevealTests` holds them to that spread, which is
    // the part a later edit could break without anybody noticing.

    /// Whether a strip on `edge` should be showing.
    ///
    /// `height` is the surface the pointer is being reported in; the top edge
    /// does not use it, which is exactly why the two rules did not look alike
    /// before.
    static func shows(pointerY: CGFloat, edge: VerticalEdge, band: CGFloat,
                      in height: CGFloat) -> Bool {
        switch edge {
        case .top: return pointerY < band
        case .bottom: return pointerY > height - band
        }
    }

    /// The same rule over a whole hover phase. The pointer LEAVING the window
    /// takes the chrome with it, on both edges: a strip left on screen because
    /// the pointer went out of the top of the frame is a strip that never goes
    /// away again.
    static func shows(_ phase: HoverPhase, edge: VerticalEdge, band: CGFloat,
                      in height: CGFloat) -> Bool {
        switch phase {
        case .active(let point):
            return shows(pointerY: point.y, edge: edge, band: band, in: height)
        case .ended:
            return false
        @unknown default:
            return false
        }
    }
}
