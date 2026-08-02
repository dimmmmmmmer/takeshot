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
                get: { controller.settings.monitorDeviceID },
                set: { controller.settings.monitorDeviceID = $0 })) {
                Text(L("external_off")).tag(String?.none)
                ForEach(controller.devices.filter { $0.id.hasPrefix("decklink:") }) { device in
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
            Picker(L("playback_output"), selection: Binding(
                get: { controller.playbackOutputUID },
                set: { controller.playbackOutputUID = $0 })) {
                Text(L("system_default")).tag(String?.none)
                ForEach(AudioOutputDevices.list()) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
        }
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
