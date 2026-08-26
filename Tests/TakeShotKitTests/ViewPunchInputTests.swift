import AppKit
import Testing

@testable import TakeShotKit

/// What a pinch or a scroll over the picture means.
///
/// This rule used to live inside `PunchEventView.handle`, behind a local
/// `NSEvent` monitor that a test cannot drive — a monitor wants a real
/// application event queue, and a synthesized event cannot carry a matching
/// window number. docs/coverage.md listed pulling it out as worth doing; this
/// is that, and the rule turns out to be worth pinning on its own account: it
/// decides whether a wheel zooms or pans, which on a rolling camera is the
/// difference between framing a shot and losing it.
@MainActor
struct ViewPunchInputTests {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let inside = CGPoint(x: 200, y: 150)

    private func decide(_ type: NSEvent.EventType,
                        magnification: CGFloat = 0,
                        modifiers: NSEvent.ModifierFlags = [],
                        delta: CGSize = .zero,
                        precise: Bool = true,
                        pointer: CGPoint? = nil,
                        bounds: CGRect? = nil,
                        punchedIn: Bool = false) -> PunchInput {
        PunchEventView.decide(
            PunchEvent(type: type, magnification: magnification,
                       modifiers: modifiers, scrollingDelta: delta,
                       precise: precise),
            pointer: pointer ?? inside, bounds: bounds ?? self.bounds,
            isPunchedIn: punchedIn)
    }

    /// The view declines every hit test, so the monitor sees events meant for
    /// whatever SwiftUI draws on top of it as well. The pointer being inside
    /// these bounds is the whole claim to an event.
    @Test func anEventOutsideThePictureIsNotOurs() {
        for point in [CGPoint(x: -1, y: 150), CGPoint(x: 401, y: 150),
                      CGPoint(x: 200, y: -1), CGPoint(x: 200, y: 301)] {
            #expect(decide(.magnify, magnification: 0.1, pointer: point)
                    == .ignore, "a pinch at \(point) was taken")
            #expect(decide(.scrollWheel, delta: CGSize(width: 0, height: 8),
                           pointer: point, punchedIn: true) == .ignore,
                    "a scroll at \(point) was taken")
        }
    }

    /// Before the first layout the view has no size, and a bounds-contains test
    /// on an empty rect is false for every point anyway — but stating it keeps
    /// a later "clamp the pointer into bounds" from quietly claiming events on
    /// a view that is not on screen.
    @Test func aViewWithNoSizeClaimsNothing() {
        #expect(decide(.magnify, magnification: 0.1, bounds: .zero) == .ignore)
    }

    /// A pinch over a picture means one thing, so it needs no modifier and no
    /// punched-in state: it zooms from wherever it starts.
    @Test func aPinchAlwaysZoomsByItsRelativeDelta() {
        #expect(decide(.magnify, magnification: 0.25) == .magnify(1.25))
        #expect(decide(.magnify, magnification: -0.1) == .magnify(0.9))
        // and it does not need to be punched in already
        #expect(decide(.magnify, magnification: 0.5, punchedIn: false)
                == .magnify(1.5))
    }

    /// ⌘-scroll is the macOS zoom idiom, and it has to work BEFORE the punch —
    /// it is one of the two ways in.
    @Test func commandScrollZoomsWhetherOrNotItIsPunchedIn() {
        let up = CGSize(width: 0, height: 20)
        let factor = PunchEventView.wheelZoomFactor(deltaY: 20, precise: true)
        #expect(decide(.scrollWheel, modifiers: .command, delta: up)
                == .magnify(factor))
        #expect(decide(.scrollWheel, modifiers: .command, delta: up,
                       punchedIn: true) == .magnify(factor))
        #expect(factor > 1, "scrolling up must zoom in")
    }

    /// Plain scroll pans, and ONLY while punched in: at 1:1 there is nothing to
    /// pan, and a wheel that zoomed until 1.1x and panned after would change
    /// meaning mid-roll.
    @Test func plainScrollPansOnlyWhilePunchedIn() {
        let delta = CGSize(width: 3, height: -7)
        #expect(decide(.scrollWheel, delta: delta, punchedIn: false)
                == .ignore)
        #expect(decide(.scrollWheel, delta: delta, punchedIn: true)
                == .pan(delta))
    }

    /// A trackpad reports points and a wheel notch reports lines, so the same
    /// numbers mean different distances. A notch is worth 16 points in the pan
    /// and in the zoom alike, or a notch would feel like two different gestures.
    @Test func aWheelNotchIsWorthSixteenPointsInBothGestures() {
        let one = CGSize(width: 1, height: 2)
        #expect(decide(.scrollWheel, delta: one, precise: true,
                       punchedIn: true) == .pan(one))
        #expect(decide(.scrollWheel, delta: one, precise: false,
                       punchedIn: true)
                == .pan(CGSize(width: 16, height: 32)))
        #expect(PunchEventView.wheelZoomFactor(deltaY: 1, precise: false)
                == PunchEventView.wheelZoomFactor(deltaY: 16, precise: true))
    }

    /// The monitor matches two event types; anything else that reaches it — a
    /// gesture the OS adds later, a synthesized event — passes through.
    @Test func anyOtherEventPassesThrough() {
        for type in [NSEvent.EventType.leftMouseDown, .keyDown, .rotate,
                     .swipe, .mouseMoved] {
            #expect(decide(type, punchedIn: true) == .ignore,
                    "\(type.rawValue) was claimed")
        }
    }

    /// Symmetry, which is why the factor goes through `exp`: scrolling N points
    /// up and N points back down returns exactly where it started, so a hand
    /// that overshoots and corrects does not drift the framing.
    @Test func theZoomStepsAreSymmetricAndClamped() {
        let up = PunchEventView.wheelZoomFactor(deltaY: 40, precise: true)
        let down = PunchEventView.wheelZoomFactor(deltaY: -40, precise: true)
        #expect(abs(up * down - 1) < 1e-12, "a step and its reverse do not cancel")
        // and one OS-accelerated flick cannot jump the whole range
        #expect(PunchEventView.wheelZoomFactor(deltaY: 5000, precise: true) == 2)
        #expect(PunchEventView.wheelZoomFactor(deltaY: -5000, precise: true) == 0.5)
    }
}
