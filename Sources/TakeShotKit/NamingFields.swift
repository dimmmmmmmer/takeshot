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
            .onChange(of: controller.settings.clipPadWidth) { _, _ in
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
            fileNameRow
            slateRow
        }
        .animation(.easeOut(duration: 0.15), value: controller.nameCollision)
        .animation(.easeOut(duration: 0.15), value: controller.settings.namingTemplate)
    }

    /// What the file will be called: only the fields the current template has a
    /// placeholder for.
    private var fileNameRow: some View {
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
            if uses("{cam}") {
                Self.steppedField(
                    L("cam_label"), field: .camera, width: 40,
                    text: Binding(get: { controller.settings.cameraLabel },
                                  set: { controller.settings.cameraLabel = $0 }),
                    onStep: { controller.stepCamera($0) })
            }
            if uses("{roll}") {
                Self.steppedField(L("roll_label"), field: .roll, width: 50,
                                  text: $controller.roll,
                                  onStep: { controller.stepRoll($0) })
            }
            if uses("{clip}") {
                ClipField()
                    .help(L("clip_help"))
            }
            if uses("{postfix}") {
                Self.labeledField(L("postfix_label"), field: .postfix, width: 56,
                                  text: Binding(
                                    get: { controller.settings.postfix ?? "" },
                                    set: { controller.settings.postfix =
                                        $0.isEmpty ? nil : $0 }))
            }
        }
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

    /// Whether a placeholder is in the current template.
    private func uses(_ placeholder: String) -> Bool {
        controller.settings.namingTemplate.contains(placeholder)
    }

    // MARK: - the two field shapes

    /// The caption over a naming field. Every field in both rows carries it,
    /// and they used to have a copy each — a drifted font size there shows up
    /// as rows of fields at two different heights.
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
