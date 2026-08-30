import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// What the ‹ › arrows beside the slate fields do, asserted without a window.
///
/// The arrows page TEXT, so "one step" had to be defined before a button could
/// be wired to it — see `SlateStep`. The two facts an operator's day depends on
/// are the ones a size measurement could never see: that the ladder reaches
/// EMPTY at the bottom (an empty take number means "follow the clip counter"),
/// and that a scene someone typed a note into is left alone rather than having
/// its last letter incremented.
struct SlateStepTests {
    /// One field's ladder: whose rules it is paged under, what an empty press
    /// of › seeds it with, and where the walk starts.
    private struct Ladder {
        let field: NameField
        let seed: String
        let start: String
    }

    /// Scene and take numbers: the trailing digits, ±1.
    @Test func digitsPageByOne() {
        #expect(SlateStep.stepped("12", by: 1, seed: "1") == "13")
        #expect(SlateStep.stepped("12", by: -1, seed: "1") == "11")
        #expect(SlateStep.stepped("9", by: 1, seed: "1") == "10")
        // the run at the end of a longer value, not the whole string
        #expect(SlateStep.stepped("12A3", by: 1, seed: "1") == "12A4")
    }

    /// Zero padding is the operator's: "007" is a scene numbered by a
    /// production that pads, and paging it must not silently unpad it.
    @Test func zeroPaddingSurvivesAStep() {
        #expect(SlateStep.stepped("007", by: 1, seed: "1") == "008")
        #expect(SlateStep.stepped("009", by: 1, seed: "1") == "010")
        // …and it does not invent padding that was never there
        #expect(SlateStep.stepped("9", by: 1, seed: "1") == "10")
    }

    /// Shot letters: A → B → C, case kept, clamped at Z rather than rolling
    /// over into a two-letter shot nobody asked for.
    @Test func lettersPageThroughTheAlphabet() {
        #expect(SlateStep.stepped("A", by: 1, seed: "A") == "B")
        #expect(SlateStep.stepped("B", by: -1, seed: "A") == "A")
        #expect(SlateStep.stepped("12A", by: 1, seed: "A") == "12B")
        #expect(SlateStep.stepped("Z", by: 1, seed: "A") == "Z")
        #expect(SlateStep.stepped("b", by: 1, seed: "A") == "c",
                "a lower-case shot came back re-cased")
    }

    /// The bottom of every ladder is EMPTY, and that is the constraint the
    /// arrows exist under: an emptied take number hands numbering back to the
    /// clip counter, so it has to be reachable with the arrow and not only by
    /// selecting the text and deleting it.
    @Test func steppingOffTheBottomEmptiesTheField() {
        #expect(SlateStep.stepped("1", by: -1, seed: "1") == "")
        #expect(SlateStep.stepped("A", by: -1, seed: "A") == "")
        // a trailing token that is not the whole value only loses that token
        #expect(SlateStep.stepped("12A", by: -1, seed: "A") == "12")
        #expect(SlateStep.stepped("12", by: -1, seed: "1") == "11")
    }

    /// …and the first press of › from empty is the field's own first value.
    @Test func steppingUpFromEmptyGivesTheSeed() {
        #expect(SlateStep.stepped("", by: 1, seed: "1") == "1")
        #expect(SlateStep.stepped("", by: 1, seed: "A") == "A")
        #expect(SlateStep.stepped("", by: -1, seed: "1") == "",
                "an empty field stepped down invented a value")
    }

    /// A scene with a note in it is free text. "112A pickup" has a trailing
    /// letter, and paging it would produce "112A pickuq" — so the arrows leave
    /// it alone and say so by going grey.
    @Test func freeTextIsLeftAloneAndTheArrowsSaySo() {
        let scene = "112A pickup"
        #expect(SlateStep.stepped(scene, by: 1, seed: "1") == scene)
        #expect(SlateStep.stepped(scene, by: -1, seed: "1") == scene)
        #expect(!SlateStep.canStep(scene, by: 1))
        #expect(!SlateStep.canStep(scene, by: -1))
        // the same value with a number on the end IS pageable again
        #expect(SlateStep.canStep("112A pickup 2", by: 1))
        #expect(SlateStep.stepped("112A pickup 2", by: 1, seed: "1")
                == "112A pickup 3")
    }

    /// What each arrow offers, which is what enables or greys it.
    @Test func theArrowsKnowWhenTheyCanDoNothing() {
        #expect(SlateStep.canStep("", by: 1), "› from empty must seed the field")
        #expect(!SlateStep.canStep("", by: -1),
                "‹ on an empty field claimed it had somewhere to go")
        #expect(SlateStep.canStep("12", by: -1))
        #expect(SlateStep.canStep("12A", by: 1))
        #expect(!SlateStep.canStep("wide", by: 1))
        #expect(!SlateStep.canStep("12", by: 0))
    }

    /// The ceiling is the one the take field and the controller already clamp
    /// to, so the arrow cannot page past what can be typed or stored.
    @Test func pagingStopsAtTheCeiling() {
        #expect(SlateStep.stepped("9999", by: 1, seed: "1") == "9999")
        #expect(SlateStep.stepped("9998", by: 1, seed: "1") == "9999")
        #expect(SlateStep.maxNumber == 9999)
    }

    /// Every value the arrows can produce for a slate field has to be a value
    /// the field would have let the operator TYPE — otherwise the box refuses
    /// what its own arrow just put in it.
    @Test func everyPagedValueIsOneTheFieldAccepts() {
        let cases: [Ladder] = [
            Ladder(field: .scene, seed: "1", start: "12"),
            Ladder(field: .shot, seed: "1", start: "2"),
            Ladder(field: .take, seed: "1", start: "12"),
        ]
        for probe in cases {
            var value: String = probe.start
            for _ in 0..<6 {
                value = SlateStep.stepped(value, by: 1, seed: probe.seed)
                #expect(probe.field.accepts(value),
                        "\(probe.field) refuses its own arrow's \(value)")
            }
            for _ in 0..<40 {
                value = SlateStep.stepped(value, by: -1, seed: probe.seed)
                #expect(probe.field.accepts(value),
                        "\(probe.field) refuses its own arrow's \(value)")
            }
            #expect(value.isEmpty,
                    "\(probe.field) never reached the empty state: \(value)")
        }
    }
}
