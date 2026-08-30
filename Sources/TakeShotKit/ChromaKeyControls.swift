import AppKit
import CaptureCore
import SwiftUI

/// The chroma-key rows of the assist popover: the switch, the screen color and
/// how it is chosen, the three dials, and what goes behind the actor.
///
/// Its own file rather than another block inside `AssistMenu`: that view is the
/// exposure/framing/zoom panel and was already the longest one in the app, and
/// this section has a mode of its own (the eyedropper) that reaches out onto
/// the picture. The plate's own rows are `ChromaPlateControls`.
struct ChromaKeyRows: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Toggle(L("chroma_key"), isOn: Binding(
            get: { controller.chromaKeyOn },
            set: { on in controller.chromaKeyOn = on }))
        if controller.chromaKeyOn {
            screenColorRow
            percentRow(L("chroma_tolerance"),
                       value: Binding(get: { controller.chromaTolerance },
                                      set: { controller.chromaTolerance = $0 }),
                       range: 0...ChromaKey.maxTolerance)
            percentRow(L("chroma_softness"),
                       value: Binding(get: { controller.chromaSoftness },
                                      set: { controller.chromaSoftness = $0 }),
                       range: 0...ChromaKey.maxSoftness)
            percentRow(L("chroma_spill"),
                       value: Binding(get: { controller.chromaSpill },
                                      set: { controller.chromaSpill = $0 }),
                       range: 0...1)
            backgroundRows
            bakeRow
        }
    }

    /// The bake, and the sentence that has to go with whichever way it is set.
    ///
    /// The note is not decoration and it is not the same note in two moods: with
    /// the bake off it says where this picture goes (the director's monitor too,
    /// and no file), and with it on it says what the next take BECOMES — a
    /// composite that is not camera original, whose scopes are still measuring
    /// the camera rather than the file. That second sentence is the only warning
    /// an operator gets before a day's footage cannot be re-keyed.
    @ViewBuilder private var bakeRow: some View {
        Toggle(L("chroma_record"), isOn: Binding(
            get: { controller.chromaRecordOn },
            set: { on in controller.chromaRecordOn = on }))
            .disabled(!controller.canBakeChromaKey)
        Text(controller.chromaRecordOn
            ? L("chroma_record_warning") : L("chroma_preview_only"))
            .font(.caption2)
            .foregroundStyle(controller.chromaRecordOn ? .orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One of the three dials the operator reads as a percentage of its own
    /// travel — tolerance, softness, spill.
    ///
    /// The three share a helper rather than each naming
    /// `ChromaSliderReadout.percentOfTravel` for themselves, and that is the
    /// same lesson one turn further on: which KIND of readout a dial gets is
    /// still a per-call-site choice, and a call site given the wrong one reads
    /// "+30" where it should read "50". Nothing can catch that — the readout
    /// sits in a fixed-width column, so it does not move a measurable size, and
    /// ink is not portable between the runner and this Mac (see
    /// `ViewRenderSupport`). One site that can be wrong instead of three is what
    /// is available; docs/coverage.md carries it as a stated limit.
    private func percentRow(_ label: String, value: Binding<Double>,
                            range: ClosedRange<Double>) -> some View {
        ChromaSliderRow(label: label, value: value, range: range,
                        readout: .percentOfTravel)
    }

    /// The screen color: what it is now, the eyedropper that takes it off the
    /// picture, the two presets, and a field to type one in.
    private var screenColorRow: some View {
        HStack(spacing: 8) {
            Text(L("chroma_screen"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button {
                controller.toggleChromaPick()
            } label: {
                Image(systemName: "eyedropper")
                    .font(.system(size: 12))
                    .foregroundStyle(controller.chromaPickArmed
                        ? controller.accentColor : Color.primary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("chroma_pick_help"))
            preset(ChromaKey.greenScreen, help: L("chroma_preset_green"))
            preset(ChromaKey.blueScreen, help: L("chroma_preset_blue"))
            ChromaColorField(color: Binding(
                get: { controller.chroma.keyColor },
                set: { controller.setChromaScreen($0) }))
        }
    }

    /// A screen preset. Swatches like the peaking palette next door — the crew
    /// calls the cyc "the green" or "the blue", and that is the whole choice.
    private func preset(_ color: ChromaKey.RGB, help: String) -> some View {
        let selected = controller.chroma.keyColor == color
        return Button {
            controller.setChromaScreen(color)
        } label: {
            Circle()
                .fill(Color(color))
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(
                    Color.primary.opacity(selected ? 0.9 : 0.25),
                    lineWidth: selected ? 2 : 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder private var backgroundRows: some View {
        Picker(L("chroma_background"), selection: Binding(
            get: { controller.chromaBackground },
            set: { controller.chromaBackground = $0 })) {
            ForEach(ChromaKey.Background.allCases, id: \.self) { background in
                Text(L(background.labelKey)).tag(background)
            }
        }
        switch controller.chromaBackground {
        case .color:
            HStack(spacing: 8) {
                Text(L("chroma_background_color"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ChromaColorField(color: Binding(
                    get: { controller.chromaBackgroundRGB },
                    set: { controller.chromaBackgroundRGB = $0 }))
            }
        case .image:
            ChromaPlateControls()
        case .checkerboard, .matte:
            EmptyView()
        }
    }
}

/// A color the operator can set without the popover closing under them.
///
/// This was a SwiftUI `ColorPicker`, and clicking it opened the system color
/// panel — a window of its own, which takes key away from the popover, and a
/// popover that loses key dismisses. So picking the screen color shut the panel
/// every single time (owner item 30). There is no supported way to make a
/// SwiftUI popover survive that, so the color well went instead: a swatch and
/// the hex the rest of this app already speaks, both inside the popover, plus
/// the eyedropper and the two presets beside them — which is how a screen color
/// is actually chosen anyway.
struct ChromaColorField: View {
    @Binding var color: ChromaKey.RGB
    /// What is being typed. Kept apart from the color so that a half-typed
    /// "#0F" does not repaint the picture as it is entered.
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(color))
                .frame(width: 22, height: 14)
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary.opacity(0.25)))
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .controlSize(.mini)
                .frame(width: 64)
                .focused($editing)
                .onSubmit(commit)
                .onChange(of: editing) { _, focused in
                    if !focused { commit() }
                }
        }
        .onAppear { text = color.hexString }
        .onChange(of: color) { _, value in
            // do not fight the operator's cursor: a pick or a preset landing
            // while the field is being typed in is the only case that repaints
            if !editing { text = value.hexString }
        }
    }

    private func commit() {
        let outcome = Self.committed(text: text, current: color)
        color = outcome.color
        text = outcome.text
    }

    /// What committing `text` over `current` leaves behind: the color the keyer
    /// adopts, and the text the field is left showing.
    ///
    /// A function rather than four lines inside the view, because this is the
    /// only decision in the field and it was unreachable: `commit()` is private
    /// to a body SwiftUI does not build until the popover is presented, and it
    /// is reached from `onSubmit` and from focus LEAVING the field — neither of
    /// which a headless render performs.
    ///
    /// Two claims, and the second is the one worth writing down:
    ///
    /// - **An unparseable hex is put back rather than swallowed.** A field
    ///   keeping a value nothing on screen matches is worse than one that
    ///   reverts — the operator would be reading a screen colour the keyer is
    ///   not using.
    /// - **A parseable one is normalized, not echoed.** `abcdef` and `#ABCDEF`
    ///   are the same colour and the field settles on one spelling of it, so
    ///   what is on screen is what `hexString` would print for the colour the
    ///   keyer actually holds. That is what makes this an inverse of the
    ///   `onChange` above, which writes `value.hexString` into the same field.
    static func committed(text: String,
                          current: ChromaKey.RGB) -> (color: ChromaKey.RGB,
                                                      text: String) {
        let color = ChromaKey.RGB(hex: text) ?? current
        return (color, color.hexString)
    }
}

/// The plate rows: which file is behind the actor, and where it sits.
///
/// Split from `ChromaKeyRows` because it is a section rather than a row — the
/// plate has a source, a fit, a scale and two offsets, and none of them mean
/// anything unless the background is set to the image.
struct ChromaPlateControls: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        plateRow
        Picker(L("chroma_plate_fit"), selection: Binding(
            get: { controller.chromaPlateFit },
            set: { controller.chromaPlateFit = $0 })) {
            ForEach(ChromaKey.PlateFit.allCases, id: \.self) { fit in
                Text(L(fit.labelKey)).tag(fit)
            }
        }
        ChromaSliderRow(
            label: L("chroma_plate_scale"),
            value: Binding(get: { controller.chromaPlateScale },
                           set: { controller.chromaPlateScale = $0 }),
            range: ChromaKey.PlateLayout.minScale...ChromaKey.PlateLayout.maxScale,
            readout: .multiplier)
        offsetRow(L("chroma_plate_offset_x"),
                  value: Binding(get: { controller.chromaPlateOffsetX },
                                 set: { controller.chromaPlateOffsetX = $0 }))
        offsetRow(L("chroma_plate_offset_y"),
                  value: Binding(get: { controller.chromaPlateOffsetY },
                                 set: { controller.chromaPlateOffsetY = $0 }))
    }

    /// The plate: which file, chosen from the app's own media or off disk.
    private var plateRow: some View {
        HStack(spacing: 6) {
            Menu {
                Button(L("chroma_choose_file")) {
                    controller.chooseChromaBackgroundImage()
                }
                if controller.chromaBackgroundImageName != nil {
                    Button(L("chroma_clear_image")) {
                        controller.clearChromaBackgroundImage()
                    }
                }
                MediaSourceMenuItems(groups: controller.chromaPlateSources,
                                     selection: nil) { url in
                    controller.loadChromaBackground(mediaURL: url)
                }
            } label: {
                Text(controller.chromaBackgroundImageName ?? L("chroma_no_image"))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            Spacer(minLength: 2)
            Button {
                controller.resetChromaPlate()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(!controller.chromaPlateIsAdjusted)
            .help(L("chroma_plate_reset"))
        }
    }

    /// An offset, in percent of the frame. Signed on purpose: the operator has
    /// to be able to see which way it has gone without watching the picture.
    private func offsetRow(_ label: String,
                           value: Binding<Double>) -> some View {
        let limit = ChromaKey.PlateLayout.maxOffset
        return ChromaSliderRow(
            label: label, value: value, range: -limit...limit,
            readout: .signedPercentOfFrame)
    }
}

/// One dial: a label, a mini slider and the value it is on. These rows carry
/// percentages, multipliers and signed offsets, so the KIND of readout is given
/// — but the text itself is derived here, from the same range the slider is
/// laid out on, because the row is the one place that holds both. Handing the
/// row a finished string beside the range is what let the two disagree; see
/// `ChromaSliderReadout`. The fixed width is what keeps the slider from jumping
/// as the number grows a digit.
struct ChromaSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let readout: ChromaSliderReadout

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $value, in: range)
                .controlSize(.mini)
            Text(verbatim: readout.text(for: value, in: range))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

/// The eyedropper's own surface: while it is armed, a click anywhere on the
/// picture takes the screen color from under the pointer.
///
/// A separate transparent layer rather than a gesture on the viewer surface, so
/// that arming the pick cannot change what an ordinary click does the rest of
/// the time — the picture already answers a click by dismissing whatever panel
/// is floating over it, and the punch-in pan is a drag on the same pixels.
struct ChromaPickOverlay: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        if controller.chromaPickArmed {
            GeometryReader { geo in
                // not `Color.clear`: a fully transparent view is not hit-tested
                Color.white.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        controller.pickChromaKeyColor(at: location,
                                                      viewport: geo.size)
                    }
                    .onHover { inside in
                        if inside {
                            PickerCursor.eyedropper.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            }
        }
    }
}

/// The UI face of the background choices. Here and not on the CaptureCore enum
/// — that module has no L10n.
extension ChromaKey.Background {
    var labelKey: String {
        switch self {
        case .checkerboard: return "chroma_bg_checker"
        case .color: return "chroma_bg_color"
        case .image: return "chroma_bg_image"
        case .matte: return "chroma_bg_matte"
        }
    }
}

extension ChromaKey.PlateFit {
    var labelKey: String {
        switch self {
        case .fit: return "chroma_plate_fit_fit"
        case .fill: return "chroma_plate_fit_fill"
        case .stretch: return "chroma_plate_fit_stretch"
        }
    }
}
