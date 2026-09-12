import CaptureCore
import SwiftUI

/// Two sections of the settings window, one per department: where the PICTURE
/// goes — a second screen and a DeckLink monitor out — and, under its own
/// heading, where the SOUND comes from and goes to.
///
/// One section held both until the operator pointed out that the audio device
/// rows read as an afterthought under a heading about monitors. They are the
/// sound department's rows and they get their own block.
///
/// Lifted out of `SettingsView` when the Remote section arrived: that type was
/// at its body-length ceiling exactly, so the next section had to displace one.
/// This is the group with no state of its own, which makes it the one that
/// moves without changing behaviour.
struct OutputSettingsSection: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Section(L("settings_output")) {
            Picker(L("external_display"), selection: Binding(
                get: { controller.externalDisplayID },
                set: { controller.externalDisplayID = $0 })) {
                Text(L("external_off")).tag(CGDirectDisplayID?.none)
                ForEach(controller.availableScreens) { screen in
                    Text(screen.name).tag(CGDirectDisplayID?.some(screen.id))
                }
            }
            Picker(L("monitor_device"), selection: Binding(
                get: { controller.settings.capture.monitorDeviceID },
                set: { controller.settings.capture.monitorDeviceID = $0 })) {
                Text(L("external_off")).tag(String?.none)
                ForEach(controller.deckLinkDevices) { device in
                    Text(device.name).tag(String?.some(device.id))
                }
            }
        }
        AudioSettingsSection()
    }
}

/// The sound department's block: what is recorded, and what the room hears
/// during playback.
struct AudioSettingsSection: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Section(L("settings_audio")) {
            AudioInputPicker()
            AudioDelayField()
            // off the controller, like the input picker above it: the list
            // used to be enumerated HERE, which put a CoreAudio device walk in
            // a Form body — once per render of the whole audio section
            Picker(L("playback_output"), selection: Binding(
                get: { controller.playbackOutputUID },
                set: { controller.playbackOutputUID = $0 })) {
                Text(L("system_default")).tag(String?.none)
                ForEach(controller.audioOutputDevices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
        }
    }
}

/// **How late this source's sound arrives**, in milliseconds, for whichever
/// source is selected right now (owner: "по звуку – хочу еще добавить
/// настройку задержки звука. мне кажется с разными источниками может быть
/// полезно").
///
/// One field rather than two, showing the number for the source the picker
/// above is on: an operator dials this in by ear against the picture, and they
/// can only do that for the source they are actually listening to. The other
/// source keeps its own number and gets it back when they switch
/// (`AudioSettings.delayMS(for:)`).
///
/// Not disabled while recording. Unlike the source itself — which is latched
/// per take because the writer's channel count is fixed at open — a delay is
/// only where samples are stamped, so it may be nudged mid-take and the rest
/// of the take follows.
struct AudioDelayField: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HStack {
            Text(L("audio_delay"))
            Spacer()
            TextField("", value: Binding(get: { controller.audioDelayMS },
                                         set: { controller.audioDelayMS = $0 }),
                      format: .number.precision(.fractionLength(0...1)))
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
            Stepper("", value: Binding(get: { controller.audioDelayMS },
                                       set: { controller.audioDelayMS = $0 }),
                    in: AudioSettings.delayRangeMS, step: 1)
                .labelsHidden()
            Text(L("unit_ms")).foregroundStyle(.secondary)
        }
        .help(L("audio_delay_help"))
    }
}

/// The record-side audio source: the board's embedded audio, or a Core Audio
/// input device (the sound cart's mix over USB). Its own view so the list can
/// come off the controller — refreshed on hot-plug by the input watcher —
/// rather than being enumerated in a Form body on every render.
struct AudioInputPicker: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        // the mask (and the writer's channel count) is latched per take, so
        // the source cannot move mid-take — same refusal as the device picker
        Picker(L("audio_input_source"), selection: Binding(
            get: { controller.audioInputUID },
            set: { controller.audioInputUID = $0 })) {
            Text(L("audio_input_embedded")).tag(String?.none)
            ForEach(controller.audioInputDevices) { device in
                Text(L("audio_input_device_label", device.name,
                       device.channelCount))
                    .tag(String?.some(device.uid))
            }
            // the saved device is not plugged in right now: shown as itself
            // rather than snapping the selection to something else
            if let uid = controller.audioInputUID,
               !controller.audioInputDevices.contains(where: { $0.uid == uid }) {
                Text(L("audio_input_missing_entry")).tag(String?.some(uid))
            }
        }
        .disabled(controller.isRecording)
        .onAppear { controller.refreshAudioInputDevices() }
    }
}
