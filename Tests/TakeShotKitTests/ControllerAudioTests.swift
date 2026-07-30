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

    /// The level of a drag that was muted inside the 400 ms debounce window used
    /// to be thrown away with the pending write: the transient mute cancelled it,
    /// and nothing wrote the level the operator had just set. Now the write
    /// carries the level it was made for, so the mute leaves it alone.
    @Test func theLevelSurvivesAMuteRightAfterTheDrag() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.monitorOn = true // no signal is running: nothing to hear
            controller.monitorVolume = 0.35   // drag settles...
            controller.toggleMonitorMute()    // ...and is muted before it persists

            #expect(controller.monitorVolume == 0)
            await ControllerWait.until { controller.settings.monitorVolume == 0.35 }
            #expect(controller.settings.monitorVolume == 0.35,
                    "the muted drag was never persisted")
        }
    }

    // MARK: - DIM (owner item 8)

    @Test func dimHalvesTheLevelAndRestoresItExactly() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.isCapturing = true
            controller.monitorVolume = 0.8
            #expect(controller.canDimMonitoring)

            controller.toggleMonitorDim()
            #expect(controller.live.dimmed)
            #expect(controller.monitorVolume == 0.4)
            #expect(abs(controller.player.volume - 0.4) < 0.001)

            controller.toggleMonitorDim()
            #expect(!controller.live.dimmed)
            #expect(controller.monitorVolume == 0.8)
            #expect(abs(controller.player.volume - 0.8) < 0.001)
        }
    }

    /// What gets remembered is the DIM STATE and the level the operator set —
    /// never the dimmed half of that level. Persisting the half would silently
    /// make it the next launch's base level, which is the shape of the bug
    /// persisting the mute's zero once caused.
    @Test func dimPersistsItsStateAndNotTheHalvedLevel() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.isCapturing = true
            controller.monitorVolume = 0.6
            await ControllerWait.until { controller.settings.monitorVolume == 0.6 }

            controller.toggleMonitorDim()
            #expect(controller.monitorVolume == 0.3)
            // the state is written on the slider's own 400 ms debounce
            await ControllerWait.until { controller.settings.monitorDimmed == true }
            #expect(controller.settings.monitorDimmed == true)
            #expect(CaptureSettings.loaded(from: controller.defaults)
                .monitorDimmed == true)
            // and the stored level is still the one the operator set
            #expect(controller.settings.monitorVolume == 0.6)
            #expect(CaptureSettings.loaded(from: controller.defaults)
                .monitorVolume == 0.6)

            controller.toggleMonitorDim()
            await ControllerWait.until { controller.settings.monitorDimmed == nil }
            #expect(controller.settings.monitorDimmed == nil,
                    "the dim outlived itself in settings")
        }
    }

    /// Written once the state settles, not per click: a settings write fans out
    /// through applySettingsChange and re-renders the window, and this button is
    /// beside the meters and reachable from a hotkey.
    @Test func theDimStateIsPersistedOnTheSameDebounceAsTheSlider() async throws {
        try await ControllerHarness.run(configure: { settings in
            settings.monitorVolume = 0.8
            settings.monitorDimmed = true
        }, { controller, _ in
            controller.isCapturing = true

            controller.toggleMonitorDim() // off
            #expect(controller.monitorVolume == 0.8)
            #expect(controller.settings.monitorDimmed == true,
                    "the click wrote settings instead of waiting for the debounce")
            await ControllerWait.until { controller.settings.monitorDimmed == nil }
            #expect(controller.settings.monitorDimmed == nil)

            // two clicks inside one window settle as a single write of the final
            // state — the intermediate one never reaches settings
            controller.toggleMonitorDim() // on...
            controller.toggleMonitorDim() // ...and off again
            await ControllerWait.until({ controller.settings.monitorDimmed == true },
                                       timeout: .seconds(1))
            #expect(controller.settings.monitorDimmed == nil,
                    "an intermediate dim click reached settings")
        })
    }

    /// A dim left engaged comes back engaged, holding down the level the operator
    /// set — which is why the state is what gets stored. The footer badge is lit,
    /// so a quiet launch is explained rather than mysterious.
    @Test func aStoredDimComesBackHoldingTheStoredLevel() async throws {
        try await ControllerHarness.run(configure: { settings in
            settings.monitorVolume = 0.6
            settings.monitorDimmed = true
        }, { controller, _ in
            #expect(controller.live.dimmed)
            #expect(controller.monitorVolume == 0.3)
            #expect(abs(controller.player.volume - 0.3) < 0.001)

            // switching it off gives back the level that was stored, exactly
            controller.toggleMonitorDim()
            #expect(controller.monitorVolume == 0.6)
        })
    }

    /// Moving the level by hand takes DIM's restore point with it: the highlight
    /// may not claim a dim the level is no longer holding.
    @Test func movingTheLevelClearsTheDimState() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.isCapturing = true
            controller.monitorVolume = 0.8
            controller.toggleMonitorDim()
            #expect(controller.live.dimmed)
            await ControllerWait.until { controller.settings.monitorDimmed == true }

            controller.monitorVolume = 0.55 // the operator drags the slider

            #expect(!controller.live.dimmed)
            #expect(controller.monitorVolume == 0.55)
            // the stored state goes with it: a badge lit at the next launch would
            // be claiming a hold this level is not under
            await ControllerWait.until { controller.settings.monitorDimmed == nil }
            #expect(controller.settings.monitorDimmed == nil)
            // and DIM starts again from the new level
            controller.toggleMonitorDim()
            #expect(controller.monitorVolume == 0.275)
        }
    }

    /// Mute and DIM compose: un-muting comes back to the dimmed level, with DIM
    /// still engaged, and switching DIM off then restores the pre-dim level.
    @Test func dimAndMuteCompose() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.isCapturing = true
            controller.monitorOn = true // no signal is running: nothing to hear
            controller.monitorVolume = 0.9
            controller.toggleMonitorDim()
            #expect(controller.monitorVolume == 0.45)

            controller.toggleMonitorMute()
            #expect(controller.monitorVolume == 0)
            #expect(controller.live.dimmed, "the mute switched DIM off")

            controller.toggleMonitorMute()
            #expect(controller.monitorVolume == 0.45)
            #expect(controller.live.dimmed)

            controller.toggleMonitorDim()
            #expect(controller.monitorVolume == 0.9)
        }
    }

    /// Dimming silence is refused rather than accepted as a no-op: the state is
    /// shown as a highlight, and a highlight holding nothing down would survive
    /// the next un-mute and lie about the level.
    @Test func dimIsRefusedWhenThereIsNothingToDim() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.isCapturing = true
            controller.monitorVolume = 0

            #expect(!controller.canDimMonitoring)
            controller.toggleMonitorDim()
            #expect(!controller.live.dimmed)
            #expect(controller.monitorVolume == 0)
        }
    }

    /// With nothing capturing and nothing in the player there is no monitoring to
    /// dim, and the button says so instead of pretending.
    @Test func dimIsUnavailableWithNothingMonitoring() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.stopCapture()
            #expect(!controller.isCapturing)
            #expect(controller.viewerMode == .record)
            #expect(!controller.canDimMonitoring)

            controller.viewerMode = .playback // reviewing a take: the player has sound
            #expect(controller.canDimMonitoring)
        }
    }
}
