import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

// The footer's naming BLOCK, as opposed to either of its rows: what it shows
// under the boxes, and where the reel is edited. Split out of
// `ViewNamingRowTests` when that file reached its length ceiling — the two
// suites here ask about the block as a whole, which is also why neither could
// be measured from a row.

/// **The name the next take will get, under the boxes that decide it.**
///
/// Owner: "в навбаре кстати добавить бы еще превью имени которое будет у след
/// тейка" — "ну вот чтоб под боксами было подписано оно аккуратно". Its own
/// suite because the claim is about the BLOCK's geometry rather than about a
/// row's.
@MainActor
struct ViewNextNameTests {
    /// Something is drawn under the boxes, and a long name cannot widen the
    /// block that the footer's two halves are balanced against.
    ///
    /// The second half is the whole reason the preview is an overlay over a
    /// flexible spacer rather than a row of the stack: a `Text` reports its own
    /// ideal width, so a long project name would push the block wider and walk
    /// the centred REC button off centre as the operator typed. Measured: 274pt
    /// with "SUNSET" and 274pt with a 66-character project.
    @Test func theNextNameIsShownAndCannotWidenTheBlock() async throws {
        try await ViewProbe.run { probe in
            probe.controller.settings.naming.projectName = "SUNSET"
            probe.controller.roll = "A007"
            probe.controller.nextTakeNumber = 12
            try #require(!probe.controller.pendingTakeName.isEmpty,
                         "there is no name to preview, so this proves nothing")

            let box = CGSize(width: 300, height: 60)
            let ink: CGRect = try #require(
                ViewRender.drawnBounds(probe.hosted(NamingFieldsView()), in: box),
                "the block drew nothing at all")
            // The ink's own EXTENT, not where it ends: a block with no
            // preview is centred in the box it is rendered in, so its last row
            // of pixels still lands past the row's height and a `maxY` claim
            // is green over a deleted preview. Seen: this assertion passed the
            // mutation until it was written this way.
            #expect(ink.height > NamingFieldsView.rowHeight + 4, """
                nothing is drawn under the boxes: \(ink.height)pt of ink for a \
                \(NamingFieldsView.rowHeight)pt row
                """)

            let short: CGSize = probe.fittingSize(probe.hosted(NamingFieldsView()))
            probe.controller.settings.naming.projectName =
                String(repeating: "LONGPROJECT", count: 6)
            let long: CGSize = probe.fittingSize(probe.hosted(NamingFieldsView()))
            #expect(long.width == short.width, """
                a long project name widened the naming block from \
                \(short.width)pt to \(long.width)pt — the REC button moves \
                with it
                """)
            // …and the block does not STRETCH into the half it sits in.
            // `Color.clear` under the rows is flexible, and the block's
            // neighbour in the footer is a flexible spacer: offered the whole
            // half, a block that grew would slide the fields off the right
            // edge toward the record button. Asked the way the footer asks —
            // with a proposal, not with `fittingSize`, which cannot see this.
            let offered = CGSize(width: 600, height: 200)
            let taken: CGSize = ViewRender.laidOutSize(
                probe.hosted(NamingFieldsView()), in: offered)
            #expect(taken.width <= short.width + 1, """
                offered \(offered.width)pt the block took \(taken.width) — \
                the fields leave the right edge
                """)
        }
    }
}

/// **Where the reel is edited — a different question from what the file is
/// called.**
///
/// Its own suite rather than another case in `ViewNamingRowTests`, because the
/// claim spans BOTH of that block's rows and is measured over the block as a
/// whole.
@MainActor
struct ViewReelEditorTests {
    /// **The reel is editable under every template, and never twice.**
    ///
    /// This is the invariant the ROLL field's move is FOR, and it is the one
    /// that has been broken in both directions inside a week: hidden with the
    /// Sony α preset (uneditable reel, and a clip counter restarting on a value
    /// nobody can type), then — reading the report as "drop the reel" — dropped
    /// from the template's vocabulary altogether. So it is stated as a count
    /// over the WHOLE naming block rather than as "the file row shows it":
    /// switch the block to each pane in turn and count the boxes actually
    /// holding the reel.
    ///
    /// A sentinel value rather than a position, because the claim is about the
    /// editor rather than about the layout — a box holding the reel is one an
    /// operator can type the reel into, wherever the row puts it.
    @Test func theReelHasExactlyOneEditorUnderEveryTemplate() async throws {
        try await ViewProbe.run { probe in
            let sentinel = "R0T7"
            probe.controller.roll = sentinel
            try #require(probe.controller.roll == sentinel,
                         "the reel did not take the sentinel, so nothing below counts")

            /// Which panes of the block hold an editor with the reel in it.
            @MainActor func panesEditingTheReel() -> [NamingPane] {
                NamingPane.allCases.filter { pane in
                    probe.controller.namingPane = pane
                    let host = NSHostingView(rootView: AnyView(
                        probe.hosted(NamingFieldsView())))
                    host.frame = CGRect(x: 0, y: 0,
                                        width: ViewBudget.footerHalfWidth,
                                        height: 200)
                    host.layoutSubtreeIfNeeded()
                    return Self.countTextFields(in: host, holding: sentinel) > 0
                }
            }

            probe.controller.settings.naming.namingTemplate =
                "{prefix}_{cam}{roll}C{clip}_{postfix}"
            #expect(panesEditingTheReel() == [.file],
                    "a template built out of the reel edits it somewhere other than the file row")

            let alpha: NamingPreset = try #require(
                NamingPreset.all.first { $0.key == "preset_sony_alpha" },
                "the Sony α preset is gone")
            probe.controller.applyNamingPreset(alpha)
            #expect(panesEditingTheReel() == [.meta],
                    """
                    under \(alpha.template) the reel is edited in \
                    \(panesEditingTheReel()) — it must be on the META row \
                    and only there
                    """)

            // …and the two rows really do read ONE rule, so they cannot both
            // answer yes or both answer no for some third template.
            for template in ["{prefix}_{cam}{reel}C{clip}", "C{clip}_{tc}",
                             "{roll}", "{prefix}_{date}"] {
                probe.controller.settings.naming.namingTemplate = template
                let panes: [NamingPane] = panesEditingTheReel()
                let expected: [NamingPane] =
                    NamingFieldsView.templateCarriesRoll(template)
                    ? [NamingPane.file] : [NamingPane.meta]
                #expect(panes.count == 1,
                        "\(template) puts the reel's editor in \(panes)")
                #expect(panes == expected,
                        "\(template) edits the reel in \(panes), against its own rule")
            }
        }
    }

    /// How many of the view's text fields are holding `value` — the way to ask
    /// "is THIS value editable on screen" without naming a position.
    private static func countTextFields(in view: NSView,
                                        holding value: String) -> Int {
        if let field = view as? NSTextField {
            return field.stringValue == value ? 1 : 0
        }
        return view.subviews.reduce(0) {
            $0 + countTextFields(in: $1, holding: value)
        }
    }
}

/// **A stepper that cannot move is greyed out rather than dead under the
/// pointer.**
///
/// `SlateStep.canStep` was written for exactly this and then never called: the
/// arrows stayed lit on "112A pickup", which has no number and no pageable
/// letter. A control that looks live and does nothing reads on set as the app
/// having hung — a press, a pause, and then a second press.
///
/// Asserted through the AppKit control rather than through a render: an
/// offscreen host draws an enabled and a disabled `NSStepper` to the same
/// pixels (measured — the two bitmaps agree to every digit), so a brightness
/// comparison here would pass whatever the code did.
@MainActor
struct ViewSteppedFieldTests {
    /// Every `NSControl` in a hosted tree, so the assertion is about the
    /// control the operator actually clicks.
    private static func controls(_ view: NSView) -> [NSControl] {
        var found: [NSControl] = []
        if let control = view as? NSControl { found.append(control) }
        for child in view.subviews { found += controls(child) }
        return found
    }

    private static func steppersAreEnabled(_ view: some View) -> [Bool] {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: CGSize(width: 420, height: 70))
        host.layoutSubtreeIfNeeded()
        return controls(host)
            .filter { String(describing: type(of: $0)).contains("Stepper") }
            .map(\.isEnabled)
    }

    /// The builder itself: the same field, with and without a usable arrow.
    @Test func aFieldWithNothingToPageDisablesItsStepper() {
        let live = Self.steppersAreEnabled(
            NamingFieldsView.steppedField("SCENE", field: .scene, width: 70,
                                          text: .constant("12"),
                                          onStep: { _ in }))
        #expect(live == [true], "the field has no stepper to look at: \(live)")
        let dead = Self.steppersAreEnabled(
            NamingFieldsView.steppedField("SCENE", field: .scene, width: 70,
                                          text: .constant("12"),
                                          onStep: { _ in },
                                          canStep: { _ in false }))
        #expect(dead == [false], """
            a field whose arrows can do nothing is still live — `canStep` \
            reaches no control
            """)
    }

    /// And the slate row asks it. "pickup 1" ends in a number the arrows page;
    /// "1 pickup" ends in the last letter of a word, which they must not — the
    /// same glyphs, so nothing but the arrows can differ.
    @Test func theSlateRowGreysAStepperItCannotUse() {
        let pageable = Self.steppersAreEnabled(
            SlateFieldsEditor(scene: .constant("pickup 1"), shot: .constant("2"),
                              takeText: .constant("3")))
        #expect(pageable == [true, true, true],
                "the slate row's three steppers are not all live: \(pageable)")
        let stuck = Self.steppersAreEnabled(
            SlateFieldsEditor(scene: .constant("1 pickup"), shot: .constant("2"),
                              takeText: .constant("3")))
        #expect(stuck == [false, true, true], """
            a scene with nothing to page keeps a live stepper — the row is not \
            asking `SlateStep.canStep`: \(stuck)
            """)
    }

    /// An empty field keeps its stepper: up seeds it with "1", which is how a
    /// scene is entered without going for the keyboard.
    @Test func anEmptyFieldKeepsTheArrowThatSeedsIt() {
        let empty = Self.steppersAreEnabled(
            SlateFieldsEditor(scene: .constant(""), shot: .constant(""),
                              takeText: .constant("")))
        #expect(empty == [true, true, true],
                "an empty slate row cannot be filled with the arrows: \(empty)")
    }
}
