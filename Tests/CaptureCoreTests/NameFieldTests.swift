import Foundation
import Testing

@testable import CaptureCore

/// What the naming fields accept, per keystroke (owner item 28).
///
/// The complaint was that the fields let an invalid character be typed and
/// erased it afterwards. `normalized` is the answer to "what does the field
/// hold after this edit", and the formatter behind the real field installs it
/// in place of the proposed edit — so everything refused here is a character
/// that never appears on screen. What the field never has to think about
/// afterwards is asserted at the bottom: whatever survives this filter,
/// `NamingEngine.sanitize` leaves alone.
struct NameFieldTests {
    /// Every character a file system refuses, in one string.
    private static let forbidden = #"/\:?*<>|""#

    @Test func theCounterFieldsTakeDigitsAndNothingElse() {
        for field in [NameField.clip, .take] {
            #expect(field.normalized("0123") == "0123")
            #expect(field.normalized("12a3") == "123")
            #expect(field.normalized("-5") == "5")
            #expect(field.normalized(" 7 ") == "7")
            // four is the width the controller clamps to anyway, so a fifth
            // digit is refused rather than accepted and rounded down
            #expect(field.normalized("12345") == "1234")
            #expect(field.maxLength == 4)
        }
    }

    @Test func theCameraLabelIsUppercaseLatinOnly() {
        #expect(NameField.camera.normalized("b") == "B")
        #expect(NameField.camera.normalized("cam b") == "CAMB")
        #expect(NameField.camera.normalized("A1") == "A")
        // a Cyrillic А looks identical on the keycap and is the realistic way a
        // non-ASCII character reaches a filename here
        #expect(NameField.camera.normalized("А") == "")
        #expect(NameField.camera.normalized("Aк") == "A")
    }

    /// The roll travels furthest of all of these — it is the CSV's Reel Name
    /// column, which every NLE downstream reads.
    @Test func theRollTakesAlphanumericsAndTheTwoSafeSeparators() {
        #expect(NameField.roll.normalized("A001") == "A001")
        #expect(NameField.roll.normalized("A-001_b") == "A-001_b")
        #expect(NameField.roll.normalized("A 001") == "A001")
        #expect(NameField.roll.normalized("A/001") == "A001")
        #expect(NameField.roll.normalized("Ролл") == "")
        #expect(NameField.roll.maxLength == nil)
    }

    /// Free-text fields keep spaces and accents — a scene is "12 A" and a
    /// project can be called anything — and lose only what a path cannot hold.
    @Test func theFreeTextFieldsLoseOnlyWhatAPathCannotHold() {
        for field in [NameField.prefix, .postfix, .scene, .shot] {
            #expect(field.normalized("12 A") == "12 A")
            #expect(field.normalized("Сцена 4") == "Сцена 4")
            #expect(field.normalized("a/b") == "ab")
            #expect(field.normalized("x\u{0}y") == "xy")
            #expect(field.normalized("line\nbreak") == "linebreak")
            for character in Self.forbidden {
                #expect(field.normalized("A\(character)B") == "AB",
                        "\(field) let \(character) through")
            }
        }
    }

    /// `accepts` is the same question asked of a whole value — what a paste has
    /// to pass, and what a test can assert without knowing the filter's shape.
    @Test func acceptsAgreesWithNormalized() {
        for field in NameField.allCases {
            for sample in ["A001", "12 A", "a/b", "0007", "Кам", "", "x\u{0}"] {
                #expect(field.accepts(sample) == (field.normalized(sample) == sample),
                        "\(field) disagreed with itself on \(sample.debugDescription)")
                // and normalizing is idempotent — a field can never be left
                // holding something it would refuse
                #expect(field.accepts(field.normalized(sample)),
                        "\(field) refuses its own output for \(sample.debugDescription)")
            }
        }
    }

    /// The last line and the first one have to agree: anything the field lets
    /// the operator type is a character the filename pass will not rewrite.
    /// Where they disagreed is exactly where the erase-after-the-fact behaviour
    /// came from.
    @Test func whatTheFieldsAcceptSurvivesTheFilenamePass() {
        let samples = ["A001", "B", "0007", "pickup", "Сцена", "12A"]
        for field in NameField.allCases {
            for sample in samples {
                let typed = field.normalized(sample)
                guard !typed.isEmpty else { continue }
                #expect(NamingEngine.sanitize(typed) == typed,
                        "\(field) accepts \(typed) and the filename pass rewrites it")
            }
        }
    }
}
