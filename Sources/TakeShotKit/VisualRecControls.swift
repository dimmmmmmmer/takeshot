import AppKit
import CaptureCore
import SwiftUI

/// The taught REC indicator's rows, in Settings → Take detection, plus the two
/// overlays teaching mode puts on the picture.
///
/// **Why Settings and not a popover over the player.** This is a detection
/// control — it belongs beside the mode picker and the confirm-frame fields it
/// shares its numbers with, and those are here. The two things it needs from the
/// picture (a click to place the box, and the box drawn while it is adjusted)
/// reach it through overlays on the viewer, which is a window of its own: the
/// operator can see the frame and the panel at the same time, which a popover
/// sitting on top of the frame could not offer.
///
/// The rows collapse to a single switch until the trigger is on or teaching mode
/// is armed, so an operator who never uses it sees one line.
struct VisualRecRows: View {
    @EnvironmentObject private var controller: CaptureController

    private var isExpanded: Bool {
        controller.visualRecOn || controller.visualRecTeachArmed
            || controller.visualRecTeaching.rolling != nil
            || controller.visualRecTeaching.idle != nil
    }

    var body: some View {
        Toggle(L("visual_rec"), isOn: Binding(
            get: { controller.visualRecOn },
            set: { controller.visualRecOn = $0 }))
            .disabled(!controller.visualRecTeaching.isTaught)
            .help(L("visual_rec_hint"))
        if isExpanded {
            teachRow
            VisualRecSliderRow(
                label: L("visual_rec_size"),
                value: Binding(get: { controller.visualRecSize },
                               set: { controller.visualRecSize = $0 }),
                range: VisualRecRegion.minSize...VisualRecRegion.maxSize,
                readout: percent(controller.visualRecSize))
            VisualRecSliderRow(
                label: L("visual_rec_margin"),
                value: Binding(get: { controller.visualRecMargin },
                               set: { controller.visualRecMargin = $0 }),
                range: 0...VisualRecTeaching.maxMargin,
                readout: percent(controller.visualRecMargin))
            learnRow
            LabeledContent(L("visual_rec_reading")) {
                Text(controller.visualRecReadingText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(controller.visualRecStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The one thing nobody may be left guessing about: this box is
            // measured and never drawn into anything that is kept.
            Text(L("visual_rec_analysis_only"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))"
    }

    /// Arming teaching mode, and forgetting a teaching that has gone stale.
    private var teachRow: some View {
        HStack(spacing: 8) {
            Button(L("visual_rec_teach")) { controller.toggleVisualRecTeach() }
                .help(L("visual_rec_teach_help"))
            if controller.visualRecTeachArmed {
                Image(systemName: "viewfinder")
                    .foregroundStyle(controller.accentColor)
                    .help(L("visual_rec_teach_armed"))
            }
            Spacer(minLength: 4)
            Button(L("visual_rec_forget"), role: .destructive) {
                controller.forgetVisualRecReferences()
            }
            .disabled(controller.visualRecTeaching.rolling == nil
                && controller.visualRecTeaching.idle == nil)
        }
    }

    /// The two captures. A tick beside each says which one is already in hand —
    /// the pair is useless until both are, and "which am I missing" is the
    /// question this row exists to answer at a glance.
    private var learnRow: some View {
        HStack(spacing: 8) {
            learnButton(L("visual_rec_learn_rolling"), which: .rolling,
                        have: controller.visualRecTeaching.rolling != nil)
            learnButton(L("visual_rec_learn_idle"), which: .idle,
                        have: controller.visualRecTeaching.idle != nil)
            Spacer(minLength: 0)
        }
    }

    private func learnButton(_ title: String, which: VisualRecReading,
                             have: Bool) -> some View {
        Button {
            controller.learnVisualRec(which)
        } label: {
            if have {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .disabled(!controller.isCapturing)
    }
}

/// One dial: a label, a mini slider and the value it is on — the same row shape
/// the chroma panel uses, with its own name because the two panels are not
/// otherwise related and a shared row would tie their layouts together.
struct VisualRecSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let readout: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $value, in: range)
                .controlSize(.mini)
            Text(verbatim: readout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

/// Teaching mode's surface on the picture: the box as it will be watched, and a
/// click anywhere that moves its centre.
///
/// A separate transparent layer rather than a gesture on the viewer surface, for
/// the reason `ChromaPickOverlay` is one: the picture already answers an ordinary
/// click by dismissing whatever panel floats over it, and the punch-in pan is a
/// drag on the same pixels. It draws and hit-tests nothing at all while teaching
/// mode is off.
struct VisualRecTeachOverlay: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        if controller.visualRecTeachArmed {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // not `Color.clear`: a fully transparent view is not hit-tested
                    Color.white.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            controller.placeVisualRecRegion(at: location,
                                                            viewport: geo.size)
                        }
                        .onHover { inside in
                            if inside {
                                NSCursor.crosshair.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    box(in: geo.size)
                }
            }
        }
    }

    /// The watched box, drawn through the SAME placement transform the renderer
    /// uses — so it sits on the pixels that are actually sampled through a
    /// desqueeze, a punch-in and a pan, and the geometry comes from
    /// `VisualRecRegion.normalizedBox`, which is also what the sampler reads.
    /// Two copies of that arithmetic is how a guide comes to lie.
    @ViewBuilder private func box(in viewport: CGSize) -> some View {
        if let placed = controller.liveAssist.placement(
            sourceSize: controller.displaySourceSize(), in: viewport) {
            let unit = controller.visualRecTeaching.region.normalizedBox
            let rect = CGRect(
                x: placed.rect.minX + unit.x * placed.rect.width,
                y: placed.rect.minY + unit.y * placed.rect.height,
                width: unit.width * placed.rect.width,
                height: unit.height * placed.rect.height)
            Rectangle()
                .strokeBorder(controller.accentColor, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }
}

/// What the REC trigger is called on screen. Here and not on the CaptureCore
/// enum — that module has no L10n.
extension RecTrigger {
    var labelKey: String { "trigger_" + rawValue }
}
