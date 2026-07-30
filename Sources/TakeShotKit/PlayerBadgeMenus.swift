import CaptureCore
import SwiftUI

// The two menu badges of the player's top chrome.
//
// Split out of `PlayerBadges.swift`: that file owns the chrome family and the
// ONE HStack the row is built from (the three corner overlays it replaced used
// to slide under each other), and adding two full menus to it pushed it past the
// file-length limit. They are views rather than properties of the modifier for a
// second reason — the render suites measure one plate at a time, and a property
// inside a `ViewModifier` cannot be handed to `NSHostingView` on its own.

/// TC readout + the detection/timecode-source menu behind it.
///
/// Its own view rather than a property of the modifier so the render suites can
/// measure ONE plate: item 10 is a family of heights and materials, and a
/// property inside a ViewModifier cannot be handed to `NSHostingView` on its own.
struct PlayerTimecodeBadge: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        playerOverlayBadge {
            Menu {
                detectionModePicker
                Divider()
                timecodeSourcePicker
            } label: {
                if controller.viewerMode == .playback {
                    PlaybackTimecodeText()
                } else {
                    LiveTimecodeText(
                        live: controller.live,
                        tint: controller.isRecording ? Color.red : Color.white)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("tc_menu_help"))
        }
    }

    /// Shared with the Settings pane — see `SignalControls`. Inline and
    /// unlabelled here because the menu's own title says what it is.
    private var detectionModePicker: some View {
        DetectionModePicker()
            .pickerStyle(.inline)
            .labelsHidden()
    }

    private var timecodeSourcePicker: some View {
        Picker(L("tc_source"), selection: Binding(
            get: {
                controller.settings.timecodeSource == "ltc"
                    ? 1 + (controller.settings.ltcChannel ?? 0)
                    : 0
            },
            set: { value in
                if value == 0 {
                    controller.settings.timecodeSource = nil
                } else {
                    controller.settings.timecodeSource = "ltc"
                    controller.settings.ltcChannel = value - 1
                }
            })) {
            Text(L("tc_source_rp188")).tag(0)
            ForEach(1...8, id: \.self) { channel in
                Text(L("tc_source_ltc", channel)).tag(channel)
            }
        }
        .pickerStyle(.menu)
    }
}

/// Resolution/rate readout + the input-mode menu behind it. Its own view for the
/// same reason as `PlayerTimecodeBadge`.
struct PlayerFormatBadge: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        playerOverlayBadge {
            Menu {
                inputModePicker
                ForcedInputRGBToggle()
            } label: {
                formatLabel
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("input_mode"))
        }
    }

    /// Shared with the Settings pane — see `SignalControls`.
    private var inputModePicker: some View {
        InputModePicker()
            .pickerStyle(.inline)
            .labelsHidden()
    }

    private var formatLabel: some View {
        Group {
            if controller.viewerMode == .playback,
               let info = controller.playbackFormatText {
                Text(info).monospacedDigit()
            } else if let format = controller.signalFormat {
                Text(playerShortFormat(format)).monospacedDigit()
            } else {
                Text(L("no_signal_short"))
            }
        }
        .font(.callout)
        .foregroundStyle(.white.opacity(0.9))
    }
}
