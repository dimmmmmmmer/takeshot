import SwiftUI

/// The Output section of the settings window: where the picture and the sound
/// go — a second screen, a DeckLink monitor out, and the audio device.
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
            Picker(L("playback_output"), selection: Binding(
                get: { controller.playbackOutputUID },
                set: { controller.playbackOutputUID = $0 })) {
                Text(L("system_default")).tag(String?.none)
                ForEach(AudioOutputDevices.list()) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
            AudioInputPicker()
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
        // which source is actually feeding the pipeline right now
        Text(controller.audioSourceStatusText)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
