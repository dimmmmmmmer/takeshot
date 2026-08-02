import CaptureCore
import SwiftUI

/// The slate group in the footer's naming row: a compact chip carrying
/// scene/shot/take, opening a popover with the three fields.
///
/// A chip and not three inline boxes, and that is a measurement, not a taste.
/// The naming row has to fit `footerHalfWidth` (726/2 pt at the app's minimum
/// window), and CAM + ROLL + CLIP + POSTFIX already spend most of it — three
/// more labelled fields overflow the half and push the centered REC button off
/// center, which is exactly the failure `ViewFooterTests` exists to catch. The
/// chip is one field's worth of width, shows the current slate at a glance
/// (which is what an operator glances at the footer FOR), and puts the typing
/// one click away where there is room for proper labels.
///
/// Its own width is fixed rather than fitted: the value is operator-typed, and
/// a row that changes width with the scene name is a row that shifts the record
/// button every time somebody types.
struct SlateChip: View {
    @EnvironmentObject private var controller: CaptureController
    @State private var showPopover = false

    /// Measured, not chosen: 44pt is what the naming row can give up and still
    /// fit `footerHalfWidth` with the collision badge showing (the row lands at
    /// 352 of 363 with this and the 6pt inter-field spacing beside it). Eight
    /// characters of 9pt monospaced text, which is exactly "12A/B T3" — what a
    /// slate looks like on a normal day. Anything longer truncates and the
    /// popover has the full value.
    static let width: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Latin and unlocalized, like CAM/ROLL/CLIP beside it: the footer
            // must measure identically in both languages.
            Text(L("slate_label"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.leading, 2)
            Button {
                showPopover = true
            } label: {
                Text(controller.slateDisplay)
                    .font(.system(size: 9, weight: .medium,
                                  design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: Self.width, height: 19)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.secondary.opacity(0.35)))
            .help(L("slate_help"))
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                SlatePopover()
                    .environmentObject(controller)
            }
        }
        .frame(width: Self.width)
    }
}

/// What the chip opens: the slate for the NEXT take.
private struct SlatePopover: View {
    @EnvironmentObject private var controller: CaptureController
    @State private var takeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SlateFieldsEditor(scene: $controller.scene, shot: $controller.shot,
                              takeText: $takeText)
            Text(L("slate_next_hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 250, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .onAppear { takeText = takeFieldText }
        // The number can move without this popover: a landed take advances it,
        // and a scene change restarts it. Mirror that back into the field
        // unless the operator is mid-edit of it.
        .onChange(of: controller.slateTakeNumber) { _, _ in
            takeText = takeFieldText
        }
        .onChange(of: takeText) { _, newValue in
            let filtered = String(newValue.filter(\.isNumber).prefix(4))
            if filtered != newValue { takeText = filtered }
            controller.commitSlateTakeText(filtered)
        }
    }

    /// An unlogged take number shows as an empty field, not as a 0: the field
    /// being blank is how the operator sees that numbering is still following
    /// the clip counter.
    private var takeFieldText: String {
        controller.slateTakeNumber > 0 ? String(controller.slateTakeNumber) : ""
    }
}

/// Scene / shot / take over whatever bindings the caller owns — the footer's
/// popover drives the slate of the next take, the takes panel drives one
/// recorded take's copy. One layout, so the two can never grow apart.
struct SlateFieldsEditor: View {
    @Binding var scene: String
    @Binding var shot: String
    /// The take number as typed. Text rather than Int so an emptied field can
    /// mean "not logged" — a numeric binding has no way to say that.
    @Binding var takeText: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            field(L("scene"), width: 90, text: $scene)
            field(L("slate_shot"), width: 60, text: $shot)
            field(L("slate_take"), width: 50, text: $takeText)
                .help(L("slate_take_help"))
        }
    }

    private func field(_ label: String, width: CGFloat,
                       text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.leading, 2)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
        .fixedSize()
    }
}
