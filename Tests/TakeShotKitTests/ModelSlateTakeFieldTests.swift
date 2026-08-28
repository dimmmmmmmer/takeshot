import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// What a TAKE field means, from all three places one can be typed into.
///
/// The number these produce is `SlateMetadata.take`: it is written into the
/// .mov when the writer opens it, and into `takeshot-slate.csv` and the ALE
/// afterwards. Three surfaces write it — the footer's field, the takes panel's
/// popover, and the phone — and they read the same typing three different ways
/// before `SlateTakeField`. Two of them are drawn by the SAME view
/// (`SlateFieldsEditor`), which is why nothing looked wrong.
@Suite struct ModelSlateTakeFieldTests {
    /// Every typing anyone has to worry about, and the one number all three
    /// surfaces have to land on. The three columns that used to differ:
    /// `12A` was 12, 12 and **0**; `12345` was **9999**, **1234** and
    /// **12345**; `0` was **1**, 0 and 0.
    private static let readings: [(typed: String, take: Int)] = [
        ("3", 3),
        ("12", 12),
        // a scene number typed into the take box: the digits are what was meant
        ("12A", 12),
        ("T7", 7),
        ("9999", 9999),
        // over the ceiling clamps — it does NOT keep the first four digits,
        // which is a plausible-looking take number with a digit silently gone
        ("12345", SlateTakeField.maximum),
        ("0", 0),
        ("000", 0),
        ("", 0),
        ("   ", 0),
        ("pickup", 0),
    ]

    @Test func theFieldReadsOneNumberOutOfWhateverWasTyped() {
        for reading in Self.readings {
            let read: Int = SlateTakeField.number(from: reading.typed)
            #expect(read == reading.take,
                    "\"\(reading.typed)\" read as \(read), not \(reading.take)")
        }
    }

    /// The footer's field and the phone are two people logging the same take
    /// into the same sidecar, so they have to agree — and they did not. The
    /// footer stripped non-digits and clamped at 9999; the phone refused
    /// anything that was not purely a number and then accepted any number at
    /// all, so a scripty could log take 99999 and a "12A" typo logged nothing.
    ///
    /// Driven through the real entry points rather than the function, because
    /// the claim is about the call sites: sharing the rule is the fix.
    @Test @MainActor func theCartAndThePhoneLogTheSameTakeNumber() async throws {
        for reading in Self.readings {
            let phone: SlateMetadata = try Self.slateOverTheWire(take: reading.typed)
            #expect(phone.take == reading.take,
                    "the phone read \"\(reading.typed)\" as \(phone.take)")
        }
        try await ControllerHarness.run { controller, _ in
            controller.shot = "A" // slating, so the field has a meaning
            controller.nextTakeNumber = 41 // and a counter to fall back to
            for reading in Self.readings {
                controller.commitSlateTakeText(reading.typed)
                // 0 is not a take number, it is "follow the clip counter" —
                // the field's own way of saying nothing is logged
                let expected: Int? = reading.take > 0 ? reading.take : nil
                let got: String = String(describing: controller.slateTakeOverride)
                #expect(controller.slateTakeOverride == expected,
                        "the footer read \"\(reading.typed)\" as \(got)")
            }
        }
    }

    /// The ‹ › arrows and the keyboard are two ways to set one field, so they
    /// stop in the same place. `SlateStep.maxNumber` says "nothing pages past
    /// this"; a field that ACCEPTED more from the keyboard would make that
    /// sentence false, and it was a second `9999` literal away from doing so.
    @Test func theArrowsAndTheKeyboardStopAtTheSameNumber() {
        #expect(SlateTakeField.maximum == SlateStep.maxNumber)
        let ceiling: String = String(SlateTakeField.maximum)
        #expect(SlateStep.stepped(ceiling, by: 1, seed: "1") == ceiling,
                "the arrow paged past the ceiling")
        #expect(SlateTakeField.number(from: ceiling + "9")
            == SlateTakeField.maximum,
                "the keyboard typed past the ceiling")
    }

    /// A number shown in the field and typed straight back in is the same
    /// number. The popover LOADS the take into the field and SAVES it back, so
    /// an operator who opens it to fix a comment and presses save must not
    /// change the take number by doing nothing to it.
    @Test func whatTheFieldShowsTypedBackInIsWhatItShowed() {
        for take in [0, 1, 7, 42, 999, SlateTakeField.maximum] {
            let shown: String = SlateTakeField.text(for: take)
            let back: Int = SlateTakeField.number(from: shown)
            #expect(back == take,
                    "take \(take) shows as \"\(shown)\" and reads back as \(back)")
        }
        // and an unlogged take is a BLANK field, never a "0" — a 0 in the box
        // reads as a take that was logged as zero
        #expect(SlateTakeField.text(for: 0).isEmpty)
        #expect(SlateTakeField.text(for: -3).isEmpty)
    }

    /// Two ways of typing something that is not a number, both of which used to
    /// come out as a take somebody would have to explain.
    ///
    /// A run of digits longer than an `Int` makes `Int(_:)` answer nil, and
    /// every call site had its own `?? fallback` for that — the footer's was 1,
    /// so leaning on a key logged take 1 over whatever was there. And
    /// `Character.isNumber` is true of "١٢", which `Int(_:)` then refuses, so a
    /// non-Latin numeral went down the same nil path.
    @Test func nothingThatIsNotANumberBecomesOne() {
        #expect(SlateTakeField.number(from: String(repeating: "9", count: 40))
            == SlateTakeField.maximum,
                "a leant-on key did not read as the ceiling")
        #expect(SlateTakeField.number(from: "١٢") == 0,
                "a non-ASCII numeral was read as a take number")
        // and the ASCII digits inside a mixed string still count
        #expect(SlateTakeField.number(from: "١٢3") == 3)
    }

    /// The phone's parse, through the real message decoder.
    private static func slateOverTheWire(take: String) throws -> SlateMetadata {
        let payload: [String: String] = ["action": "slate", "id": "AB-1",
                                         "scene": "12", "shot": "B",
                                         "take": take, "pin": "0417"]
        let data: Data = try JSONSerialization.data(withJSONObject: payload)
        let json: String = try #require(String(data: data, encoding: .utf8))
        let message: RemoteMessage = try #require(RemoteMessage.parse(json))
        guard case .slate(_, let slate) = message.command else {
            Issue.record("the phone's slate message did not parse: \(json)")
            return .empty
        }
        return slate
    }
}
