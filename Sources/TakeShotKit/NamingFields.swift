import CaptureCore
import SwiftUI

/// CLIP field: digits only, max 4; text isn't reformatted while typing,
/// commit on Enter/blur; leading zeros set the filename padding.
struct ClipField: View {
    @EnvironmentObject private var controller: CaptureController
    @State private var text = ""
    @State private var editing = false

    var body: some View {
        NamingFieldsView.steppedField(
            L("clip_label"), field: .clip, width: 50, text: $text,
            onStep: { controller.nextTakeNumber = min(
                9999, max(0, controller.nextTakeNumber + $0)) },
            onCommit: { controller.commitClipText(text) },
            onEditingChanged: { editing = $0 })
            .onAppear { text = controller.clipDisplay }
            // The counter moves without this field: a landed take advances it,
            // a roll change restarts it. Mirrored back — but never while the
            // operator is mid-word, or a take landing would delete what they
            // are typing.
            .onChange(of: controller.nextTakeNumber) { _, _ in
                if !editing { text = controller.clipDisplay }
            }
            .onChange(of: controller.settings.naming.clipPadWidth) { _, _ in
                if !editing { text = controller.clipDisplay }
            }
    }
}

/// Naming fields: what the file is called on top, what was shot underneath.
///
/// Two rows, and that is a measurement (owner item 27). Scene, shot and take
/// used to be a chip in this row that opened a popover, because CAM + ROLL +
/// CLIP + POSTFIX already spend most of `footerHalfWidth` (363pt at the app's
/// minimum window) and three more labelled fields overflow it — which pushes
/// the centered REC button off centre, the failure `ViewFooterTests` exists to
/// catch. Typing into a popover is not something anyone wants to do between
/// takes, so the fields are real and the row they do not fit on is a second
/// row: the budget is respected by wrapping, not by shrinking every field
/// until they all fit.
struct NamingFieldsView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        VStack(alignment: .trailing, spacing: Self.previewGap) {
            rows
            namePreview
        }
        // **The block keeps its own width.** `Color.clear` under the rows is
        // FLEXIBLE, and the block sits in a half beside a flexible spacer — so
        // without this the two would share the space and the fields would
        // drift off the right edge toward the record button as soon as the
        // preview existed. Horizontal only: the height is the row plus the
        // preview line and is what it is.
        .fixedSize(horizontal: true, vertical: false)
        .animation(.easeOut(duration: 0.15), value: controller.nameCollision)
        .animation(.easeOut(duration: 0.15),
                   value: controller.settings.naming.namingTemplate)
    }

    /// **What the next take will be called**, under the boxes that decide it
    /// (owner: "в навбаре кстати добавить бы еще превью имени которое будет у
    /// след тейка" — "ну вот чтоб под боксами было подписано оно аккуратно").
    ///
    /// `pendingTakeName` and not a second composition: it is the same string
    /// the collision warning is about and the same one the phone shows, built
    /// from the values the pipeline is configured with. A preview composed
    /// here would be a second answer to "what is this file called".
    ///
    /// **Drawn in an overlay over a flexible spacer, which is the whole trick.**
    /// A `Text` as a plain row of this stack would report its own ideal width,
    /// and a long project name would then set the block's width — the block
    /// the footer's two halves are balanced against, so the centred REC button
    /// would move as the operator typed. `Color.clear` is flexible, so it takes
    /// the row's width and adds none, and the text inside is proposed exactly
    /// that width and truncates in the middle rather than overflowing toward
    /// the button.
    private var namePreview: some View {
        Color.clear
            .frame(height: Self.previewHeight)
            .overlay(alignment: .trailing) {
                Text(controller.pendingTakeName)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(L("next_name_help"))
            }
    }

    /// The preview's line, and the gap over it. One text line at 9pt, which is
    /// the caption size the rows above already use.
    static let previewHeight: CGFloat = 12
    static let previewGap: CGFloat = 2

    private var rows: some View {
        HStack(alignment: .center, spacing: NamingFieldsView.fieldGap) {
            // A switch ABOVE the rows made the whole footer jump on every
            // press (owner: "высота подвала прыгает при переключении"), back
            // when the two rows were different heights — the file row stacked
            // its captions over its boxes and the slate row put them beside.
            // Both stack now, so the heights match and the jump is gone twice
            // over; the switch stays beside them, because that is what the
            // layout was rebuilt around and what the tests measure. Beside
            // them it cannot jump: the block is as tall as whichever row is
            // showing, and
            // the switch is shorter than both.
            Group {
                switch controller.namingPane {
                case .file: NamingFileNameRow()
                case .meta: slateRow
                }
            }
            // …and pinned to the tallest of the two, so the row that is showing
            // sits where the other one would. Without this the block's height
            // still changes, it just changes on the other axis.
            .frame(height: Self.rowHeight, alignment: .bottom)
            paneSwitch
        }
    }

    /// FILE or META, on its side beside the fields.
    ///
    /// **Two buttons rather than a rotated `Picker`, and that was a
    /// measurement.** A segmented picker has no vertical style, so the first
    /// version rotated one — and a rotated picker rotates its CONTENT, so the
    /// glyphs came out lying on their sides. Counter-rotating them inside did
    /// not survive the picker's own re-render. A control that has to be
    /// un-rotated twice to look right is the wrong control.
    ///
    /// Icons and not words (owner: "переключатель вертикальный нужно значками
    /// сделать, подвал по высоте оч растянулся"): two words on their side cost
    /// the footer 92pt of height to say one bit. A document against a tag —
    /// what the file is CALLED against what was SHOT, the same distinction the
    /// two rows draw. The words stay as the tooltip and the accessibility
    /// label, so the control is still readable to someone meeting it.
    private var paneSwitch: some View {
        VStack(spacing: 2) {
            ForEach(NamingPane.allCases) { pane in
                let selected = controller.namingPane == pane
                Button { controller.namingPane = pane } label: {
                    // A TINTED plate under the glyph rather than a filled one,
                    // which is what the scopes panel's own toggles do. Filled
                    // with the accent, a white-ish accent — the default on this
                    // app — put a white glyph on a white cell and the selected
                    // side vanished.
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? Color.primary : .secondary)
                        .frame(width: Self.paneSwitchThickness,
                               height: Self.paneSwitchCellHeight)
                        .background(selected
                                    ? AnyShapeStyle(controller.accentColor
                                        .opacity(0.35))
                                    : AnyShapeStyle(Color.white.opacity(0.07)),
                                    in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .accessibilityLabel(L(pane.titleKey))
                .help(L(pane.titleKey))
            }
        }
    }

    /// One cell. Two of them plus the gap is the switch, and it is shorter than
    /// the naming row beside it — which is what keeps it from setting the
    /// footer's height.
    static let paneSwitchCellHeight: CGFloat = 17
    /// Across.
    static let paneSwitchThickness: CGFloat = 22
    /// What both naming rows are pinned to, so switching cannot change the
    /// block's height. The file row (captions stacked over boxes) is the taller
    /// of the two and sets it.
    static let rowHeight: CGFloat = 38

    /// Whether the file NAME is built out of the reel — which is the whole of
    /// the question "where is the roll edited".
    ///
    /// Stated once, and read by both rows, because the two answers have to be
    /// exact complements: asked twice it becomes two spellings of one rule,
    /// and the failure is silent in both directions — a reel with no editor
    /// anywhere (and a clip counter that restarts on a value nobody can type),
    /// or two boxes for one value on one screen.
    static func templateCarriesRoll(_ template: String) -> Bool {
        template.contains("{roll}") || template.contains("{reel}")
    }

    /// What was shot. NOT gated on the template like the row above: scene, shot
    /// and take describe the work, not the file name, so they are here whether
    /// or not a placeholder uses them.
    ///
    /// The ROLL is the exception in both directions, and it is the reason this
    /// row takes an optional binding at all: it describes the work AND names
    /// the file, so it lives on whichever row is actually using it — here when
    /// the template does not (owner: "режим сони легаси для нейминга должен
    /// быть типа C0001 / а у меня остается поле ролла почему-то"), on the file
    /// row when it does. Never on both, and never on neither.
    private var slateRow: some View {
        SlateFieldsEditor(
            scene: $controller.scene, shot: $controller.shot,
            takeText: Binding(get: { controller.slateTakeFieldText },
                              set: { controller.commitSlateTakeText($0) }),
            roll: Self.templateCarriesRoll(
                controller.settings.naming.namingTemplate)
                ? nil : $controller.roll,
            onStepRoll: { controller.stepRoll($0) })
    }

    // MARK: - the two field shapes

    /// The caption over a naming field. Every field in the file-name row carries
    /// it, and they used to have a copy each — a drifted font size there shows
    /// up as rows of fields at two different heights. The slate row's captions
    /// are the same type at the same size, turned through ninety degrees (see
    /// `SlateFieldsEditor`).
    static func fieldLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .fixedSize()
            .padding(.leading, 2)
    }

    static func labeledField(_ label: String, field: NameField, width: CGFloat,
                             text: Binding<String>,
                             onCommit: @escaping () -> Void = {}) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            fieldLabel(label)
            NameTextField(field: field, text: text, onCommit: onCommit)
                .frame(width: width)
        }
        .fixedSize()
    }

    /// `canStep` is what greys the arrows out on a value they cannot move —
    /// "112A pickup" has no number and no pageable letter, so both directions
    /// are no-ops, and a control that looks live and does nothing reads on set
    /// as the app having hung: a press, a pause, and then a second press.
    ///
    /// **Both arrows or neither.** AppKit's `Stepper` cannot grey one of its
    /// two halves: the documented "pass nil to disable that button" holds on
    /// other platforms, and here it leaves an enabled `NSStepper` (measured —
    /// `isEnabled` stays true either way). So the control is disabled when
    /// NEITHER direction can do anything, which is the case that actually reads
    /// as a hang; a half-usable stepper keeps both arrows, and the one that
    /// cannot move returns the value unchanged.
    /// **Where the row's air goes**, and the two numbers are one decision.
    ///
    /// The block has a width budget it is already at — `ViewBudget
    /// .footerSideZoneWidth`, which is half a footer at the narrowest window
    /// the app allows — so a gap widened between a field and its arrows has to
    /// come from somewhere, and the row gap is where it was: at 6 points
    /// between fields and 1 inside a field, the arrows read as part of the
    /// box's own border (owner: "тут все стрелки прям вплотную к текст боксам
    /// чуть тоже дай воздуха"). Four and four puts the seam where the eye
    /// needs it — between the control and its stepper — and keeps the block
    /// inside the budget the tests hold it to. Three and four rather than four
    /// and four because the widest state of the row, the one with the
    /// name-taken triangle in it, came out one point over otherwise: that is
    /// how little slack there is, and it is why both numbers are named here
    /// instead of being literals in two files.
    static let fieldGap: CGFloat = 3
    static let stepperGap: CGFloat = 4

    static func steppedField(_ label: String, field: NameField, width: CGFloat,
                             text: Binding<String>,
                             onStep: @escaping (Int) -> Void,
                             canStep: @escaping (Int) -> Bool = { _ in true },
                             onCommit: @escaping () -> Void = {},
                             onEditingChanged: @escaping (Bool) -> Void = { _ in })
        -> some View {
        VStack(alignment: .leading, spacing: 3) {
            fieldLabel(label)
            // **Air between the box and its arrows** (owner: "тут все стрелки
            // прям вплотную к текст боксам чуть тоже дай воздуха"). At 1 point
            // the stepper read as part of the field's own border — two
            // controls with no seam between them.
            HStack(spacing: Self.stepperGap) {
                NameTextField(field: field, text: text, monospacedDigit: true,
                              onCommit: onCommit,
                              onEditingChanged: onEditingChanged)
                    .frame(width: width)
                Stepper("", onIncrement: { onStep(1) },
                        onDecrement: { onStep(-1) })
                    .labelsHidden()
                    .controlSize(.small)
                    // disabled(exception): per-FIELD, and about the field's
                    // own text rather than about app state — whether the value
                    // in THIS box has anything the arrows can page. The rule is
                    // named once, on `SlateStep.canStep`, and both rows reach it
                    // through this one builder; the controller has no opinion
                    // about a string a binding is holding.
                    .disabled(!canStep(1) && !canStep(-1))
            }
        }
        .fixedSize()
    }
}

/// What the file will be called, plus the badge that says the name is already
/// taken.
///
/// **A field is hidden by the template only when the FILE NAME is the only thing
/// that consumes it.** That is the rule the slate row below already states from
/// the other side ("scene, shot and take describe the work, not the file name"),
/// and this row used to decide the opposite way for three fields that are not
/// file-name decoration at all:
///
/// - **ROLL** is the reel, and it is the one field that MOVES rather than
///   staying or going. It is written into the take's own metadata
///   (`TakeWriter.rollKey`), into the Reel Name column of `takeshot-log.csv` and
///   the ALE, into the EDL's reel, onto the slate, and it is the key the clip
///   counter restarts on (`resetClipForRoll`) — so it must always have an
///   editor. It also has nothing to do with a name built without it: under the
///   Sony α preset (`C{clip}`) the box sat under a file name that could not
///   contain it, which is what was reported (owner: "режим сони легаси для
///   нейминга должен быть типа C0001 / а у меня остается поле ролла почему-то"
///   — and then, when it was read as "drop the reel entirely": "префикс проекта
///   в сони легаси должен оставаться я имел ввиду что в интерфейсе остается
///   текстовый бокс под название ролла"). So it is here when the template
///   names it and on the META row when it does not, through the one rule both
///   rows read — `NamingFieldsView.templateCarriesRoll`. Exactly one editor,
///   always, which is what `ViewNamingRowTests` counts.
/// - **CAM** is the camera letter: the shift report, the still's file name, the
///   multicam channel labels, the slate and the remote's camera list all read it.
/// - **CLIP** is the take number: it goes into the Take column and onto the
///   slate, and the counter keeps moving whether a placeholder shows it or not.
///
/// **POSTFIX stays gated**, because it really is filename decoration and nothing
/// else reads it — which is what makes this a rule rather than "show
/// everything". The widest state is unchanged either way: the default template
/// spends all four, which is the case `ViewFooterTests` measures.
///
/// A view of its own rather than a property of `NamingFieldsView`, and for a
/// test's sake: the collision badge has to be shown to RENDER, which used to be
/// asserted as "the block got wider". The slate row under it is the widest thing
/// in the block now, so the block's width says nothing about this row any more —
/// and a property inside another view cannot be handed to `NSHostingView`.
struct NamingFileNameRow: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        // **4pt, and the block's own gap is 6.**
        //
        // Not taste: arithmetic. The naming block cannot compress — every
        // field in it is a fixed width, so its ideal width IS its minimum —
        // and at the narrowest window it measured 298pt against the 299 there
        // are between the footer's edge and the record group's own half. The
        // block reserves the middle now like the shooting controls do
        // (`BottomBarView.centerReserve`), and this is where the points that
        // buys came from: whitespace between fields, not the boxes an
        // operator types into.
        HStack(alignment: .top, spacing: 4) {
            // **The warning that the name is already taken — a triangle, and
            // no word under it.**
            //
            // It used to stack "TAKEN" / "ЗАНЯТО" under the glyph, and that
            // cost the block 38pt in a row that has none to give: the whole
            // block reserves the middle now, and the warned state was the one
            // that could not fit. The word was also the ONE localized thing in
            // a block deliberately kept latin so the two languages measure the
            // same, and it was wider in Russian.
            //
            // Nothing is lost: the tooltip has always carried the whole
            // sentence AND the name that collides, which is the part an
            // operator actually acts on. An orange triangle in the naming row
            // has one meaning.
            if let collision = controller.nameCollision {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .padding(.top, 10)
                    .help(L("name_taken_help", collision))
                    .transition(.opacity)
            }
            NamingFieldsView.steppedField(
                L("cam_label"), field: .camera, width: 36,
                text: Binding(get: { controller.settings.naming.cameraLabel },
                              set: { controller.settings.naming.cameraLabel = $0 }),
                onStep: { controller.stepCamera($0) })
            // **Only when the NAME is built out of it** — the same rule the
            // postfix follows, and for the same reason. A preset like Sony's
            // legacy scheme names files `C0001`, so a ROLL box under the file
            // name is a box with nothing to do with the name beside it (owner:
            // "в интерфейсе остается текстовый бокс под название ролла").
            //
            // It does not vanish from the app: the reel moves to the SLATE
            // row, which is where "what was shot" lives — see
            // `SlateFieldsEditor.roll` for everything that still reads it.
            if NamingFieldsView.templateCarriesRoll(
                controller.settings.naming.namingTemplate) {
                NamingFieldsView.steppedField(
                    L("roll_label"), field: .roll, width: 46,
                    text: $controller.roll,
                    onStep: { controller.stepRoll($0) })
            }
            ClipField()
                .help(L("clip_help"))
            if uses("{postfix}") {
                NamingFieldsView.labeledField(
                    L("postfix_label"), field: .postfix, width: 48,
                    text: Binding(
                        get: { controller.settings.naming.postfix ?? "" },
                        set: { controller.settings.naming.postfix =
                            $0.isEmpty ? nil : $0 }))
            }
        }
    }

    /// Whether a placeholder is in the current template.
    private func uses(_ placeholder: String) -> Bool {
        controller.settings.naming.namingTemplate.contains(placeholder)
    }
}
