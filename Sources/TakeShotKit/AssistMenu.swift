import CaptureCore
import SwiftUI

/// Operator aids: exposure tools, framelines, desqueeze, punch-in.
/// A popover, not a Menu — sliders don't work inside NSMenu, and toggles
/// need to stay open for stacking tools.
struct AssistMenu: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "viewfinder")
                .font(.system(size: 13))
                .foregroundStyle(
                    controller.assist != ViewAssist()
                        || controller.settings.framelineRatio != nil
                    ? controller.accentColor : .white)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
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
    @EnvironmentObject private var hotkeys: HotkeyManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L("assist_tool"), selection: Binding(
                get: { controller.assist.colorTool },
                set: { controller.assist.colorTool = $0 })) {
                Text(L("assist_off")).tag(ViewAssist.ColorTool.off)
                Text(L("assist_false_color")).tag(ViewAssist.ColorTool.falseColor)
                Text(L("assist_el_zone")).tag(ViewAssist.ColorTool.elZone)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle(L("assist_zebra"), isOn: Binding(
                get: { controller.assist.zebraOn },
                set: { controller.assist.zebraOn = $0 }))
            if controller.assist.zebraOn {
                HStack(spacing: 6) {
                    Slider(value: Binding(
                        get: { controller.assist.zebraThreshold },
                        set: { controller.assist.zebraThreshold = $0 }),
                        in: 0.7...1.0)
                        .controlSize(.mini)
                    Text("\(Int((controller.assist.zebraThreshold * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }

            Toggle(L("assist_peaking"), isOn: Binding(
                get: { controller.assist.peakingOn },
                set: { controller.assist.peakingOn = $0 }))
            if controller.assist.peakingOn {
                HStack(spacing: 6) {
                    Slider(value: Binding(
                        get: { controller.assist.peakingIntensity },
                        set: { controller.assist.peakingIntensity = $0 }),
                        in: 2...30)
                        .controlSize(.mini)
                    Text("\(Int(controller.assist.peakingIntensity))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }

            Divider()

            Picker(L("framelines"), selection: Binding(
                get: { controller.settings.framelineRatio ?? 0 },
                set: { controller.settings.framelineRatio = $0 == 0 ? nil : $0 })) {
                Text(L("assist_off")).tag(0.0)
                Text("1.85").tag(1.85)
                Text("2.00").tag(2.0)
                Text("2.35").tag(2.35)
                Text("2.39").tag(2.39)
                Text("4:3").tag(4.0 / 3.0)
                Text("9:16").tag(9.0 / 16.0)
            }
            Toggle(L("safe_areas"), isOn: Binding(
                get: { controller.settings.safeAreasOn ?? false },
                set: { controller.settings.safeAreasOn = $0 }))

            Divider()

            Picker(L("desqueeze"), selection: Binding(
                get: { controller.assist.desqueeze },
                set: { controller.assist.desqueeze = $0 })) {
                Text(verbatim: "1x").tag(1.0)
                Text(verbatim: "1.33x").tag(1.33)
                Text(verbatim: "1.5x").tag(1.5)
                Text(verbatim: "1.8x").tag(1.8)
                Text(verbatim: "2x").tag(2.0)
            }

            Picker(L("punch_in") + " - "
                   + hotkeys.combo(for: .punchIn).display,
                   selection: Binding(
                get: { controller.assist.punchIn },
                set: {
                    controller.assist.punchIn = $0
                    if $0 == 1 {
                        controller.assist.panX = 0
                        controller.assist.panY = 0
                    }
                })) {
                Text(L("assist_off")).tag(1.0)
                Text(verbatim: "2x").tag(2.0)
                Text(verbatim: "4x").tag(4.0)
            }
            if controller.assist.punchIn > 1 {
                Text(L("punch_pan_hint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Color legend for the active exposure tool (false color / EL Zone).
struct AssistLegend: View {
    let tool: ViewAssist.ColorTool

    private var entries: [(Color, String)] {
        switch tool {
        case .falseColor:
            return [
                (Color(red: 0.58, green: 0.20, blue: 0.75), "<2"),
                (Color(red: 0.16, green: 0.34, blue: 0.90), "2-8"),
                (Color(white: 0.25), ""),
                (Color(red: 0.15, green: 0.75, blue: 0.25), "18%"),
                (Color(white: 0.55), ""),
                (Color(red: 0.95, green: 0.60, blue: 0.70), "skin"),
                (Color(white: 0.8), ""),
                (Color(red: 0.98, green: 0.90, blue: 0.20), "92-97"),
                (Color(red: 0.95, green: 0.15, blue: 0.10), "clip"),
            ]
        case .elZone:
            // the same stop palette the layer renders with (MetalPreviewLayer)
            return [
                (Color(red: 0.04, green: 0.04, blue: 0.04), "-6"),
                (Color(red: 0.45, green: 0.15, blue: 0.65), "-5"),
                (Color(red: 0.15, green: 0.25, blue: 0.90), "-4"),
                (Color(red: 0.10, green: 0.60, blue: 0.70), "-3"),
                (Color(red: 0.15, green: 0.65, blue: 0.25), "-2"),
                (Color(white: 0.32), "-1"),
                (Color(white: 0.50), "0"),
                (Color(white: 0.68), "+1"),
                (Color(red: 0.95, green: 0.60, blue: 0.65), "+2"),
                (Color(red: 0.95, green: 0.55, blue: 0.15), "+3"),
                (Color(red: 0.98, green: 0.72, blue: 0.30), "+4"),
                (Color(red: 0.98, green: 0.92, blue: 0.25), "+5"),
                (Color(white: 1), "+6"),
            ]
        case .off:
            return []
        }
    }

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                VStack(spacing: 2) {
                    Rectangle()
                        .fill(entry.0)
                        .frame(width: tool == .elZone ? 22 : 30, height: 8)
                    Text(entry.1)
                        .font(.system(size: 7).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(height: 8)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Framelines + safe areas over the aspect-fit video box.
struct FramelinesOverlay: View {
    let ratio: Double?
    let safeAreas: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                if let ratio {
                    // explicit CGFloat: the CI toolchain can't resolve the
                    // mixed Double/CGFloat arithmetic the local one accepts
                    let r = CGFloat(ratio)
                    let videoAspect = size.width / max(1, size.height)
                    let rect: CGRect = r >= videoAspect
                        ? CGRect(x: 0,
                                 y: (size.height - size.width / r) / 2,
                                 width: size.width,
                                 height: size.width / r)
                        : CGRect(x: (size.width - size.height * r) / 2,
                                 y: 0,
                                 width: size.height * r,
                                 height: size.height)
                    Path { $0.addRect(rect) }
                        .stroke(.white.opacity(0.75), lineWidth: 1)
                    // matte the outside slightly so the frame reads instantly
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: size))
                        path.addRect(rect)
                    }
                    .fill(.black.opacity(0.35), style: FillStyle(eoFill: true))
                }
                if safeAreas {
                    // safe areas live INSIDE the frameline when one is set
                    let base: CGRect = {
                        guard let ratio else {
                            return CGRect(origin: .zero, size: size)
                        }
                        let r = CGFloat(ratio)
                        let videoAspect = size.width / max(1, size.height)
                        return r >= videoAspect
                            ? CGRect(x: 0,
                                     y: (size.height - size.width / r) / 2,
                                     width: size.width,
                                     height: size.width / r)
                            : CGRect(x: (size.width - size.height * r) / 2,
                                     y: 0,
                                     width: size.height * r,
                                     height: size.height)
                    }()
                    Path { $0.addRect(base.insetBy(
                        dx: base.width * 0.05, dy: base.height * 0.05)) }
                        .stroke(.white.opacity(0.45), lineWidth: 0.7)
                    Path { $0.addRect(base.insetBy(
                        dx: base.width * 0.1, dy: base.height * 0.1)) }
                        .stroke(.white.opacity(0.3), lineWidth: 0.7)
                }
            }
        }
    }
}
