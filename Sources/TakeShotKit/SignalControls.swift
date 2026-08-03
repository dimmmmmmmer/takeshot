import CaptureCore
import SwiftUI

// The three controls that decide how the incoming signal is read.
//
// Each of them is offered in two places — the badge menus over the player, for
// the operator who is looking at the picture, and the Settings pane, for the
// one who is setting the rig up — and each had been written out twice. They are
// not decorative: the input mode and the RGB flag restart capture, and the
// detection mode is what decides whether a take starts at all. Two spellings of
// a control like that is two chances to fix only one of them.
//
// The style stays with the caller: the badge menus wear `.pickerStyle(.inline)`
// and hide their labels, Settings disables its rows while a take is rolling.
// Both are environment modifiers, so they reach the picker through the wrapper.

/// Force a DeckLink input mode, or let the board detect one.
struct InputModePicker: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Picker(L("input_mode"), selection: Binding(
            get: { controller.settings.forcedInputMode ?? "auto" },
            set: { controller.settings.forcedInputMode =
                $0 == "auto" ? nil : $0 })) {
            Text(L("input_mode_auto")).tag("auto")
            ForEach(controller.selectedDeviceInputModes, id: \.self) { name in
                Text(name).tag(name)
            }
        }
    }
}

/// The RGB 4:4:4 override, which only means anything once a mode is forced —
/// on auto the board reports the sampling itself, and a switch that claims
/// otherwise is a lie about what is being captured.
struct ForcedInputRGBToggle: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        if controller.settings.forcedInputMode != nil {
            Toggle(L("input_mode_rgb"), isOn: Binding(
                get: { controller.settings.forcedInputRGB ?? false },
                set: { controller.settings.forcedInputRGB = $0 }))
        }
    }
}

/// Bits per component to ask the board for — for BOTH samplings, which is why
/// the rows name two formats each: 10-bit is 'r210' off an RGB 4:4:4 source and
/// 'v210' off a YCbCr 4:2:2 one.
///
/// 10-bit is the default for both, and for YCbCr that is a change worth being
/// plain about: it is what an SDI wire carries, so 8-bit capture of a 4:2:2
/// signal was the driver dropping two bits before the app saw a frame. 12-bit,
/// by contrast, is offered and never the default — it costs twice the record
/// bandwidth, only ProRes 4444 can carry it, not every board or mode delivers
/// it, and there is no 12-bit YCbCr wire format at all, so on a 4:2:2 signal it
/// asks for the same v210 that 10-bit does.
///
/// Either request can fall short, and either falls back visibly rather than
/// quietly (`reportBitDepthShortfall`).
struct CaptureBitDepthPicker: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Picker(L("capture_bit_depth"), selection: Binding(
            get: { controller.settings.resolvedCaptureBitDepth },
            set: { controller.settings.captureBitDepth = $0.rawValue })) {
            Text(L("bit_depth_8")).tag(CaptureBitDepth.eight)
            Text(L("bit_depth_10")).tag(CaptureBitDepth.ten)
            Text(L("bit_depth_12")).tag(CaptureBitDepth.twelve)
        }
        .help(L("capture_bit_depth_hint"))
    }
}

/// What the source's code values mean on the wire.
///
/// Three options, and one of them is Limited — there were two studio-swing
/// entries for a while, differing in what they did with a camera's excursions.
/// The question they were arguing about is settled elsewhere now: the setting
/// says what the SOURCE carries, the monitor gets the nominal expansion so that
/// black is black, and the recorded file gets the wire codes whatever the
/// monitor is doing. Neither reading can destroy anything in the deliverable
/// any more, so there is one Limited.
struct InputLevelsPicker: View {
    @EnvironmentObject private var controller: CaptureController

    /// Legacy stored spellings map onto the option that now means them, so an
    /// operator's saved choice selects a row rather than nothing (see
    /// `CaptureSettings.migrateToVersion2`, which rewrites the value itself).
    private var selection: String {
        switch controller.settings.videoLevels {
        case nil: return "auto"
        case "off": return InputLevels.full.rawValue
        case "limited_excursions": return InputLevels.limited.rawValue
        case let value?: return value
        }
    }

    var body: some View {
        Picker(L("video_levels"), selection: Binding(
            get: { selection },
            set: { controller.settings.videoLevels = $0 == "auto" ? nil : $0 })) {
            Text(L("levels_auto")).tag("auto")
            Text(L("levels_limited")).tag(InputLevels.limited.rawValue)
            Text(L("levels_full")).tag(InputLevels.full.rawValue)
        }
    }
}

/// What starts a take. The default is VANC-only on purpose: running timecode
/// alone is not evidence a camera is rolling (a Resolve playout feeding the
/// board runs timecode too), and it must never start a take.
struct DetectionModePicker: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Picker(L("detection_mode"),
               selection: $controller.settings.detectionMode) {
            Text(L("mode_vanc")).tag(RecDetectionMode.vanc)
            Text(L("mode_auto")).tag(RecDetectionMode.auto)
            Text(L("mode_timecode")).tag(RecDetectionMode.timecodeRun)
            Text(L("mode_manual")).tag(RecDetectionMode.manual)
        }
    }
}
