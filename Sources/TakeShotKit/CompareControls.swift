import SwiftUI

/// Live/playback compare controls.
struct CompareControls: View {
    /// Tighter than the shared plate inset: this is a row of six controls that
    /// carry their own margins, and the full 8pt a side pushed it into the badge
    /// groups it is centered between at the narrowest window.
    static let platePadding: CGFloat = 5

    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $controller.compareMode) {
                Text(controller.viewerMode == .record && controller.referencePinned
                     ? L("compare_source") : L("compare_off"))
                    .tag(CaptureController.CompareMode.off)
                Text(L("compare_wipe")).tag(CaptureController.CompareMode.wipe)
                Text(L("compare_blend")).tag(CaptureController.CompareMode.blend)
                Text(L("compare_difference"))
                    .tag(CaptureController.CompareMode.difference)
                Text(L("compare_side")).tag(CaptureController.CompareMode.sideBySide)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .controlSize(.mini)

            if controller.compareMode == .wipe {
                Picker("", selection: $controller.wipeOrientation) {
                    Image(systemName: "rectangle.split.2x1")
                        .tag(CaptureController.WipeOrientation.vertical)
                        .help(L("wipe_vertical"))
                    Image(systemName: "rectangle.split.1x2")
                        .tag(CaptureController.WipeOrientation.horizontal)
                        .help(L("wipe_horizontal"))
                    Image(systemName: "line.diagonal")
                        .tag(CaptureController.WipeOrientation.diagonal)
                        .help(L("wipe_diagonal"))
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                .controlSize(.mini)
            }
            // The wipe has its seam and the blend its slider; difference has
            // its gain — the same control family, in the same slot. No wipe
            // position anywhere near it: a seam through |A−B| means nothing.
            if controller.compareMode == .difference {
                Picker("", selection: $controller.differenceGain) {
                    ForEach(CaptureController.DifferenceGain.allCases) { gain in
                        Text(gain.label).tag(gain)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                .controlSize(.mini)
                .help(L("difference_gain_help"))
            }
            // The B-side menu belongs to an ENGAGED compare (it names the other
            // half), so the resting bar goes without it: with five modes in the
            // picker, the off state has to fit the centered slot between the
            // badge groups, and the menu is what it can spare — engaging any
            // mode brings it back, and picking a B clip arms the wipe anyway.
            // It stays while a B clip is chosen with the compare off, so the
            // choice never becomes invisible.
            if controller.viewerMode == .playback,
               controller.rawPlayer == nil,
               controller.compareMode != .off || controller.compareClipURL != nil {
                Menu {
                    Button {
                        controller.compareClipURL = nil
                    } label: {
                        if controller.compareClipURL == nil {
                            Label(L("compare_b_live"), systemImage: "checkmark")
                        } else {
                            Text(L("compare_b_live"))
                        }
                    }
                    Divider()
                    ForEach(controller.takes) { take in
                        Button {
                            controller.compareClipURL = take.url
                        } label: {
                            if controller.compareClipURL == take.url {
                                Label(take.displayName, systemImage: "checkmark")
                            } else {
                                Text(take.displayName)
                            }
                        }
                    }
                } label: {
                    Text(controller.compareClipURL == nil
                         ? L("compare_b_live")
                         : (controller.takes.first {
                             $0.url == controller.compareClipURL
                         }?.displayName ?? "B"))
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 120)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L("compare_b_help"))
            }

            Button {
                controller.pinReferenceFromCurrentFrame()
            } label: {
                Image(systemName: "pin")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(L("pin_reference_help"))
            if controller.referencePinned {
                Button {
                    controller.unpinReference()
                } label: {
                    Image(systemName: "pin.slash.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help(L("unpin_reference_help"))
            }
            if controller.compareMode == .blend {
                Slider(value: $controller.blendOpacity, in: 0...1)
                    .frame(width: 90)
                    .controlSize(.mini)
                TextField("", value: Binding(
                    get: { Int((controller.blendOpacity * 100).rounded()) },
                    set: { controller.blendOpacity = Double(min(100, max(0, $0))) / 100 }),
                    format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 30)
                    .controlSize(.mini)
                Text("%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // same plate as the badges and the mode switch above it (see PlayerChrome)
        .playerChromePlate(horizontalPadding: Self.platePadding)
    }
}
