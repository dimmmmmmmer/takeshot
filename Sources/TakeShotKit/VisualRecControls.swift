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
/// The rows collapse to the switch and the way IN — two lines — until the
/// trigger is on or teaching mode is armed, so an operator who never uses it is
/// not carrying the dials.
///
/// **Two lines and not one, which is the whole feature.** The teach row is the
/// only caller of `toggleVisualRecTeach()` anywhere in the app, so it is the
/// only thing that can put a first reference in hand; it used to sit behind
/// `isExpanded`, which is false on a fresh install precisely because nothing has
/// been taught yet. A greyed switch and nothing else was the entire feature as
/// shipped, and no test caught it because the suites drive the controller
/// directly and only ever measured how WIDE the rows were. The switch stays
/// disabled until the pair separates — that part was right, and the setter
/// enforces it anyway (see `visualRecOn`) — but "cannot be switched on yet" and
/// "cannot be reached at all" are different statements and the panel now makes
/// only the first one.
struct VisualRecRows: View {
    @EnvironmentObject private var controller: CaptureController

    /// Shown when the operator has CHOSEN this mode, whether or not the box has
    /// been taught yet.
    ///
    /// It used to expand on `visualRecOn`, which cannot be true until the box
    /// is taught — and the teaching rows were inside the expansion. The key was
    /// inside the lock, the same shape as the reference pin and the taught REC
    /// indicator before it. Choosing the mode is now what opens the rows, so an
    /// untaught install has somewhere to start.
    private var isExpanded: Bool {
        controller.settings.capture.detectionMode == .visual
            || controller.visualRecTeachArmed
            || controller.visualRecTeaching.rolling != nil
            || controller.visualRecTeaching.idle != nil
    }

    var body: some View {
        // No switch of its own: the mode picker above IS the switch
        // (see `RecDetectionMode.visual`).
        if isExpanded {
            VisualRecTeachRow()
            VisualRecSliderRow(
                label: L("visual_rec_width"),
                value: Binding(get: { controller.visualRecWidth },
                               set: { controller.visualRecWidth = $0 }),
                range: VisualRecRegion.minSize...VisualRecRegion.maxSize,
                readout: percent(controller.visualRecWidth))
            VisualRecSliderRow(
                label: L("visual_rec_height"),
                value: Binding(get: { controller.visualRecHeight },
                               set: { controller.visualRecHeight = $0 }),
                range: VisualRecRegion.minSize...VisualRecRegion.maxSize,
                readout: percent(controller.visualRecHeight))
            // The margin is DERIVED from the taught separation and is shown
            // rather than set (see `VisualRecTeaching.margin`). Shown at all
            // because it is the number that explains a trigger's behaviour: a
            // marginal teach demands nearly the whole separation, and knowing
            // that is what tells an operator to re-teach rather than to fiddle.
            LabeledContent(L("visual_rec_margin")) {
                Text(verbatim: percent(controller.visualRecMargin))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
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

/// Arming teaching mode, and forgetting a teaching that has gone stale.
///
/// A view of its own rather than a computed property on `VisualRecRows`, and
/// that is a test's requirement rather than a layout's: this row is the door
/// into the whole feature, and a suite that can only measure the rows as a block
/// cannot say whether the door is in them. `ViewVisualRecTests` measures it
/// separately and holds the untaught panel against switch + door.
struct VisualRecTeachRow: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
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
            .disabled(!controller.hasVisualRecReferences)
        }
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
                        // Dragging, because tapping was the ONLY way to move
                        // the box and nothing said so (owner: "бокс не могу
                        // никуда подвинуть"). A guide you place by clicking
                        // somewhere else is not how a box on a picture behaves;
                        // every operator tries to drag it first, gets nothing,
                        // and concludes it is fixed.
                        //
                        // The same setter as the tap, so the clamp and the
                        // placement transform are still stated once —
                        // `minimumDistance: 0` so a press that turns into a
                        // drag does not need a threshold first, and the tap
                        // above still answers a click that never moves.
                        // **Drag DRAWS the box; a click still moves it.**
                        //
                        // The crosshair says a region can be drawn here, and
                        // until now it could not — the drag moved the centre,
                        // which is a different gesture wearing the same cursor.
                        // Both live in one controller method, which decides
                        // between them on the size of the band: under the
                        // floor it is a click and moves the centre, so a
                        // twitch cannot replace a taught shape.
                        //
                        // Live during the drag rather than on release: an
                        // operator sizing a box against a camera's REC dot is
                        // watching the box, and a rectangle that only appears
                        // when the mouse comes up cannot be aimed.
                        .gesture(DragGesture(minimumDistance: 0,
                                             coordinateSpace: .local)
                            .onChanged { value in
                                controller.drawVisualRecRegion(
                                    from: value.startLocation,
                                    to: value.location, viewport: geo.size)
                            })
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
