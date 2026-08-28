import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The numbers beside the chroma dials, and the hex field's commit.
///
/// Both were decisions living where nothing could ask them: the readouts were
/// expressions inside the panel's `body`, and `commit()` is private to a view
/// SwiftUI does not build until the assist popover is presented. Rendering the
/// panel executes them and asserts nothing about what they SAY.
@Suite @MainActor struct ViewChromaReadoutTests {
    /// The three dials the operator reads as percentages, with the ranges the
    /// panel really gives them.
    private static let percentDials: [(name: String, range: ClosedRange<Double>)] = [
        ("tolerance", 0...ChromaKey.maxTolerance),
        ("softness", 0...ChromaKey.maxSoftness),
        ("spill", 0...1)
    ]

    /// Every dial reads 0 at one end and 100 at the other, whatever its range.
    ///
    /// This is the claim the panel used to make three different ways — and one
    /// of the three (softness) made it without dividing by anything at all.
    @Test func everyDialReadsZeroToAHundredAcrossItsOwnTravel() {
        for dial in Self.percentDials {
            let range = dial.range
            let readout = ChromaSliderReadout.percentOfTravel
            #expect(readout.text(for: range.lowerBound, in: range) == "0",
                    "\(dial.name) does not start at 0")
            #expect(readout.text(for: range.upperBound, in: range) == "100",
                    "\(dial.name) does not reach 100 at the end of its travel")
            let middle = (range.lowerBound + range.upperBound) / 2
            #expect(readout.text(for: middle, in: range) == "50",
                    "\(dial.name) is not linear across its travel")
        }
    }

    /// The regression the shared-rule wave wrote up and left: the softness
    /// readout was correct only because `maxSoftness` is 1.0.
    ///
    /// The ceiling is a real number with a real argument behind it — the
    /// feather is a fraction of the tolerance, so 1 is as gradual as a key can
    /// be and still have a boundary — and it is exactly the kind of constant a
    /// later measurement moves. Asked with any other ceiling, the old spelling
    /// (`percent(value)`, no divisor) returns the RAW value: a dial the
    /// operator can see is hard against the end of its slider, reading 80.
    @Test func aDialWhoseCeilingMovesStillReachesAHundred() {
        for ceiling in [0.8, 0.5, 2.0, 0.6] {
            let range = 0...ceiling
            #expect(ChromaSliderReadout.percentOfTravel
                .text(for: ceiling, in: range) == "100",
                    "a dial with ceiling \(ceiling) stops short of 100")
            #expect(ChromaSliderReadout.percentOfTravel
                .text(for: ceiling / 2, in: range) == "50",
                    "a dial with ceiling \(ceiling) is not linear")
        }
    }

    /// The number agrees with where the knob is. A slider pins its knob at the
    /// end for a value outside its range, so a readout of 120 beside a stopped
    /// knob is the control disagreeing with itself.
    @Test func aDialNeverReadsPastTheEndOfItsSlider() {
        let range = 0...ChromaKey.maxTolerance
        let readout = ChromaSliderReadout.percentOfTravel
        #expect(readout.text(for: 99, in: range) == "100")
        #expect(readout.text(for: -99, in: range) == "0")
    }

    /// A zero-width range answers 0 rather than dividing by it.
    ///
    /// The second case is the one that carries this test, and that is a
    /// measurement: with the guard removed, `0` on `0...0` still answers "0",
    /// because the fraction is NaN and the clamp absorbs it (`max(0, .nan)` is
    /// 0 — `nan >= 0` is false). It is `5` on `3...3` that divides by zero to
    /// +∞, clamps to 1 and reads **100** — "all the way along" a travel of
    /// zero. A test that only asked the first case would have gone green
    /// against the bug.
    @Test func aDegenerateRangeAnswersZeroRatherThanDividingByIt() {
        #expect(ChromaSliderReadout.percentOfTravel.text(for: 0, in: 0...0) == "0")
        #expect(ChromaSliderReadout.percentOfTravel.text(for: 5, in: 3...3) == "0",
                "a value off a zero-width range read as the end of its travel")
    }

    /// The plate offsets are percent OF THE FRAME and keep their sign — a
    /// different denominator from the dials above, on purpose: at `maxOffset`
    /// the plate is shifted half a frame, which is +50 and not +100.
    @Test func theOffsetsReadAsSignedPercentOfTheFrame() {
        let limit = ChromaKey.PlateLayout.maxOffset
        let range = -limit...limit
        let readout = ChromaSliderReadout.signedPercentOfFrame
        #expect(readout.text(for: limit, in: range) == "+50")
        #expect(readout.text(for: -limit, in: range) == "-50")
        #expect(readout.text(for: 0, in: range) == "+0",
                "a centred plate must still show its sign column")
        #expect(readout.text(for: 0.125, in: range) == "+13",
                "the offset does not round to the nearest percent")
    }

    /// The plate scale is a multiplier, and 2.5× is not a percentage of
    /// anything.
    @Test func theScaleReadsAsAMultiplier() {
        let range = ChromaKey.PlateLayout.minScale...ChromaKey.PlateLayout.maxScale
        let readout = ChromaSliderReadout.multiplier
        #expect(readout.text(for: 1, in: range) == "1.00")
        #expect(readout.text(for: ChromaKey.PlateLayout.maxScale, in: range)
                == "4.00")
        #expect(readout.text(for: 0.25, in: range) == "0.25")
    }

    /// Every readout fits the 30-point column the row reserves for it. A number
    /// that grows a digit past the frame pushes the slider, which is the reason
    /// that column is fixed at all.
    @Test func noReadoutOutgrowsItsColumn() {
        var widest = 0
        for dial in Self.percentDials {
            for step in 0...20 {
                let value = dial.range.lowerBound
                    + (dial.range.upperBound - dial.range.lowerBound)
                    * Double(step) / 20
                widest = max(widest, ChromaSliderReadout.percentOfTravel
                    .text(for: value, in: dial.range).count)
            }
        }
        #expect(widest <= 3, "a percentage readout grew to \(widest) characters")
    }

    // MARK: - the hex field

    /// An unparseable hex is put back rather than swallowed: a field keeping a
    /// value nothing on screen matches is worse than one that reverts.
    @Test func theHexFieldPutsBackWhatItCannotParse() {
        let current = ChromaKey.greenScreen
        for nonsense in ["", "#12345", "nope", "#GGGGGG", "+FF000", "  "] {
            let outcome = ChromaColorField.committed(text: nonsense,
                                                     current: current)
            #expect(outcome.color == current,
                    "\"\(nonsense)\" changed the screen colour")
            #expect(outcome.text == current.hexString,
                    "\"\(nonsense)\" was left in the field")
        }
    }

    /// A parseable one is adopted AND normalized, which is what makes the
    /// commit an inverse of the `onChange` that writes `hexString` into the
    /// same field.
    @Test func aParsedHexIsAdoptedInTheFieldsOwnSpelling() {
        let outcome = ChromaColorField.committed(text: "0000ff",
                                                 current: ChromaKey.greenScreen)
        #expect(outcome.color == ChromaKey.blueScreen,
                "a hex with no hash was refused")
        #expect(outcome.text == "#0000FF",
                "the field kept the operator's spelling: \(outcome.text)")

        // …and committing what the field already shows is a fixed point
        let again = ChromaColorField.committed(text: outcome.text,
                                               current: outcome.color)
        #expect(again.color == outcome.color)
        #expect(again.text == outcome.text)
    }
}
