import Foundation
import Testing

@testable import TakeShotKit

/// The playback output, at launch and on hot-plug.
///
/// The app points playback and the live monitor at the stored output UID in
/// `completeStartup`, before any picker is opened — and it used to have no
/// list of outputs at that moment, because the two views that show one each
/// enumerated CoreAudio themselves. The channels panel therefore came up
/// naming the operator's chosen device "missing" while playing out of it, and
/// a device that registered a moment after launch never appeared in the menu
/// at all (owner: "playback audio output сразу не определился при запуске
/// приложения почему то").
@Suite @MainActor struct ControllerAudioOutputListTests {
    private func provider(
        _ names: [(String, String)]) -> FakeAudioInputProvider {
        let fake = FakeAudioInputProvider()
        fake.connectedOutputs = names.map {
            AudioOutputDevices.Device(uid: $0.0, name: $0.1)
        }
        return fake
    }

    /// The list is there as soon as the controller is, with nobody having
    /// opened a picker.
    @Test func theOutputsAreKnownBeforeAnyPickerIsOpened() async throws {
        let outputs = provider([("board-uid", "UltraStudio 4K Mini"),
                                ("built-in", "MacBook Pro Speakers")])
        try await ControllerHarness.run(audioInputs: outputs) { controller, _ in
            #expect(controller.audioOutputDevices.map(\.uid)
                        == ["board-uid", "built-in"],
                    "the outputs are not read until something asks for them")
        }
    }

    /// The symptom itself: the stored device is NAMED at launch, not reported
    /// missing. Same derivation the channels panel's label goes through.
    @Test func theStoredOutputIsNamedAtLaunchRatherThanCalledMissing() async throws {
        let outputs = provider([("board-uid", "UltraStudio 4K Mini")])
        try await ControllerHarness.run(audioInputs: outputs, configure: {
            $0.audio.playbackAudioDeviceUID = "board-uid"
        }, { controller, _ in
            #expect(AudioOutputMenu.name(for: controller.playbackOutputUID,
                                         in: controller.audioOutputDevices)
                        == "UltraStudio 4K Mini",
                    "the panel cannot name the device it is already playing out of")
        })
    }

    /// A UID with nothing behind it still says so — the honest half of the
    /// same label, which the fix must not have traded away.
    @Test func anOutputThatIsReallyGoneIsStillCalledMissing() async throws {
        let outputs = provider([("built-in", "MacBook Pro Speakers")])
        try await ControllerHarness.run(audioInputs: outputs, configure: {
            $0.audio.playbackAudioDeviceUID = "board-uid"
        }, { controller, _ in
            #expect(AudioOutputMenu.name(for: controller.playbackOutputUID,
                                         in: controller.audioOutputDevices)
                        == L("audio_output_missing"))
            #expect(AudioOutputMenu.name(for: nil, in: controller.audioOutputDevices)
                        == L("system_default"))
        })
    }

    /// One CoreAudio notification, both directions: an interface arriving
    /// brings an input and an output, and the operator should not have to
    /// close and reopen the panel to see the output.
    @Test func aHotPluggedInterfaceShowsUpInTheOutputListToo() async throws {
        let outputs = provider([])
        try await ControllerHarness.run(audioInputs: outputs) { controller, _ in
            #expect(controller.audioOutputDevices.isEmpty)

            outputs.connectedOutputs = [
                AudioOutputDevices.Device(uid: "board-uid", name: "UltraStudio 4K Mini")]
            outputs.deviceListChanged()

            #expect(controller.audioOutputDevices.map(\.name)
                        == ["UltraStudio 4K Mini"],
                    "the output list waited for the panel to be reopened")
        }
    }

    /// The watcher is installed by the startup refresh, so the hot-plug above
    /// works with nobody having opened Settings. One watcher for both
    /// directions — CoreAudio has one device-set property.
    @Test func theStartupRefreshIsWhatArmsTheWatcher() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.audioDeviceWatchStarted,
                    "nothing is listening for devices until a picker is opened")
        }
    }

    /// **No view enumerates the machine's outputs itself.** That is what put a
    /// CoreAudio device walk in a `Form` body, and what left the channels
    /// panel's first render with an empty list to name the device from.
    @Test func noViewWalksCoreAudioForOutputsOnItsOwn() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit")
        // the enum's own file, and the one provider allowed to call it
        let allowed: Set<String> = ["AudioOutputDevices.swift", "AudioInputDevices.swift"]
        var offenders: [String] = []
        for case let url as URL in FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" && !allowed.contains(url.lastPathComponent) {
            let code = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains("AudioOutputDevices.list()") {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders == [String](), """
            these enumerate the machine's audio outputs themselves instead of \
            reading controller.audioOutputDevices
            """)
    }
}
