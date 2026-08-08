import AVFoundation
import CaptureCore
import CoreMedia
import Foundation
import Testing

@testable import TakeShotKit

/// The USB audio input, driven end to end through the fake device layer: the
/// choice persists, a take carries the external source's PCM instead of the
/// embedded audio, and both failure shapes stay honest — a device missing at
/// the start falls back to embedded with a warning, a device that vanishes
/// mid-take leaves the take alive over counted silence.
@Suite @MainActor struct ControllerAudioInputTests {
    /// Roll a manual take for roughly `seconds` (same shape as the capture
    /// suite's helper: the synthetic source's TC is frozen, so the clock paces
    /// the take and every assertion afterwards waits on real state).
    private func record(_ controller: CaptureController,
                        seconds: Double) async {
        controller.toggleManualRecord()
        await ControllerWait.until { controller.isRecording }
        let deadline = Date().addingTimeInterval(seconds)
        await ControllerWait.until({ Date() >= deadline },
                                   timeout: .seconds(seconds + 45))
        controller.toggleManualRecord()
        await ControllerWait.until { !controller.isRecording }
    }

    @Test func theSourceChoicePersistsAndRoundTrips() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.settings.audioInputDeviceUID == nil)

            controller.audioInputUID = "usb-42"
            #expect(CaptureSettings.loaded(from: controller.defaults)
                .audioInputDeviceUID == "usb-42")

            controller.audioInputUID = nil
            #expect(CaptureSettings.loaded(from: controller.defaults)
                .audioInputDeviceUID == nil)
        }
    }

    /// The field is Optional on purpose: settings JSON written before it
    /// existed must keep decoding (the project's contract for added fields).
    @Test func settingsWithoutTheFieldStillDecode() throws {
        var old = CaptureSettings()
        old.audioInputDeviceUID = "usb-42"
        let data = try JSONEncoder().encode(old)
        let json = try #require(String(data: data, encoding: .utf8))
        let stripped = json.replacingOccurrences(
            of: "\"audioInputDeviceUID\":\"usb-42\",", with: "")
            .replacingOccurrences(of: ",\"audioInputDeviceUID\":\"usb-42\"",
                                  with: "")
        #expect(!stripped.contains("audioInputDeviceUID"),
                "the fixture failed to strip the field")
        let decoded = try JSONDecoder().decode(
            CaptureSettings.self, from: Data(stripped.utf8))
        #expect(decoded.audioInputDeviceUID == nil)
    }

    @Test func aTakeRecordedFromTheUSBSourceCarriesItsPCM() async throws {
        let provider = FakeAudioInputProvider()
        let device = FakeAudioCaptureDevice(amplitude: 9000)
        provider.connected = [device]
        try await ControllerHarness.run(live: true,
                                        audioInputs: provider) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }

            controller.audioInputUID = device.uid
            #expect(controller.externalAudioActive)
            #expect(device.started)
            // the meters follow the USB source's two channels — the 16-channel
            // embed is refused whole, never mixed in
            await ControllerWait.until { controller.live.audioLevels.count == 2 }
            #expect(controller.live.audioLevels.count == 2)

            await record(controller, seconds: 1.2)
            await ControllerWait.untilWritten { controller.takes.count == 1 }
            let take = try #require(controller.takes.first)
            await TestWaitKit.fileExists(at: take.url)

            // the file carries the fake's constant 9000 — the embedded feed is
            // near-silence (every sample 1), so this cannot pass by accident
            let peak = try await TestAudioKit.peakAmplitude(of: take.url)
            #expect(peak > 4000,
                    "peak \(peak) — the USB source's PCM did not reach the take")

            // host-clock audio anchored to the take's first video PTS: the two
            // tracks start together and cover the same span
            let ranges = try await TestAudioKit.trackRanges(of: take.url)
            let video = try #require(ranges.video)
            let audio = try #require(ranges.audio)
            let startSkew = abs(
                CMTimeSubtract(audio.start, video.start).seconds)
            #expect(startSkew < 0.15,
                    "audio starts \(startSkew) s away from the video")
            #expect(audio.duration.seconds > video.duration.seconds - 0.3,
                    "audio \(audio.duration.seconds) s, picture \(video.duration.seconds) s")
        }
    }

    @Test func aVanishingUSBDeviceDoesNotKillTheTake() async throws {
        let provider = FakeAudioInputProvider()
        let device = FakeAudioCaptureDevice()
        provider.connected = [device]
        try await ControllerHarness.run(live: true,
                                        audioInputs: provider) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }
            controller.audioInputUID = device.uid
            #expect(controller.externalAudioActive)

            controller.toggleManualRecord()
            await ControllerWait.until { controller.isRecording }
            // some real audio first, then the interface is yanked
            let rolling = Date().addingTimeInterval(0.6)
            await ControllerWait.until({ Date() >= rolling },
                                       timeout: .seconds(10))
            provider.connected = []
            device.vanish()

            // the take survives: video keeps recording, the sticky alarm names
            // the loss, and the drop counter path is the pad counter's
            await ControllerWait.until {
                controller.persistentAlert == L("alarm_usb_audio_lost")
            }
            #expect(controller.isRecording, "the take died with the device")
            let padded = Date().addingTimeInterval(1.0)
            await ControllerWait.until({ Date() >= padded },
                                       timeout: .seconds(10))
            #expect(controller.isRecording)

            controller.toggleManualRecord()
            await ControllerWait.until { !controller.isRecording }
            await ControllerWait.untilWritten { controller.takes.count == 1 }
            let take = try #require(controller.takes.first)
            await TestWaitKit.fileExists(at: take.url)

            // the log row is marked — a padded take must not read as clean
            #expect(take.comment.contains("silence"),
                    "take comment does not mark the loss: '\(take.comment)'")

            // silence padding kept the audio track continuous to the end
            let ranges = try await TestAudioKit.trackRanges(of: take.url)
            let video = try #require(ranges.video)
            let audio = try #require(ranges.audio)
            let shortfall = video.duration.seconds - audio.duration.seconds
            #expect(audio.duration.seconds > video.duration.seconds - 0.35,
                    "audio ends \(shortfall) s early — the gap was not padded")

            // with the device still gone, the source resolves to embedded
            // (visibly) once the take is closed
            await ControllerWait.until { !controller.externalAudioActive }
            #expect(!controller.externalAudioActive)
            #expect(controller.persistentAlert == L("usb_audio_missing"))
        }
    }

    @Test func aMissingDeviceAtStartFallsBackToEmbeddedWithAWarning() async throws {
        let provider = FakeAudioInputProvider() // nothing plugged in
        try await ControllerHarness.run(live: true,
                                        audioInputs: provider) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }

            controller.audioInputUID = "gone-usb"
            #expect(!controller.externalAudioActive)
            #expect(controller.persistentAlert == L("usb_audio_missing"))

            // a REC start normally clears the alarm banner — the fallback must
            // be re-raised so the take never records embedded audio silently
            controller.toggleManualRecord()
            await ControllerWait.until { controller.isRecording }
            await ControllerWait.until {
                controller.persistentAlert == L("usb_audio_missing")
            }
            #expect(controller.persistentAlert == L("usb_audio_missing"))
            // the embedded feed is what the meters show: all 16 channels
            await ControllerWait.until { controller.live.audioLevels.count == 16 }
            #expect(controller.live.audioLevels.count == 16)

            let deadline = Date().addingTimeInterval(1.0)
            await ControllerWait.until({ Date() >= deadline },
                                       timeout: .seconds(10))
            controller.toggleManualRecord()
            await ControllerWait.until { !controller.isRecording }
            await ControllerWait.untilWritten { controller.takes.count == 1 }
            let take = try #require(controller.takes.first)
            await TestWaitKit.fileExists(at: take.url)

            // embedded audio was recorded — never a take with no sound at all
            let ranges = try await TestAudioKit.trackRanges(of: take.url)
            let audio = try #require(ranges.audio,
                                     "the fallback take has no audio track")
            #expect(audio.duration.seconds > 0.5)
        }
    }

    @Test func hotPlugRefreshesTheListAndReattachesTheChosenDevice() async throws {
        let provider = FakeAudioInputProvider()
        try await ControllerHarness.run(audioInputs: provider) { controller, _ in
            controller.refreshAudioInputDevices()
            #expect(controller.audioInputDevices.isEmpty)

            controller.audioInputUID = "fake-usb"
            #expect(!controller.externalAudioActive)
            #expect(controller.persistentAlert == L("usb_audio_missing"))

            // the interface is plugged in: the picker list refreshes and the
            // configured device reattaches without a trip through Settings
            let device = FakeAudioCaptureDevice()
            provider.connected = [device]
            provider.deviceListChanged()

            #expect(controller.audioInputDevices.map(\.uid) == ["fake-usb"])
            #expect(controller.externalAudioActive)
            #expect(device.started)
            // the panel names the live source honestly
            #expect(controller.audioSourceStatusText.contains(device.name))
        }
    }
}

/// File waits for this target (CaptureCoreTests has its own TestWait; the two
/// targets cannot share a file, and the audio suites here need the same
/// I/O-sized budget for finalized takes).
@MainActor
enum TestWaitKit {
    static func fileExists(at url: URL) async {
        await ControllerWait.untilWritten {
            FileManager.default.fileExists(atPath: url.path)
        }
    }
}
