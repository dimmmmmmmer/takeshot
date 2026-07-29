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
                    if controller.settings.lutFileName != nil,
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
            lutControls.padding(14).frame(width: 240)
        }
        .fixedSize()
        .help(L("lut_help"))
    }

    /// Name of the selected LUT for the menu title (or "No LUT").
    private var currentLUTName: String {
        controller.availableLUTs
            .first { $0.fileName == controller.settings.lutFileName }?.name
            ?? L("lut_none")
    }

    @ViewBuilder private var lutControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // choosing and adding .cube in one dropdown menu (the separate import
            // button is gone: "Add .cube…" right in the list, multi-select)
            Menu {
                Button {
                    controller.selectLUT(fileName: nil)
                } label: {
                    if controller.settings.lutFileName == nil {
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
                            if controller.settings.lutFileName == lut.fileName {
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
            Toggle(L("lut_preview"), isOn: Binding(
                get: { controller.lutPreviewOn },
                set: { controller.lutPreviewOn = $0 }))
            Toggle(L("lut_record"), isOn: Binding(
                get: { controller.lutRecordOn },
                set: { controller.lutRecordOn = $0 }))
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
                .disabled(controller.settings.lutFileName == nil)
            Text("%").font(.caption).foregroundStyle(.secondary)
        }
        Slider(value: Binding(
            get: { live.lutIntensity },
            set: { controller.lutIntensity = $0 }), in: 0...1)
        .disabled(controller.settings.lutFileName == nil)
    }
}
