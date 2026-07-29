import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Markers are flagged twice — under the playhead in review and against the
/// wall clock while a take rolls — and the two paths share nothing but the
/// name. What regresses here is the routing (a marker landing on the wrong
/// take, or nowhere), the one-per-frame rule that keeps a held-down hotkey
/// from filling the sidecar, and the ±2 frame reach of the delete.
@Suite @MainActor struct ControllerMarkersTests {
    private func loadedTake(_ controller: CaptureController,
                            in root: URL) throws -> Take {
        let take = ControllerFixtures.take(named: "A001C01", in: root)
        try ControllerFixtures.placeholder(for: take)
        controller.takes = [take]
        controller.playbackURL = take.url
        controller.viewerMode = .playback
        controller.playbackFPS = 25
        return take
    }

    @Test func aMarkerLandsOnTheTakeInThePlayer() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try loadedTake(controller, in: root)

            controller.addMarker()

            #expect(controller.takes[0].markers.count == 1)
            #expect(controller.playbackMarkers.count == 1)
            #expect(controller.lastNotice != nil)
        }
    }

    /// One marker per frame: the hotkey repeats while held, and a sidecar of
    /// two hundred markers on the same frame is unusable in Resolve.
    @Test func aSecondMarkerOnTheSameFrameIsDropped() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try loadedTake(controller, in: root)

            controller.addMarker()
            controller.addMarker()
            controller.addMarker()

            #expect(controller.takes[0].markers.count == 1)
        }
    }

    /// Other content is playable but has nowhere to store a marker — this used
    /// to be the silent case.
    @Test func markingSomethingThatIsNotATakeReportsWhyItFailed() async throws {
        try await ControllerHarness.run { controller, root in
            controller.viewerMode = .playback
            controller.playbackURL = root.appendingPathComponent("foreign.mp4")

            controller.addMarker()

            #expect(controller.lastError == L("marker_only_takes"))
            #expect(controller.playbackMarkers.isEmpty)
        }
    }

    @Test func markersOfTheLoadedClipCanBeEditedAndRemoved() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try loadedTake(controller, in: root)
            controller.takes[0].markers = [
                TakeMarker(seconds: 1, timecodeText: "10:00:01:00"),
                TakeMarker(seconds: 3, timecodeText: "10:00:03:00"),
            ]

            controller.updatePlaybackMarker(at: 1) { $0.note = "flare" }
            #expect(controller.takes[0].markers[1].note == "flare")

            // an index the list no longer has must not trap
            controller.updatePlaybackMarker(at: 9) { $0.note = "nope" }
            controller.removePlaybackMarker(at: 9)
            #expect(controller.takes[0].markers.count == 2)

            controller.removePlaybackMarker(at: 0)
            #expect(controller.takes[0].markers.count == 1)
            #expect(controller.takes[0].markers[0].note == "flare")

            controller.clearPlaybackMarkers()
            #expect(controller.takes[0].markers.isEmpty)
        }
    }

    /// ⇧M drops the marker under the playhead — "under" being ±2 frames, not
    /// "the nearest one anywhere in the clip".
    @Test func theNearestMarkerDeleteHasATwoFrameReach() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try loadedTake(controller, in: root)
            // the player holds no item, so the playhead sits at zero
            controller.takes[0].markers = [
                TakeMarker(seconds: 0.04, timecodeText: "10:00:00:01"),
                TakeMarker(seconds: 6, timecodeText: "10:00:06:00"),
            ]

            controller.removeNearestMarker()
            #expect(controller.takes[0].markers.count == 1)
            #expect(controller.takes[0].markers[0].seconds == 6)

            // the remaining one is six seconds away — out of reach
            controller.removeNearestMarker()
            #expect(controller.takes[0].markers.count == 1)
        }
    }

    @Test func markerNavigationOnlyMovesForwardWhenThereIsSomethingAhead()
        async throws {
        try await ControllerHarness.run { controller, root in
            _ = try loadedTake(controller, in: root)
            controller.takes[0].markers = [
                TakeMarker(seconds: 2, timecodeText: "10:00:02:00", note: "gate"),
            ]

            controller.jumpToMarker(forward: false) // nothing behind zero
            #expect(controller.lastNotice == nil)

            controller.jumpToMarker(forward: true)
            #expect(controller.lastNotice?.contains("gate") == true)
            #expect(controller.lastNotice?.contains("10:00:02:00") == true)
        }
    }

    /// While recording there is no clip to attach to yet: markers queue up on
    /// the controller and are anchored when the take finalizes.
    @Test func markersQueueUpWhileATakeIsRolling() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.viewerMode = .record
            controller.isRecording = true
            controller.recordingStartDate = Date().addingTimeInterval(-10)
            controller.live.currentTimecode = Timecode(
                hours: 10, minutes: 0, seconds: 10, frames: 0, fps: 25)
            controller.recordingMarkers = [TakeMarker(seconds: 5)]

            controller.addMarker()
            #expect(controller.recordingMarkers.count == 2)
            #expect(controller.recordingMarkers[1].timecodeText == "10:00:10:00")

            controller.removeNearestMarker()
            #expect(controller.recordingMarkers.count == 1)
            #expect(controller.recordingMarkers[0].seconds == 5)
        }
    }

    @Test func markingIsANoOpWhenNothingIsRollingOrLoaded() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.viewerMode = .record
            controller.isRecording = false

            controller.addMarker()
            controller.removeNearestMarker()

            #expect(controller.recordingMarkers.isEmpty)
            #expect(controller.lastError == nil)
            #expect(controller.lastNotice == nil)
        }
    }

    /// Both exports bail before opening a save panel when there is nothing to
    /// write — the guard is what keeps them headless, and it is also the only
    /// feedback the operator gets.
    @Test func exportsRefuseAnEmptyDay() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.exportSelectsEDL()
            #expect(controller.lastError == L("edl_no_good_takes"))

            controller.lastError = nil
            controller.exportShiftReport(pdf: true)
            #expect(controller.lastError == L("report_no_takes"))
        }
    }
}
