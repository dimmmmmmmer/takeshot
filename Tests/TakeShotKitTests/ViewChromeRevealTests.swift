import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// When a fullscreen window's chrome is showing.
///
/// Three strips hide until the pointer visits an edge — the badge row at the
/// top of both fullscreen windows, the live window's footer, the playback
/// window's transport — and each used to spell the rule out for itself, in two
/// different shapes: the top one against a bare number, the two bottom ones
/// against a band measured off the view's own height. Nothing showed they were
/// the same rule, and the comment on `BottomHoverReveal` already said what that
/// costs: the band is how far the operator has to move the mouse before the
/// controls appear, and two different answers on two windows reads as one of
/// them being broken.
///
/// All three live behind `onContinuousHover`, which a headless test cannot
/// drive; the rule under it is ordinary code.
struct ViewChromeRevealTests {
    private let height: CGFloat = 1000

    private func shows(_ y: CGFloat, edge: VerticalEdge, band: CGFloat) -> Bool {
        ChromeReveal.shows(.active(CGPoint(x: 500, y: y)), edge: edge,
                           band: band, in: height)
    }

    /// The top band is measured from the top of the surface and the bottom band
    /// from its bottom, which is the whole of the rule.
    @Test func eachBandIsMeasuredFromItsOwnEdge() {
        #expect(shows(10, edge: .top, band: 140))
        #expect(!shows(200, edge: .top, band: 140))
        #expect(shows(height - 10, edge: .bottom, band: 140))
        #expect(!shows(height - 200, edge: .bottom, band: 140))
    }

    /// The far edge is never the near one. A sign error would put the transport
    /// on screen whenever the pointer went near the timecode.
    @Test func onePointerPositionCannotRevealBothStrips() {
        for y in stride(from: 0.0, through: height, by: 50) {
            let both = shows(y, edge: .top, band: ChromeReveal.topBand)
                && shows(y, edge: .bottom, band: ChromeReveal.footerBand)
            #expect(!both, "y=\(y) revealed the badges and the footer at once")
        }
    }

    /// The pointer leaving the window takes the chrome with it, on both edges.
    /// A strip left up because the pointer went out of the top of the frame is
    /// a strip that never goes away again — and this window is the one whose
    /// whole job is to show nothing but the picture.
    @Test func thePointerLeavingHidesEveryStrip() {
        for edge in [VerticalEdge.top, .bottom] {
            #expect(!ChromeReveal.shows(.ended, edge: edge, band: 400,
                                        in: height),
                    "\(edge) kept its chrome after the pointer left")
        }
    }

    /// The three bands are comparable at a glance now, and this is the claim
    /// that goes with putting them side by side: they differ, because each is
    /// sized to the strip it brings back, but they differ by TWENTY POINTS —
    /// near enough that no window feels different to reach into. That is the
    /// question `BottomHoverReveal` was asking when it said two answers on two
    /// windows read as one of them being broken, and it is the part a later
    /// edit could break without anybody noticing.
    @Test func theThreeBandsAgreeCloselyEnoughToFeelLikeOneApp() {
        let bands = [ChromeReveal.topBand, ChromeReveal.footerBand,
                     ChromeReveal.transportBand]
        let spread = (bands.max() ?? 0) - (bands.min() ?? 0)
        #expect(spread <= 20, "the reveal bands are \(bands), \(spread) apart")
        // and none of them covers a sensible window: a band deeper than half a
        // laptop's picture is a strip that is always up
        for band in bands {
            #expect(band > 0 && band < 360,
                    "a \(band)pt band is most of a laptop's height")
        }
    }

    /// Exactly on the band's edge the strip is not up yet. Stated because the
    /// two bottom strips used a strict comparison and the top one used a
    /// different strict comparison in the other direction, and the answer at
    /// the boundary was never the same twice.
    @Test func theBoundaryItselfBelongsToThePicture() {
        #expect(!shows(140, edge: .top, band: 140))
        #expect(shows(139.9, edge: .top, band: 140))
        #expect(!shows(height - 140, edge: .bottom, band: 140))
        #expect(shows(height - 139.9, edge: .bottom, band: 140))
    }
}
