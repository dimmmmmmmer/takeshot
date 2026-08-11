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
        VStack(alignment: .trailing, spacing: 5) {
            NamingFileNameRow()
            slateRow
        }
        .animation(.easeOut(duration: 0.15), value: controller.nameCollision)
        .animation(.easeOut(duration: 0.15), value: controller.settings.naming.namingTemplate)
    }

    /// What was shot. NOT gated on the template like the row above: scene, shot
    /// and take describe the work, not the file name, so they are here whether
    /// or not a placeholder uses them.
    private var slateRow: some View {
        SlateFieldsEditor(scene: $controller.scene, shot: $controller.shot,
                          takeText: Binding(
                            get: { controller.slateTakeFieldText },
                            set: { controller.commitSlateTakeText($0) }))
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

    static func steppedField(_ label: String, field: NameField, width: CGFloat,
                             text: Binding<String>,
                             onStep: @escaping (Int) -> Void,
                             onCommit: @escaping () -> Void = {},
                             onEditingChanged: @escaping (Bool) -> Void = { _ in })
        -> some View {
        VStack(alignment: .leading, spacing: 3) {
            fieldLabel(label)
            HStack(spacing: 1) {
                NameTextField(field: field, text: text, monospacedDigit: true,
                              onCommit: onCommit,
                              onEditingChanged: onEditingChanged)
                    .frame(width: width)
                Stepper("", onIncrement: { onStep(1) }, onDecrement: { onStep(-1) })
                    .labelsHidden()
                    .controlSize(.small)
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
/// - **ROLL** is the reel. It is written into the take's own metadata
///   (`TakeWriter.rollKey`), into the Reel Name column of `takeshot-log.csv` and
///   the ALE, into the EDL's reel, onto the slate, and it is the key the clip
///   counter restarts on (`resetClipForRoll`). It had exactly one editor in the
///   whole app, so choosing the Sony α preset (`C{clip}`) made all of that
///   uneditable while every one of those consumers went on writing it.
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
        HStack(alignment: .top, spacing: 6) {
            // warning: the current name is already taken in the folder
            if let collision = controller.nameCollision {
                VStack(spacing: 1) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L("name_taken_short"))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                .padding(.top, 8)
                .help(L("name_taken_help", collision))
                .transition(.opacity)
            }
            NamingFieldsView.steppedField(
                L("cam_label"), field: .camera, width: 40,
                text: Binding(get: { controller.settings.naming.cameraLabel },
                              set: { controller.settings.naming.cameraLabel = $0 }),
                onStep: { controller.stepCamera($0) })
            NamingFieldsView.steppedField(
                L("roll_label"), field: .roll, width: 50,
                text: $controller.roll,
                onStep: { controller.stepRoll($0) })
            ClipField()
                .help(L("clip_help"))
            if uses("{postfix}") {
                NamingFieldsView.labeledField(
                    L("postfix_label"), field: .postfix, width: 56,
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
