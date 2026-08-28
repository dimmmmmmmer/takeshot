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

    /// Which row the timecode menu is on. Tags: 0 is RP188, 1…n are channels
    /// 0…n-1, and -1 is the stored channel when the signal cannot offer it.
    /// The negative tags are labels rather than choices — see the setter.
    ///
    /// Static so the rule can be checked without a window, which is the only way
    /// the stale-channel case can be checked at all: it needs a stored channel,
    /// a live channel count, and the two to disagree.
    static func selectionTag(isLTC: Bool, stored: Int, channels: Int) -> Int {
        guard isLTC else { return 0 }
        return isChannelLive(stored, channels: channels) ? stored + 1 : -1
    }

    /// Whether a stored 0-based LTC channel is one the current signal carries.
    static func isChannelLive(_ stored: Int, channels: Int) -> Bool {
        stored >= 0 && stored < channels
    }

    /// RP188, plus one row per audio channel the CURRENT signal is carrying.
    ///
    /// It used to be `ForEach(1...8)`, hard-coded, while a board embeds up to 16
    /// — so half the channels on an SDI wire could not be selected at all. The
    /// fix is not 16: the number is a property of the signal (`audioChannelCount`
    /// is the count of the meters, i.e. the channels the decoder is actually
    /// handed), and offering channels that are not there is the same bug in the
    /// other direction. A row in this menu is a promise that LTC can be decoded
    /// from it.
    ///
    /// Two cases the count alone does not cover, and neither may rewrite the
    /// stored channel — a signal that is briefly down between setups must not
    /// cost the operator the choice they made:
    ///
    /// - **No signal.** There are no channel rows, because there are no
    ///   channels; `tc_source_ltc_no_signal` says so in the menu rather than
    ///   leaving it looking like LTC was removed. RP188 stays selectable.
    /// - **A stored channel above the live count** (a 16-channel rig swapped for
    ///   a 2-channel one, or the case above). The selection is still shown, on
    ///   its own row, labelled as unavailable. Silently showing "Ch 1" would
    ///   claim the operator had chosen something they had not, and silently
    ///   showing "Ch 13" among the live rows would claim a channel the signal
    ///   does not have. What the DECODER does meanwhile is unchanged: it clamps
    ///   to the last channel that exists (`CapturePipeline+Timecode`), so
    ///   timecode keeps arriving from somewhere while the menu says the chosen
    ///   source is not there.
    private var timecodeSourcePicker: some View {
        let channels = controller.audioChannelCount
        let stored = controller.settings.capture.ltcChannel ?? 0
        let isLTC = controller.settings.capture.timecodeSource == "ltc"
        let unavailable = isLTC && !Self.isChannelLive(stored, channels: channels)
        return Picker(L("tc_source"), selection: Binding(
            get: {
                Self.selectionTag(isLTC: isLTC, stored: stored,
                                  channels: channels)
            },
            set: { value in
                // -1 is a statement about the current selection, not a choice:
                // picking it changes nothing, and in particular does not
                // overwrite the channel the operator is waiting for a signal on.
                guard value >= 0 else { return }
                if value == 0 {
                    controller.settings.capture.timecodeSource = nil
                } else {
                    controller.settings.capture.timecodeSource = "ltc"
                    controller.settings.capture.ltcChannel = value - 1
                }
            })) {
            Text(L("tc_source_rp188")).tag(0)
            if unavailable {
                Text(L("tc_source_ltc_unavailable", stored + 1)).tag(-1)
            }
            if channels > 0 {
                ForEach(1...channels, id: \.self) { channel in
                    Text(L("tc_source_ltc", channel)).tag(channel)
                }
            } else if !unavailable {
                // the row above already says there is no signal, and says which
                // channel is waiting for one
                Text(L("tc_source_ltc_no_signal")).tag(-2)
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
                Divider()
                inputLevelsPicker
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

    /// Also shared with Settings. It belongs over the player as well as in the
    /// pane: how the wire is read is a decision the operator makes WHILE
    /// looking at the scopes, and walking to Settings to make it means losing
    /// sight of the thing being judged.
    private var inputLevelsPicker: some View {
        InputLevelsPicker()
            .pickerStyle(.menu)
    }

    private var formatLabel: some View {
        Group {
            if controller.viewerMode == .playback,
               let info = controller.playbackFormatBadgeText {
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
