import SwiftUI

/// CLIP field: digits only, max 4; text isn't reformatted while typing,
/// commit on Enter/blur; leading zeros set the filename padding.
struct ClipField: View {
    @EnvironmentObject private var controller: CaptureController
    @FocusState private var focused: Bool
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("clip_label"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.leading, 2)
            HStack(spacing: 1) {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: 50)
                    .focused($focused)
                    .onSubmit { controller.commitClipText(text) }
                Stepper("", onIncrement: {
                    controller.nextTakeNumber = min(9999, controller.nextTakeNumber + 1)
                }, onDecrement: {
                    controller.nextTakeNumber = max(0, controller.nextTakeNumber - 1)
                })
                .labelsHidden()
                .controlSize(.small)
            }
        }
        .fixedSize()
        .onAppear { text = controller.clipDisplay }
        .onChange(of: text) { _, newValue in
            // digits only, no more than four
            let filtered = String(newValue.filter(\.isNumber).prefix(4))
            if filtered != newValue { text = filtered }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { controller.commitClipText(text) }
        }
        .onChange(of: controller.nextTakeNumber) { _, _ in
            if !focused { text = controller.clipDisplay }
        }
        .onChange(of: controller.settings.clipPadWidth) { _, _ in
            if !focused { text = controller.clipDisplay }
        }
    }
}

/// Naming fields: compact, labels above the fields on the left.
struct NamingFieldsView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        // 6pt, not the 8 this row had with four fields: the slate makes five,
        // and the row still has to fit `footerHalfWidth` with the collision
        // badge showing — see `SlateChip.width` for the measurement.
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
            // The slate is NOT gated on the template like the fields after it:
            // scene/shot/take describe what was shot, not how the file is
            // named, so they are there whether or not a placeholder uses them.
            SlateChip()
            // show only the fields that actually exist in the current template
            if uses("{cam}") {
                // camera labels are plain uppercase latin (A, B, C…): anything
                // else lands in file names on other people's systems
                steppedField(L("cam_label"), width: 40,
                             text: Binding(
                                 get: { controller.settings.cameraLabel },
                                 set: { controller.settings.cameraLabel =
                                     Self.camSanitized($0) }),
                             onStep: { controller.stepCamera($0) })
            }
            if uses("{roll}") {
                steppedField(L("roll_label"), width: 50,
                             text: $controller.roll,
                             onStep: { controller.stepRoll($0) })
            }
            if uses("{clip}") {
                ClipField()
                    .help(L("clip_help"))
            }
            if uses("{postfix}") {
                labeledField(L("postfix_label"), width: 56) {
                    TextField("", text: Binding(
                        get: { controller.settings.postfix ?? "" },
                        set: { controller.settings.postfix = $0.isEmpty ? nil : $0 }))
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: controller.nameCollision)
        .animation(.easeOut(duration: 0.15), value: controller.settings.namingTemplate)
    }

    static func camSanitized(_ value: String) -> String {
        String(value.uppercased().unicodeScalars.filter { ("A"..."Z").contains($0) })
    }

    /// Whether a placeholder is in the current template.
    private func uses(_ placeholder: String) -> Bool {
        controller.settings.namingTemplate.contains(placeholder)
    }

    /// The caption over a naming field. Both field shapes below carry it, and
    /// both had their own copy — a drifted font size there shows up as two
    /// rows of fields at two different heights.
    private func fieldLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .fixedSize()
            .padding(.leading, 2)
    }

    private func labeledField(_ label: String, width: CGFloat,
                              @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            fieldLabel(label)
            content()
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
        .fixedSize()
    }

    private func steppedField(_ label: String, width: CGFloat,
                              text: Binding<String>,
                              onStep: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            fieldLabel(label)
            HStack(spacing: 1) {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: width)
                Stepper("", onIncrement: { onStep(1) }, onDecrement: { onStep(-1) })
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
        .fixedSize()
    }
}
