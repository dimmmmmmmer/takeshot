import CaptureCore
import SwiftUI

/// **Where the picture is, at what size, and which way up** — the nine
/// controls a colourist has under "Sizing" in Resolve, as a popover beside the
/// aids.
///
/// `PictureSizing` has understood all nine since it existed and the app could
/// only ever set four of them: the desqueeze, the punch-in and its pan. The
/// other five — height, rotate, pitch, yaw and the two flips — were a
/// capability the renderer had and nothing could reach. This is the reach.
///
/// **Its own popover and not a section of the aids'**, for two reasons. The
/// aids' panel is already at the file length this project holds itself to, and
/// — the one that matters — these are not AIDS: an aid is drawn over the
/// picture to help somebody judge it, and every control here MOVES the
/// picture. An operator looking for "why is the frame crooked" should not have
/// to find it under false colour.
struct SizingMenu: View {
    /// A frame with handles: what Resolve puts on the same controls, and not
    /// a magnifier — the punch-in is one of nine things in here.
    static let symbol = "crop"

    @EnvironmentObject private var controller: CaptureController

    private var isOpen: Binding<Bool> {
        Binding(get: { controller.showSizingPopover },
                set: { controller.showSizingPopover = $0 })
    }

    var body: some View {
        Button {
            controller.showSizingPopover.toggle()
        } label: {
            Image(systemName: Self.symbol)
                .font(.system(size: 13))
                .foregroundStyle(controller.liveAssist.sizing.isIdentity
                                 ? .white : controller.accentColor)
                // The same dot the aids and the look wear, and the same
                // reason: a tint alone is two shades of a 13pt glyph across a
                // room, over a picture (owner: "давай когда у нас какая-то
                // операторская помощь включена будем точку рисовать рядом с
                // этой кнопкой как когда лут включен").
                .overlay(alignment: .topTrailing) {
                    if !controller.liveAssist.sizing.isIdentity {
                        Circle()
                            .fill(controller.accentColor)
                            .frame(width: 5, height: 5)
                            .offset(x: 3, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .popover(isPresented: isOpen, arrowEdge: .bottom) {
            SizingControlsPanel()
                .padding(AssistControlsPanel.padding)
                .frame(width: AssistControlsPanel.width)
        }
        .fixedSize()
        .help(L("sizing_help"))
    }
}

/// The controls themselves.
///
/// Every row is a slider with a readout and a double-click-to-reset, because
/// that is what these are used like: an operator nudges a rotation to level a
/// horizon and then wants the number back. The two flips are checkboxes —
/// there is nothing to nudge about a flip.
struct SizingControlsPanel: View {
    @EnvironmentObject private var controller: CaptureController

    /// What each slider spans and what "off" is for it.
    ///
    /// The ranges are the clamps `AssistSettings` reads a stored value
    /// through, so a value typed here and a value read back from a blob can
    /// never disagree about what is allowed.
    static let heightRange = 0.25...4.0
    static let rotationRange = -180.0...180.0
    static let tiltRange = -45.0...45.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("sizing_title")).font(.headline)
            row(L("sizing_height"), value: binding(\.height),
                range: Self.heightRange, neutral: 1, format: "%.2f")
            row(L("sizing_rotation"), value: binding(\.rotation),
                range: Self.rotationRange, neutral: 0, format: "%.1f°")
            row(L("sizing_pitch"), value: binding(\.pitch),
                range: Self.tiltRange, neutral: 0, format: "%.1f°")
            row(L("sizing_yaw"), value: binding(\.yaw),
                range: Self.tiltRange, neutral: 0, format: "%.1f°")
            HStack(spacing: 12) {
                Toggle(L("sizing_flip_h"), isOn: flip(\.flipH))
                Toggle(L("sizing_flip_v"), isOn: flip(\.flipV))
            }
            .toggleStyle(.checkbox)
            // **A pitch or a yaw costs the eyedropper**, and saying so here is
            // the only place an operator can find that out: the transform
            // stops being affine, so a pick from the picture cannot be run
            // backwards onto a source pixel and is refused rather than landing
            // on the wrong one (`PictureSizing.isAffine`).
            if !controller.liveAssist.sizing.isAffine {
                Text(L("sizing_not_affine"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(L("sizing_reset")) { controller.resetSizing() }
                .buttonStyle(.link)
                .disabled(!controller.canResetSizing)
        }
    }

    @ViewBuilder
    private func row(_ label: String, value: Binding<Double>,
                     range: ClosedRange<Double>, neutral: Double,
                     format: String) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 48, alignment: .trailing)
            Button {
                value.wrappedValue = neutral
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.hoverPlain)
            // disabled(exception): this asks about the ROW's own slider, not
            // about the session — one control already at its neutral value,
            // which is a fact of the binding and has no rule to name on the
            // controller.
            .disabled(value.wrappedValue == neutral)
            .help(L("sizing_reset_one"))
        }
    }

    /// One field of the live assist, written back through the controller so
    /// the change reaches the pipeline, the settings and the scopes' region by
    /// the one path they all already use.
    private func binding(_ path: WritableKeyPath<ViewAssist, Double>)
        -> Binding<Double> {
        Binding(get: { controller.assist[keyPath: path] },
                set: { controller.assist[keyPath: path] = $0 })
    }

    private func flip(_ path: WritableKeyPath<ViewAssist, Bool>) -> Binding<Bool> {
        Binding(get: { controller.assist[keyPath: path] },
                set: { controller.assist[keyPath: path] = $0 })
    }
}
