import CaptureCore
import SwiftUI

/// Operator aids: exposure tools, framelines, desqueeze, punch-in.
/// A popover, not a Menu — sliders don't work inside NSMenu, and toggles
/// need to stay open for stacking tools.
struct AssistMenu: View {
    /// Exposure metering, not a frame with corner brackets: `viewfinder` reads
    /// as "make this bigger" next to the player's own fullscreen button, and
    /// that is what the badge was being mistaken for.
    static let symbol = "camera.metering.matrix"

    @EnvironmentObject private var controller: CaptureController

    /// Whether the panel is open lives on the CONTROLLER, not in a `@State`
    /// here. The eyedropper has to be able to put it away for the duration of a
    /// click on the picture and bring it straight back (see `toggleChromaPick`),
    /// and a flag private to this view cannot be reached from there.
    private var isOpen: Binding<Bool> {
        Binding(get: { controller.showAssistPopover },
                set: { controller.showAssistPopover = $0 })
    }

    var body: some View {
        Button {
            controller.showAssistPopover.toggle()
        } label: {
            Image(systemName: Self.symbol)
                .font(.system(size: 13))
                // one question, not four: the framelines ride `assist` now, so
                // `isShowingAid` covers them (see AssistGuides)
                .foregroundStyle(controller.liveAssist.isShowingAid
                                 ? controller.accentColor : .white)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: isOpen, arrowEdge: .bottom) {
            AssistControlsPanel()
                .padding(AssistControlsPanel.padding)
                .frame(width: AssistControlsPanel.width)
        }
        .fixedSize()
        .help(L("assist_help"))
    }
}

/// Body of the assist popover. Its own view rather than a property of the menu:
/// a popover never renders while its trigger is measured, so this is the only
/// way the localized pickers inside it can be laid out and checked.
struct AssistControlsPanel: View {
    /// Popover geometry, shared with the tests that assert the Russian rows
    /// still fit inside it.
    ///
    /// 310 and not the original 260: the exposure segmented control alone
    /// cannot be squeezed below 245pt in English or 262 in Russian ("Off /
    /// False color / EL Zone (stops)"), so a 260pt popover clipped its own
    /// first row in both languages.
    static let width: CGFloat = 310
    static let padding: CGFloat = 14
    /// Width left for the rows themselves.
    static var contentWidth: CGFloat { width - padding * 2 }

    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        // the dragged values live in their own observable object (see
        // AssistLiveState): this panel follows them tick by tick, the rest of
        // the window is left alone
        AssistControlRows(live: controller.assistLive)
    }
}

private struct AssistControlRows: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager
    /// Observed but not read: the values come from `controller.liveAssist`, and
    /// this is the subscription that redraws the sliders while one is being
    /// dragged (the controller itself does not publish per tick — that is the
    /// whole point). Removing it freezes every readout mid-gesture.
    @ObservedObject var live: AssistLiveState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            exposureRows
            Divider()
            ChromaKeyRows()
            Divider()
            framingRows
            Divider()
            zoomRows
        }
    }

    // MARK: - exposure

    @ViewBuilder private var exposureRows: some View {
        ColorToolPicker(selection: Binding(
            get: { controller.liveAssist.colorTool },
            set: { tool in controller.setAssist { $0.colorTool = tool } }))
            .pickerStyle(.segmented)
            .labelsHidden()

        if controller.liveAssist.colorTool != .off {
            legendRows
        }

        Toggle(L("assist_zebra"), isOn: Binding(
            get: { controller.liveAssist.zebraOn },
            set: { on in controller.setAssist { $0.zebraOn = on } }))
        if controller.liveAssist.zebraOn {
            // the threshold is adjustable, so the label no longer claims a
            // fixed 95% — the current value is right here next to the slider
            HStack(spacing: 6) {
                Slider(value: Binding(
                    get: { controller.zebraThreshold },
                    set: { controller.zebraThreshold = $0 }),
                    in: 0.7...1.0)
                    .controlSize(.mini)
                Text(zebraReadout)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
                    .help(L("assist_zebra_hint"))
            }
        }

        Toggle(L("assist_peaking"), isOn: Binding(
            get: { controller.liveAssist.peakingOn },
            set: { on in controller.setAssist { $0.peakingOn = on } }))
        if controller.liveAssist.peakingOn {
            // sensitivity as a percentage, not the renderer's 2…30 (owner item
            // 41): the operator's question is "how much peaking", and the
            // filter's own gain units answer a different one
            HStack(spacing: 6) {
                Slider(value: Binding(
                    get: { controller.peakingPercent },
                    set: { controller.peakingPercent = $0 }),
                    in: 0...100)
                    .controlSize(.mini)
                Text("\(Int(controller.peakingPercent.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            peakingColorRow
        }
    }

    /// The peaking tint. Swatches rather than a menu of names: the choice is
    /// "which color survives against THIS subject", which the eye answers from
    /// the swatch itself — and the marker palette already set the click-a-swatch
    /// idiom in this app. The name still comes along, as the tooltip.
    private var peakingColorRow: some View {
        HStack(spacing: 8) {
            Text(L("peaking_color"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            ForEach(ViewAssist.PeakingColor.allCases, id: \.self) { color in
                let selected = controller.liveAssist.peakingColor == color
                Button {
                    controller.setAssist { $0.peakingColor = color }
                } label: {
                    Circle()
                        .fill(color.swatchColor)
                        .frame(width: 14, height: 14)
                        // the chosen swatch wears the heavier ring; the others
                        // keep a hairline so white stays visible on a light popover
                        .overlay(Circle().strokeBorder(
                            Color.primary.opacity(selected ? 0.9 : 0.25),
                            lineWidth: selected ? 2 : 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L(color.labelKey))
            }
        }
    }

    /// What the zebra threshold means, in the units the current signal is in.
    ///
    /// The tool itself is unchanged under HDR and that is a measurement rather
    /// than an omission: the display transform leaves everything below its knee
    /// as an exact ratio to diffuse white, so a zebra set at a display level
    /// still fires on the same fraction of white it always did. What DOES
    /// change is the answer to "how bright is that" — under PQ or HLG the
    /// operator wants cd/m², and 95 % of an SDR scale is not a luminance at
    /// all. So the slider keeps its position and the number beside it starts
    /// naming nits, computed by inverting the very transform the picture went
    /// through.
    private var zebraReadout: String {
        let level = controller.zebraThreshold
        guard let nits = controller.signalColorimetry.transfer
            .nits(forDisplaySignal: level) else {
            return "\(Int((level * 100).rounded()))%"
        }
        return "\(Int(nits.rounded()))\u{00A0}cd/m²"
    }

    /// Legend size and placement — only while a legend is on screen.
    @ViewBuilder private var legendRows: some View {
        Picker(L("legend_size"), selection: Binding(
            get: { controller.legendSize },
            set: { controller.legendSize = $0 })) {
            ForEach(AssistLegendSize.allCases) { size in
                Text(L(size.labelKey)).tag(size)
            }
        }
        Picker(L("legend_placement"), selection: Binding(
            get: { controller.legendPlacement },
            set: { controller.legendPlacement = $0 })) {
            ForEach(AssistLegendPlacement.allCases) { placement in
                Text(L(placement.labelKey)).tag(placement)
            }
        }
    }

    // MARK: - framing

    @ViewBuilder private var framingRows: some View {
        Picker(L("framelines"), selection: Binding(
            get: { controller.settings.assist.framelineRatio ?? 0 },
            set: { controller.settings.assist.framelineRatio = $0 == 0 ? nil : $0 })) {
            Text(L("assist_off")).tag(0.0)
            Text(verbatim: "1.85").tag(1.85)
            Text(verbatim: "2.00").tag(2.0)
            Text(verbatim: "2.35").tag(2.35)
            Text(verbatim: "2.39").tag(2.39)
            Text(verbatim: "4:3").tag(4.0 / 3.0)
            Text(verbatim: "9:16").tag(9.0 / 16.0)
        }
        Toggle(L("safe_areas"), isOn: Binding(
            get: { controller.settings.assist.safeAreasOn ?? false },
            set: { controller.settings.assist.safeAreasOn = $0 }))
        if controller.settings.assist.safeAreasOn == true {
            safePercentRow(L("safe_action"), value: Binding(
                get: { controller.settings.assist.safeActionPercentEffective },
                set: { controller.settings.assist.safeActionPercent = $0 }))
            safePercentRow(L("safe_title"), value: Binding(
                get: { controller.settings.assist.safeTitlePercentEffective },
                set: { controller.settings.assist.safeTitlePercent = $0 }))
        }
    }

    /// A safe-area margin. Stepped by a whole percent on purpose: the value is
    /// persisted, and a stepped slider writes settings once per percent crossed
    /// instead of once per pointer move (the guides still follow the drag).
    private func safePercentRow(_ label: String,
                                value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: value, in: 70...100, step: 1)
                .controlSize(.mini)
            Text("\(Int(value.wrappedValue))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    // MARK: - desqueeze and zoom

    @ViewBuilder private var zoomRows: some View {
        Picker(L("desqueeze"), selection: Binding(
            get: { controller.liveAssist.desqueeze },
            set: { factor in controller.setAssist { $0.desqueeze = factor } })) {
            Text(verbatim: "1x").tag(1.0)
            Text(verbatim: "1.33x").tag(1.33)
            Text(verbatim: "1.5x").tag(1.5)
            Text(verbatim: "1.8x").tag(1.8)
            Text(verbatim: "2x").tag(2.0)
        }

        HStack(spacing: 6) {
            Text(L("punch_in"))
            Spacer(minLength: 4)
            Text(hotkeys.combo(for: .punchIn).display)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack(spacing: 6) {
            // continuous: the pinch gesture works in fractions of a stop of
            // magnification, and the slider has to be able to land on them
            Slider(value: Binding(
                get: { controller.punchInLevel },
                set: { controller.punchInLevel = $0 }),
                in: ViewAssist.minPunchIn...ViewAssist.maxPunchIn)
                .controlSize(.mini)
            // 40 and not 34: the ceiling is 10x now, and "10.0x" does not fit
            // the width one digit of magnification was sized for
            Text(verbatim: String(format: "%.1fx", controller.punchInLevel))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                // 40, not 34: the ceiling is 10× now and "10.0×" needs the room
                .frame(width: 40, alignment: .trailing)
        }
        // (the "drag to pan, pinch to zoom" line that used to sit here is gone:
        // dragging a punched-in image is not something an operator needs told)
    }
}

/// The UI face of the peaking palette: the localized name (the swatch tooltip)
/// and the SwiftUI color the swatch wears. Lives here and not on the CaptureCore
/// enum — that module has no L10n and no SwiftUI.
extension ViewAssist.PeakingColor {
    var labelKey: String { "peaking_color_" + rawValue }

    var swatchColor: Color {
        let tint = components
        return Color(red: tint.red, green: tint.green, blue: tint.blue)
    }
}
