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
        }
    }
}
