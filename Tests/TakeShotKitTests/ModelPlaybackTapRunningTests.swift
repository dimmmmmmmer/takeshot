import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **What the playback tap does when it is switched off and back on.**
///
/// Its own suite because it is a question about the tap's LIFECYCLE rather than
/// about what it renders, and because the case that made it matter comes from
/// somewhere else entirely: the sync-play grid takes the screen, the tap goes
/// off, and everything it was feeding — including a hardware output that HOLDS
/// its last frame — is now showing something else.
struct ModelPlaybackTapRunningTests {
    /// A tap and what it delivers; the handler fires on the tap queue.
    private static func tapWithCollector()
        -> (PlaybackFrameTap, MediaFixtures.FrameCollector) {
        let tap = PlaybackFrameTap()
        let collector = MediaFixtures.FrameCollector()
        tap.setOnDisplayFrame { collector.record($0[.decorated]) }
        return (tap, collector)
    }

    /// **Switching the tap back on re-delivers the paused picture**, which is
    /// what makes "the parked take comes back" true on a surface that HOLDS its
    /// last frame.
    ///
    /// `idleDelivered` means "this paused picture has already been handed to my
    /// surfaces" — and while the tap is off those surfaces are showing something
    /// else entirely: the sync-play grid, the live signal. A paused clip has no
    /// next frame to recover on, so a latch left set means the tap comes back on
    /// and delivers NOTHING, and whatever replaced its picture stays on the
    /// hardware output. The trap needs a paused source to appear at all, which
    /// is why this drives a still rather than a running clip.
    @Test func switchingTheTapBackOnRedeliversThePausedPicture() async throws {
        let (tap, collector) = Self.tapWithCollector()
        tap.setRunning(true)
        tap.attachStill(MediaFixtures.pixelBuffer(level: 64, width: 64, height: 64))

        // A paused picture is delivered until the latch catches and then not
        // again. Pinned first, because it is the behaviour the rest measures
        // against — without it this test would pass on a tap that never latched.
        #expect(await ControllerWait.until { collector.count >= 2 },
                "the paused still was never delivered")
        let settled = collector.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(collector.count == settled,
                "the idle latch never caught; this test measures nothing")

        // The grid takes the screen, then gives it back.
        tap.setRunning(false)
        tap.queue.sync {}
        tap.setRunning(true)
        #expect(await ControllerWait.until { collector.count > settled },
                "a paused clip delivered nothing after its tap came back on")
    }
}
