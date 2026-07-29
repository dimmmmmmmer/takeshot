import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// One volume drives both the live monitor and the player, because switching
/// rec↔playback must not change loudness — and the mute button is transient by
/// design: persisting its zero is what made every launch start silent.
///
/// The fixture starts every controller with the live monitor switched off (the
/// demo source makes real sound); the tests below that need it on say so, and
/// none of them runs a signal, so nothing is ever enqueued to a real device.
@Suite @MainActor struct ControllerAudioTests {
    @Test func oneVolumeDrivesTheMonitorAndThePlayer() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.monitorVolume = 0.4

            #expect(controller.playbackVolume == 0.4)
            #expect(controller.live.volume == 0.4)
            #expect(abs(controller.player.volume - 0.4) < 0.001)

            controller.playbackVolume = 0.9
            #expect(controller.monitorVolume == 0.9)
        }
    }

    /// Persisted once the drag settles rather than on every tick — a settings
    /// write per tick re-rendered the whole window.
    @Test func theVolumeIsPersistedAfterTheDragSettles() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.monitorVolume = 0.6

            await ControllerWait.until { controller.settings.monitorVolume == 0.6 }
            #expect(controller.settings.monitorVolume == 0.6)
        }
    }

    @Test func muteRestoresTheLevelItSilenced() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.monitorOn = true // no signal is running: nothing to hear
            controller.monitorVolume = 0.7
            await ControllerWait.until { controller.settings.monitorVolume == 0.7 }

            controller.toggleMonitorMute()
            #expect(controller.monitorVolume == 0)
            // the stored level is the one to come back to, never the mute
            await ControllerWait.until({ controller.settings.monitorVolume == 0 },
                                       timeout: .seconds(1))
            #expect(controller.settings.monitorVolume == 0.7)

            controller.toggleMonitorMute()
            #expect(controller.monitorVolume == 0.7)
        }
    }

    /// The speaker button never disables the output path — un-muting a monitor
    /// that was switched off has to bring the level back with it.
    @Test func unmutingASwitchedOffMonitorBringsBackALevel() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.monitorOn = true // no signal is running: nothing to hear
            controller.monitorVolume = 0.5
            controller.toggleMonitorMute()
            #expect(controller.monitorVolume == 0)
            controller.monitorOn = false

            controller.toggleMonitorMute()

            #expect(controller.monitorOn)
            #expect(controller.monitorVolume == 0.5)
        }
    }

    /// Switching to playback silences the live feed so two sources are not
    /// heard at once — but it is not the operator saying "monitor off", and
    /// coming back to the live view has to bring the sound back.
    @Test func theViewerModeDoesNotOverwriteTheOperatorsChoice() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.monitorOn = true

            controller.viewerMode = .playback
            #expect(controller.monitorOn)
            #expect(controller.settings.monitorEnabled == true)

            controller.viewerMode = .record
            #expect(controller.monitorOn)
        }
    }

    @Test func theMonitorSwitchIsRemembered() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.monitorOn = true
            #expect(controller.settings.monitorEnabled == true)
            #expect(CaptureSettings.loaded(from: controller.defaults)
                .monitorEnabled == true)

            controller.monitorOn = false
            #expect(controller.settings.monitorEnabled == false)
            #expect(CaptureSettings.loaded(from: controller.defaults)
                .monitorEnabled == false)
        }
    }

    @Test func theOutputDeviceReachesBothThePlayerAndTheMonitor() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.playbackOutputUID == nil)

            controller.playbackOutputUID = "AppleHDAEngineOutput:1"

            #expect(controller.settings.playbackAudioDeviceUID
                == "AppleHDAEngineOutput:1")
            #expect(controller.player.audioOutputDeviceUniqueID
                == "AppleHDAEngineOutput:1")
            // the renderer swap happens on the monitor's own queue
            await ControllerWait.until {
                controller.audioMonitor.outputDeviceUID == "AppleHDAEngineOutput:1"
            }
            #expect(controller.audioMonitor.outputDeviceUID
                == "AppleHDAEngineOutput:1")
        }
    }

    @Test func theMetersReadThroughToTheLiveSignal() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.live.audioLevels = [-12, -18]
            #expect(controller.audioLevels == [-12, -18])
        }
    }
}
