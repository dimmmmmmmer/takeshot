import SwiftUI

/// LUT: choose/import .cube, apply to preview/recording, intensity.
/// A Popover, not a Menu — sliders don't work in an NSMenu (intensity "hung").
struct LUTMenu: View {
    @EnvironmentObject private var controller: CaptureController
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            // same footprint as the neighbouring badge icons; the active-LUT
            // dot sits on the icon's corner instead of reserving width
            Image(systemName: "camera.filters")
                .font(.system(size: 13))
                .overlay(alignment: .topTrailing) {
                    if controller.settings.lut.fileName != nil,
                       controller.lutPreviewOn || controller.lutRecordOn {
                        Circle()
                            .fill(controller.accentColor)
                            .frame(width: 5, height: 5)
                            .offset(x: 3, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            LUTControlsPanel()
                .padding(LUTControlsPanel.padding)
                .frame(width: LUTControlsPanel.width)
        }
        .fixedSize()
        .help(L("lut_help"))
    }
}

/// Body of the LUT popover. Its own view rather than a property of the menu:
/// a popover never renders while its trigger is measured, so this is the only
/// way the localized rows inside it can be laid out and checked.
struct LUTControlsPanel: View {
    /// Popover geometry, shared with the tests that assert the Russian rows
    /// still fit inside it.
    static let width: CGFloat = 240
    static let padding: CGFloat = 14
    /// Width left for the rows themselves.
    static var contentWidth: CGFloat { width - padding * 2 }

    @EnvironmentObject private var controller: CaptureController

    /// Name of the selected LUT for the menu title (or "No LUT").
    private var currentLUTName: String {
        controller.availableLUTs
            .first { $0.fileName == controller.settings.lut.fileName }?.name
            ?? L("lut_none")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // choosing and adding .cube in one dropdown menu (the separate import
            // button is gone: "Add .cube…" right in the list, multi-select)
            Menu {
                Button {
                    controller.selectLUT(fileName: nil)
                } label: {
                    if controller.settings.lut.fileName == nil {
                        Label(L("lut_none"), systemImage: "checkmark")
                    } else {
                        Text(L("lut_none"))
                    }
                }
                if !controller.availableLUTs.isEmpty {
                    Divider()
                    ForEach(controller.availableLUTs) { lut in
                        Button {
                            controller.selectLUT(fileName: lut.fileName)
                        } label: {
                            if controller.settings.lut.fileName == lut.fileName {
                                Label(lut.name, systemImage: "checkmark")
                            } else {
                                Text(lut.name)
                            }
                        }
                    }
                }
                Divider()
                Button(L("lut_import")) { controller.importLUT() }
            } label: {
                HStack {
                    Text(currentLUTName).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            // Both gated on there BEING a look, like the same two toggles in
            // the View menu, the ⌃L key and the intensity row three lines
            // below. Ungated here they wrote "preview on" into the settings
            // over no cube at all — a stored flag claiming a look that does
            // not exist, and the one surface in the app that disagreed with
            // the other three about it. Nothing is lost: picking a look turns
            // the preview on by itself (see `selectLUT`).
            Toggle(L("lut_preview"), isOn: Binding(
                get: { controller.lutPreviewOn },
                set: { controller.lutPreviewOn = $0 }))
                .disabled(!controller.canApplyLUT)
            Toggle(L("lut_record"), isOn: Binding(
                get: { controller.lutRecordOn },
                set: { controller.lutRecordOn = $0 }))
                .disabled(!controller.canApplyLUT)
            Divider()
            LUTIntensityControls(live: controller.live)
        }
    }
}

/// Intensity row observing only LiveSignal — dragging must not re-render
/// the whole window (that read as slider lag).
private struct LUTIntensityControls: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var live: LiveSignal

    var body: some View {
        HStack(spacing: 6) {
            Text(L("lut_intensity_label")).font(.caption)
            Spacer()
            TextField("", value: Binding(
                get: { Int((live.lutIntensity * 100).rounded()) },
                set: { controller.lutIntensity = Double(min(100, max(0, $0))) / 100 }),
                format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 42)
                .disabled(!controller.canApplyLUT)
            Text("%").font(.caption).foregroundStyle(.secondary)
        }
        Slider(value: Binding(
            get: { live.lutIntensity },
            set: { controller.lutIntensity = $0 }), in: 0...1)
        .disabled(!controller.canApplyLUT)
    }
}
