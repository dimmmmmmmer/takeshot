import Foundation
import Testing

@testable import CaptureCore

/// What an operator is allowed to type into the frameline and desqueeze boxes.
///
/// The presets are the common shows, not every show, so both controls take a
/// number now (owner: "desqueze хочу иметь варик писать кастом", "и кастом
/// фреймлайнс тоже"). This is the whole contract of that box: generous about
/// how a crew spells a ratio, strict about what the number can be.
@Suite struct ModelAssistRatioInputTests {
    private let frameline = AssistRatioInput.framelineRange

    @Test func aDecimalIsTakenAsItIsWritten() {
        #expect(AssistRatioInput.parse("2.76", in: frameline) == 2.76)
        #expect(AssistRatioInput.parse(" 1.66 ", in: frameline) == 1.66)
    }

    /// A Russian keyboard puts a comma where the decimal point goes, and the
    /// app is in Russian for the operator who reported this.
    @Test func aCommaIsADecimalPoint() {
        #expect(AssistRatioInput.parse("2,76", in: frameline) == 2.76)
    }

    /// "4:3" and "16/9" are the same kind of thing said the way a crew says it.
    @Test func anAspectMayBeWrittenAsTwoNumbers() throws {
        let fourThree = try #require(AssistRatioInput.parse("4:3", in: frameline))
        #expect(abs(fourThree - 4.0 / 3.0) < 0.000001)
        let sixteenNine = try #require(AssistRatioInput.parse("16/9", in: frameline))
        #expect(abs(sixteenNine - 16.0 / 9.0) < 0.000001)
        #expect(AssistRatioInput.parse("16 / 9", in: frameline) == sixteenNine)
    }

    /// A squeeze factor is written on the lens with an x on it.
    @Test func aSqueezeFactorMayCarryItsX() {
        #expect(AssistRatioInput.parse("1.5x", in: AssistRatioInput.desqueezeRange) == 1.5)
        #expect(AssistRatioInput.parse("2X", in: AssistRatioInput.desqueezeRange) == 2)
    }

    /// Everything that would leave the operator judging a picture that cannot
    /// be judged. Refused, so the field can snap back to what it had.
    @Test func aNumberNothingCanBeDrawnAtIsRefused() {
        for bad in ["0", "-2.39", "", "  ", "abc", "2.39.1", "4:0", "4:", ":3",
                    "nan", "inf"] {
            #expect(AssistRatioInput.parse(bad, in: frameline) == nil,
                    "\(bad) was accepted as a ratio")
        }
        // outside what the caller can draw, either way
        #expect(AssistRatioInput.parse("0.1", in: frameline) == nil)
        #expect(AssistRatioInput.parse("12", in: frameline) == nil)
        #expect(AssistRatioInput.parse("6", in: AssistRatioInput.desqueezeRange) == nil)
    }

    /// **What comes out of the box goes back in as the same NUMBER.** The field
    /// rewrites itself from the value after every commit, so a formatter that
    /// wrote 16/9 back as "1.78" would move the operator's frameline the first
    /// time they pressed Return on a box they had not touched.
    ///
    /// Asserted on the value, not on the spelling: "1.78" is a perfectly stable
    /// spelling of a ratio that is no longer the one that was asked for, which
    /// is exactly the bug.
    @Test func aTypedRatioSurvivesBeingWrittenBackOut() throws {
        for typed in ["2.76", "1.66", "16/9", "4:3", "2,39"] {
            let value = try #require(AssistRatioInput.parse(typed, in: frameline))
            let written = AssistRatioInput.text(value)
            let again = try #require(AssistRatioInput.parse(written, in: frameline))
            #expect(abs(again - value) < 0.0002,
                    Comment(rawValue: "\(typed) came back out of the box as "
                        + "\(written) — \(again), not \(value)"))
        }
    }

    /// No trailing zeros — the box is 64pt wide and "2.3900" says nothing
    /// "2.39" does not.
    @Test func theBoxIsWrittenWithoutTrailingZeros() {
        #expect(AssistRatioInput.text(2.39) == "2.39")
        #expect(AssistRatioInput.text(2) == "2")
        #expect(AssistRatioInput.text(1.5) == "1.5")
    }
}
