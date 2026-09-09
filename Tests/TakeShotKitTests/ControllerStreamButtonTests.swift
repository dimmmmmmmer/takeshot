import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **The footer's stream button starts as well as stops** (owner: "должна быть
/// кнопка запустить/остановить поток" — two words, and only one of them was
/// built).
///
/// The first version was a one-way door: one press turned both switches off,
/// the indicator's `isEngaged` went false, the control erased itself, and the
/// only way to stream again was the Settings window — the window the indicator
/// exists so nobody has to open during a shooting day. There was no test on
/// this path at all, which is how it shipped.
@Suite @MainActor struct ControllerStreamButtonTests {
    @Test func aPressStopsBothAndTheNextPressStartsThemAgain() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.srt.enabled = true
            controller.settings.ndi.enabled = true
            controller.setSRTRunning(true)
            controller.setNDIRunning(true)

            controller.stopAllStreams()
            // **The RUN switches go, the enable switches stay.** A pause is
            // not the cart deciding it no longer uses SRT — that is the
            // Settings checkbox, and a button on the picture must not throw it.
            #expect(!controller.mirrors.srtRunning)
            #expect(!controller.mirrors.ndiRunning)
            #expect(controller.settings.srt.enabled == true,
                    "pausing the stream un-enabled the transport")
            #expect(controller.settings.ndi.enabled == true)
            #expect(controller.mirrors.pausedStreams.any,
                    "nothing remembered what was switched off")

            controller.resumeStreams()
            #expect(controller.mirrors.srtRunning,
                    "SRT did not come back — the button is still a one-way door")
            #expect(controller.mirrors.ndiRunning)
            #expect(!controller.mirrors.pausedStreams.any,
                    "the pause record outlived the resume")
        }
    }

    /// Exactly what was paused, and nothing else. An operator who took NDI off
    /// the set network before the shoot has not asked for it back, and a button
    /// that decided otherwise would put a picture on that network again.
    @Test func onlyWhatThisButtonStoppedComesBack() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.srt.enabled = true
            controller.setSRTRunning(true)
            controller.settings.ndi.enabled = false  // a decision, not a pause

            controller.stopAllStreams()
            #expect(controller.mirrors.pausedStreams.srt)
            #expect(!controller.mirrors.pausedStreams.ndi)

            controller.resumeStreams()
            #expect(controller.mirrors.srtRunning)
            #expect(!controller.mirrors.ndiRunning,
                    "a transport switched off in Settings was started anyway")
            #expect(controller.settings.ndi.enabled == false,
                    "a stream switched off in Settings was turned back on")
        }
    }

    /// A second press on an already-stopped footer must not erase what the
    /// first one remembered.
    @Test func aPressWithNothingRunningKeepsTheRecord() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.srt.enabled = true
            controller.setSRTRunning(true)
            controller.stopAllStreams()
            controller.stopAllStreams()
            #expect(controller.mirrors.pausedStreams.srt,
                    "the second press wiped what the first one paused")

            controller.resumeStreams()
            #expect(controller.settings.srt.enabled == true)
        }
    }

    /// And a resume with nothing paused does nothing at all — the button is not
    /// a way to turn on a stream that was never running.
    @Test func aResumeWithNothingPausedTurnsNothingOn() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.srt.enabled = false
            controller.settings.ndi.enabled = false
            controller.resumeStreams()
            #expect(controller.settings.srt.enabled == false)
            #expect(controller.settings.ndi.enabled == false)
        }
    }
}

/// **Using a transport and sending over it are two switches.**
///
/// They used to be one: `settings.srt.enabled` both meant "this cart streams
/// over SRT" and dialled the link, so the Settings checkbox was a transmit
/// button and the badge had to appear for a transport nobody uses (owner: "я бы
/// хотел чтобы кнопка включения/выключения не запускала стримы а включала
/// возможность… пользователю который не использует ни то ни другое на главном
/// окне их значки ни к чему").
@Suite @MainActor struct ControllerStreamEnableTests {
    @Test func enablingATransportDoesNotDialIt() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.srtStreamFactory = { _ in FakeSRTStream() }
            controller.settings.srt.address = "10.0.0.9"
            controller.settings.srt.enabled = true
            #expect(!controller.mirrors.srtRunning)
            #expect(controller.mirrors.srt == nil,
                    "enabling the transport opened a socket")
            #expect(controller.mirrors.srtState == SRTOutputState.off)
        }
    }

    @Test func theRunSwitchIsWhatOpensTheLink() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.srtStreamFactory = { _ in FakeSRTStream() }
            controller.settings.srt.address = "10.0.0.9"
            controller.settings.srt.enabled = true
            controller.setSRTRunning(true)
            #expect(controller.mirrors.srtRunning)
            #expect(controller.mirrors.srt != nil, "the link did not open")

            controller.setSRTRunning(false)
            #expect(!controller.mirrors.srtRunning)
            #expect(controller.mirrors.srt == nil, "the link stayed open")
        }
    }

    /// A transport the cart does not use cannot be started, and asking must not
    /// enable it behind the operator's back.
    @Test func anUnusedTransportCannotBeStarted() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.srtStreamFactory = { _ in FakeSRTStream() }
            controller.settings.srt.address = "10.0.0.9"
            controller.setSRTRunning(true)
            #expect(!controller.mirrors.srtRunning)
            #expect(controller.mirrors.srt == nil)
            #expect(controller.settings.srt.enabled == nil,
                    "starting the stream enabled the transport by itself")
        }
    }

    /// …and dropping the transport takes a live link down: you cannot be
    /// streaming over one the cart does not use.
    @Test func droppingTheTransportClosesALiveLink() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.srtStreamFactory = { _ in FakeSRTStream() }
            controller.settings.srt.address = "10.0.0.9"
            controller.settings.srt.enabled = true
            controller.setSRTRunning(true)
            #expect(controller.mirrors.srt != nil)

            controller.settings.srt.enabled = nil
            #expect(!controller.mirrors.srtRunning)
            #expect(controller.mirrors.srt == nil,
                    "the link outlived the transport being dropped")
        }
    }

    /// **Nothing streams because the app was launched.** The two outputs used
    /// to come back up for a stored switch, on the web remote's terms; a
    /// relaunch is not somebody asking for a picture on a production network.
    @Test func aRelaunchStreamsNothing() async throws {
        try await ControllerHarness.run(configure: { settings in
            settings.srt.enabled = true
            settings.srt.address = "10.0.0.9"
            settings.ndi.enabled = true
        }, { controller, _ in
            #expect(!controller.mirrors.srtRunning,
                    "SRT dialled itself at startup")
            #expect(!controller.mirrors.ndiRunning,
                    "NDI announced itself at startup")
            // …and the transports are still the ones the cart uses, so the
            // badge shows both.
            #expect(controller.settings.srt.enabled == true)
            #expect(controller.settings.ndi.enabled == true)
        })
    }
}

/// **The readout says what is actually happening; the switch says what the
/// operator asked for.**
///
/// `startSRTOutput` returns having opened nothing for three reasons an
/// operator can hit — a build with no libsrt, an address that is not one, an
/// address that is empty — and each leaves the reason on the settings row. The
/// switch deliberately stays ON through those, so a corrected address retries
/// instead of needing two presses. What must not lie is the READOUT, and the
/// first version of this fix got that backwards: it turned the switch off,
/// which broke the retry — `aNewNameRetriesAfterAFailure` caught it.
@Suite @MainActor struct ControllerStreamRunTruthTests {
    @Test func aRefusedStartLeavesTheSwitchOnSoItCanRetry() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.srtStreamFactory = { _ in FakeSRTStream() }
            controller.settings.srt.enabled = true
            controller.settings.srt.address = ""

            controller.setSRTRunning(true)
            #expect(controller.mirrors.srtRunning,
                    "the switch went off, so a corrected address cannot retry")
            #expect(controller.mirrors.srt == nil)
            // …and the reason is on the row, which is where it belongs.
            #expect(controller.mirrors.srtState != SRTOutputState.off,
                    "nothing said why the link did not open")
        }
    }

    /// **The state is reported by the row that reports state.** The Start/Stop
    /// control is a button and nothing else: a caption reading the switch
    /// would say "Sending" over a link that never opened, and one reading the
    /// link would repeat the status row directly below it.
    @Test func theRunControlSaysOnlyWhatPressingItWillDo() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TakeShotKit/StreamRunRow.swift"),
            encoding: .utf8)
        #expect(source.contains("stream_stop"))
        #expect(source.contains("stream_start"))
        #expect(!source.contains("stream_running"),
                "the row carries a state caption again")
        #expect(!source.contains("stream_stopped"))
    }

    /// …and the section still reports the state, which is what the caption
    /// would have duplicated.
    @Test func theSectionStillHasItsStatusRow() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/TakeShotKit/SRTSettingsSection.swift"),
            encoding: .utf8)
        #expect(source.contains("SRTStatusRow"),
                "nothing in the SRT section reports the link any more")
    }
}
