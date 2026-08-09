import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// The footer's naming block after the slate moved into it (owner items 27 and
/// 28): two rows of real fields, and fields that refuse a bad character rather
/// than erasing it a moment later.
@MainActor
struct ViewNamingRowTests {
    /// The slate row is ONE control tall.
    ///
    /// It used to be a caption stacked over a box, three times over, and three
    /// stacks made the whole footer a caption-line taller than the picture could
    /// spare — the owner's "the shot/scene/take fields make the footer much
    /// taller". The caption is beside its box now, so the row costs exactly what
    /// the box costs. Measured against a bare `NameTextField`, which is what the
    /// box is: a row taller than that has the caption back on its own line.
    @Test func theSlateRowIsOneControlTall() async throws {
        try await ViewProbe.run { probe in
            let box: CGSize = probe.fittingSize(
                NameTextField(field: .scene, text: .constant("12A"))
                    .frame(width: 70))
            let row = probe.fittingSizes {
                SlateFieldsEditor(scene: .constant("12A"), shot: .constant("B"),
                                  takeText: .constant("3"))
            }
            #expect(box.height > 0, "the measurement of the box itself is broken")
            #expect(row.en.height <= box.height + 2,
                    "the slate row is \(row.en.height)pt for a \(box.height)pt box")
            #expect(row.ru.height == row.en.height,
                    "the row took a different height in Russian: \(row)")

            // …and the block above it still stacks: two rows, not one
            let block = probe.fittingSizes { NamingFieldsView() }
            #expect(block.en.height > row.en.height + 10,
                    "the naming block is \(block.en.height)pt — the rows did not stack")
        }
    }

    /// The three captions are the only localized strings in the footer's right
    /// half, and beside their boxes they are charged to the row's width — so
    /// they live in a FIXED box, and a translation that does not fit it is
    /// truncated in silence. Both languages are measured against that box.
    @Test func theSlateCaptionsFitTheirFixedBoxInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let box = SlateFieldsEditor.captionWidth
            for key in ["scene", "slate_shot", "slate_take"] {
                let caption = probe.fittingSizes { () -> Text in
                    Text(L(key)).font(.system(size: 9, weight: .semibold))
                }
                #expect(caption.en.width <= box,
                        "\(key) is \(caption.en.width)pt in English, the box is \(box)")
                #expect(caption.ru.width <= box,
                        "\(key) is \(caption.ru.width)pt in Russian, the box is \(box)")
                // …and they are the caps the row above uses (owner item 3)
                let english = ViewRender.withLanguage(.english) { L(key) }
                let russian = ViewRender.withLanguage(.russian) { L(key) }
                #expect(english == english.uppercased(),
                        "\(key) reads \(english) beside CAM/ROLL/CLIP")
                #expect(russian == russian.uppercased(),
                        "\(key) reads \(russian) in Russian")
            }
        }
    }

    /// Scene / shot / take are FIELDS in the footer now, not a chip that opens
    /// a popover. They are on their own row because the file-name row has no
    /// room for them — wrapping was the instruction, not shrinking — so what
    /// this pins is: both rows fit the footer's half, the block is taller than
    /// one row, and neither row's width depends on the language.
    @Test func theSlateRowSitsUnderTheNamingRowAndFitsTheFooterHalf() async throws {
        try await ViewProbe.run { probe in
            let half = ViewBudget.footerHalfWidth
            let slate = probe.fittingSizes { NamingFieldsView() }
            let slateRow = probe.fittingSizes {
                SlateFieldsEditor(scene: .constant("112A pickup"),
                                  shot: .constant("3B"), takeText: .constant("12"))
            }

            #expect(slate.ru.width <= half,
                    "the naming block wants \(slate.ru.width)pt of \(half)")
            #expect(slate.en.width <= half)
            #expect(slateRow.ru.width <= half,
                    "the slate row alone wants \(slateRow.ru.width)pt of \(half)")
            // the block really is two rows: taller than the slate row on its own
            #expect(slate.en.height > slateRow.en.height + 10,
                    "the naming block is \(slate.en.height)pt — the rows did not stack")
        }
    }

    /// Every label in the block is latin (SCENE/SHOT/TAKE beside CAM/ROLL/CLIP),
    /// because the footer has to measure identically in both languages or the
    /// centered REC button stops being centered. The slate labels ARE localized
    /// strings — "Scene"/"Сцена" — so this is the one that would catch a
    /// translation reaching the row.
    @Test func theNamingBlockMeasuresTheSameInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let block = probe.fittingSizes { NamingFieldsView() }
            #expect(block.ru.height == block.en.height,
                    "the block took a different number of rows: \(block)")
            #expect(block.ru.width <= ViewBudget.footerHalfWidth)
            #expect(block.en.width <= ViewBudget.footerHalfWidth)

            // and the whole footer still fits its column in both
            let footer = probe.sizes(proposedWidth: ViewBudget.footerWidth) {
                BottomBarView()
            }
            #expect(footer.ru.width == ViewBudget.footerWidth)
            #expect(footer.ru.height == footer.en.height,
                    "the footer changed height with the language: \(footer)")
        }
    }

    /// The collision badge is the one localized thing in the file-name row
    /// ("TAKEN" / "ЗАНЯТО"). It may be a few points wider in Russian; it may
    /// not add a row, and the block still has to fit.
    ///
    /// Its presence is read off the file-name row rather than off the block —
    /// see the note on `ViewFooterTests.collisionBadgeStaysInsideTheNamingRow`.
    @Test func theCollisionBadgeStillDoesNotGrowTheBlock() async throws {
        try await ViewProbe.run { probe in
            let plainRow = probe.fittingSizes { NamingFileNameRow() }
            let plain = probe.fittingSizes { NamingFieldsView() }
            probe.controller.nameCollision = "TS_A001C01.mov"
            let warnedRow = probe.fittingSizes { NamingFileNameRow() }
            let warned = probe.fittingSizes { NamingFieldsView() }

            #expect(warned.ru.height == plain.ru.height,
                    "the collision badge added a row")
            #expect(warnedRow.ru.width > plainRow.ru.width,
                    "the collision badge did not render at all")
            #expect(warned.ru.width <= ViewBudget.footerHalfWidth,
                    "the warned block wants \(warned.ru.width)pt")
        }
    }

    /// The slate fields drive the controller directly now — no popover, no
    /// draft, no Save. Typing a scene restarts the take numbering inside it,
    /// which is what the popover used to do on commit.
    @Test func typingInTheSlateFieldsReachesThePendingTake() async throws {
        try await ViewProbe.run { probe in
            probe.controller.scene = "12A"
            probe.controller.shot = "B"
            #expect(probe.controller.pendingSlate.scene == "12A")
            #expect(probe.controller.pendingSlate.shot == "B")
            // a new scene starts its own take numbering at 1
            #expect(probe.controller.slateTakeFieldText == "1")

            probe.controller.commitSlateTakeText("7")
            #expect(probe.controller.slateTakeNumber == 7)
            // an emptied field hands numbering back to the clip counter
            probe.controller.commitSlateTakeText("")
            #expect(probe.controller.slateTakeFieldText
                    == String(probe.controller.nextTakeNumber))
        }
    }

    // MARK: - the character never gets in (owner item 28)

    /// The formatter behind every filename field, asked the question the
    /// operator asks with a keystroke: it must REFUSE the edit — return false —
    /// and hand back the text without the offending character, so the field
    /// installs the clean value instead of showing the dirty one first.
    /// One keystroke: what was typed into which field, and what the field is
    /// left holding.
    private struct Keystroke {
        let field: NameField
        let typed: String
        let kept: String
    }

    @Test func aRefusedCharacterNeverEntersTheField() {
        let cases = [
            Keystroke(field: .camera, typed: "Aк", kept: "A"),
            Keystroke(field: .camera, typed: "b", kept: "B"),
            Keystroke(field: .roll, typed: "A/001", kept: "A001"),
            Keystroke(field: .clip, typed: "12a", kept: "12"),
            Keystroke(field: .clip, typed: "12345", kept: "1234"),
            Keystroke(field: .take, typed: "3.5", kept: "35"),
            Keystroke(field: .scene, typed: "12:A", kept: "12A"),
            Keystroke(field: .shot, typed: "B*", kept: "B"),
            Keystroke(field: .prefix, typed: "MARS?", kept: "MARS"),
            Keystroke(field: .postfix, typed: "v2|", kept: "v2"),
        ]
        for stroke in cases {
            let formatter = NameFieldFormatter(field: stroke.field)
            var proposed = stroke.typed as NSString
            var range = NSRange(location: (stroke.typed as NSString).length,
                                length: 0)
            let valid = withUnsafeMutablePointer(to: &proposed) { pointer in
                withUnsafeMutablePointer(to: &range) { rangePointer in
                    formatter.isPartialStringValid(
                        AutoreleasingUnsafeMutablePointer(pointer),
                        proposedSelectedRange: rangePointer,
                        originalString: "", originalSelectedRange: NSRange(),
                        errorDescription: nil)
                }
            }
            #expect(!valid, "\(stroke.field) accepted \(stroke.typed) as typed")
            #expect(proposed as String == stroke.kept,
                    "\(stroke.field): \(stroke.typed) became \(proposed), wanted \(stroke.kept)")
            // the caret stays inside what was kept rather than jumping to 0
            #expect(range.location <= (stroke.kept as NSString).length)
            #expect(range.location >= 0)
        }
    }

    /// A value the field is happy with passes through with the edit intact —
    /// otherwise every keystroke would be a rejection and the caret would fight
    /// the operator.
    @Test func aValidEditIsAcceptedUntouched() {
        for (field, typed) in [(NameField.roll, "A001"), (.scene, "12 A"),
                               (.clip, "0042"), (.camera, "AB")] {
            let formatter = NameFieldFormatter(field: field)
            var proposed = typed as NSString
            let valid = withUnsafeMutablePointer(to: &proposed) { pointer in
                formatter.isPartialStringValid(
                    AutoreleasingUnsafeMutablePointer(pointer),
                    proposedSelectedRange: nil,
                    originalString: "", originalSelectedRange: NSRange(),
                    errorDescription: nil)
            }
            #expect(valid, "\(field) refused \(typed)")
            #expect(proposed as String == typed)
        }
    }

    /// The field renders as a real AppKit text field with the formatter
    /// installed — a representable that forgot to attach it would pass every
    /// test above and reject nothing on screen.
    @Test func theFieldInstallsItsFormatter() async throws {
        try await ViewProbe.run { _ in
            let field = NameTextField(field: .roll, text: .constant("A001"))
            let host = NSHostingView(rootView: AnyView(field))
            host.frame = CGRect(x: 0, y: 0, width: 60, height: 24)
            host.layoutSubtreeIfNeeded()
            let text = try #require(Self.firstTextField(in: host),
                                    "the representable made no NSTextField")
            #expect(text.stringValue == "A001")
            #expect(text.formatter is NameFieldFormatter,
                    "the field has no partial-string validation at all")
            #expect(text.isBezeled, "the field lost the rounded border chrome")
        }
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        for child in view.subviews {
            if let found = firstTextField(in: child) { return found }
        }
        return nil
    }
}
