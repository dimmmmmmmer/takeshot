import AppKit
import CaptureCore
import SwiftUI

/// The chroma-key rows of the assist popover: the switch, the screen color and
/// how it is chosen, the three dials, and what goes behind the actor.
///
/// Its own file rather than another block inside `AssistMenu`: that view is the
/// exposure/framing/zoom panel and was already the longest one in the app, and
/// this section has a mode of its own (the eyedropper) that reaches out onto
/// the picture.
struct ChromaKeyRows: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Toggle(L("chroma_key"), isOn: Binding(
            get: { controller.chromaKeyOn },
            set: { on in controller.chromaKeyOn = on }))
        if controller.chromaKeyOn {
            screenColorRow
            ChromaSliderRow(label: L("chroma_tolerance"),
                            value: Binding(get: { controller.chromaTolerance },
                                           set: { controller.chromaTolerance = $0 }),
                            range: 0...ChromaKey.maxTolerance)
            ChromaSliderRow(label: L("chroma_softness"),
                            value: Binding(get: { controller.chromaSoftness },
                                           set: { controller.chromaSoftness = $0 }),
                            range: 0...ChromaKey.maxSoftness)
            ChromaSliderRow(label: L("chroma_spill"),
                            value: Binding(get: { controller.chromaSpill },
                                           set: { controller.chromaSpill = $0 }),
                            range: 0...1)
            backgroundRows
            // The one thing nobody may be left guessing about: this picture is
            // on the director's monitor too, and it is in no file anywhere.
            Text(L("chroma_preview_only"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The screen color: what it is now, the eyedropper that takes it off the
    /// picture, the two presets, and a well for typing one in.
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
            ColorPicker("", selection: Binding(
                get: { controller.chromaKeyColor },
                set: { controller.chromaKeyColor = $0 }))
                .labelsHidden()
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
            ColorPicker(L("chroma_background_color"), selection: Binding(
                get: { controller.chromaBackgroundColor },
                set: { controller.chromaBackgroundColor = $0 }))
        case .image:
            plateRow
        case .checkerboard, .matte:
            EmptyView()
        }
    }

    /// The plate: the file behind the actor, or the offer to go and find one.
    private var plateRow: some View {
        HStack(spacing: 6) {
            Button(L("chroma_choose_image")) {
                controller.chooseChromaBackgroundImage()
            }
            .controlSize(.small)
            Text(controller.chromaBackgroundImageName ?? L("chroma_no_image"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if controller.chromaBackgroundImageName != nil {
                Button {
                    controller.clearChromaBackgroundImage()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("chroma_clear_image"))
            }
        }
    }
}

/// One dial: a label, a mini slider and the value it is on. The three chroma
/// controls are the same row three times, and the readout width is what keeps
/// the slider from jumping as the number grows a digit.
private struct ChromaSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $value, in: range)
                .controlSize(.mini)
            Text(verbatim: "\(Int((value * 100).rounded()))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
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
                            NSCursor.crosshair.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .overlay(alignment: .top) {
                        Text(L("chroma_pick_hint"))
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.6),
                                        in: Capsule())
                            .foregroundStyle(.white)
                            .padding(.top, 44)
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
