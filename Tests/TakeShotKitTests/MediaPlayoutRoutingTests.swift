import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// Where the hardware monitor output is fed from.
///
/// The mirror has exactly one source at a time and it follows the viewer: in
/// record mode the live pipeline, in playback the tap or the RAW engine. Feeding
/// it from two places at once puts two pictures on the director's monitor, and
/// leaving a stale handler behind keeps pushing frames into a torn-down feeder.
///
/// Building a real feeder is out of bounds here — it opens a DeckLink output on
/// whatever board the machine has — so these tests stay on the side of the
/// switch that decides nothing is mirrored, which is also the state the app is
/// in whenever no output device is chosen.
@Suite @MainActor struct MediaPlayoutRoutingTests {
    /// No output device: nothing is mirrored, and neither producer is left
    /// holding a handler.
    @Test func withNoOutputDeviceNothingIsMirrored() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.settings.capture.monitorDeviceID == nil)
            #expect(controller.mirrors.playout == nil)

            let collector = MediaFixtures.FrameCollector()
            controller.playbackTap.setOnDisplayFrame { collector.record($0[.decorated]) }
            controller.rebuildPlayout()

            #expect(controller.mirrors.playout == nil)
            #expect(controller.playbackTap.displayFrameHandler == nil,
                    "the tap is still feeding an output that does not exist")

            // and the cleared handler really is disconnected
            controller.playbackTap.attachStill(
                MediaFixtures.pixelBuffer(level: 0x80, width: 32, height: 32))
            controller.playbackTap.queue.sync {}
            #expect(collector.count == 0)
        }
    }

    /// A monitor device that is not a DeckLink (the playback audio output shares
    /// this setting's shape) must not be taken for one.
    @Test func anOutputThatIsNotADeckLinkIsIgnored() async throws {
        try await ControllerHarness.run { controller, _ in
            // assigning the setting is what the picker does; it rebuilds itself
            controller.settings.capture.monitorDeviceID = "builtin-speakers"

            #expect(controller.mirrors.playout == nil)
            #expect(controller.lastError == nil,
                    "a non-DeckLink output raised: \(controller.lastError ?? "")")
            #expect(controller.playbackTap.displayFrameHandler == nil)
        }
    }

    /// The board the output was configured on is not there any more (unplugged,
    /// or a saved ID from another machine). Both attempts — the signal's own
    /// raster and the 1080p25 fallback — fail, and the operator has to be told:
    /// silently showing nothing on the director's monitor is the failure this
    /// error exists for. A device ID no board can match is used deliberately, so
    /// the test cannot open an output on a machine that does have one.
    @Test func aConfiguredOutputThatIsGoneIsReported() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.capture.monitorDeviceID =
                "decklink:no-such-board-\(UUID().uuidString)"

            #expect(controller.mirrors.playout == nil)
            #expect(controller.lastError?.hasPrefix("Output:") == true,
                    "the dead output reported: \(controller.lastError ?? "nothing")")
            #expect(controller.playbackTap.displayFrameHandler == nil)
        }
    }

    /// Switching the viewer rewires the mirror. With no feeder both ends come
    /// out nil whichever way the viewer is pointing — what matters is that the
    /// switch runs on every mode change instead of only at startup.
    @Test func switchingTheViewerRewiresTheMirror() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.playbackTap.setOnDisplayFrame { _ in }

            controller.viewerMode = .playback
            #expect(controller.playbackTap.displayFrameHandler == nil)

            controller.playbackTap.setOnDisplayFrame { _ in }
            controller.viewerMode = .record
            #expect(controller.playbackTap.displayFrameHandler == nil)
        }
    }

    /// Closing a fullscreen surface that is not open must be a no-op rather
    /// than an attempt to build one — the hotkey fires in both directions.
    @Test func closingAFullscreenSurfaceOnlyDropsTheFlag() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.isPlaybackFullscreen = true
            controller.togglePlaybackFullscreen()
            #expect(!controller.isPlaybackFullscreen)
            #expect(controller.playbackFullscreenWindow == nil)

            controller.isLiveFullscreen = true
            controller.toggleLiveFullscreen()
            #expect(!controller.isLiveFullscreen)
            #expect(controller.liveFullscreenWindow == nil)
        }
    }

    /// The external-display option is identified by its display ID: two screens
    /// can report the same localized name, and the app has to tell them apart.
    @Test func screenOptionsAreIdentifiedByDisplayID() {
        let first = CaptureController.ScreenOption(id: 1, name: "DELL U2720Q")
        let same = CaptureController.ScreenOption(id: 1, name: "DELL U2720Q")
        let second = CaptureController.ScreenOption(id: 2, name: "DELL U2720Q")
        #expect(first == same)
        #expect(first != second)
        #expect(first.id == 1)
    }
}
