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

    // MARK: - the color a marker is born with (owner item 24)

    /// Colors used to be reachable only after a marker existed. The swatch in
    /// the marker controls sets the color of the NEXT one, in review and while a
    /// take rolls alike.
    @Test func newMarkersAreBornInTheChosenColor() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try loadedTake(controller, in: root)
            #expect(controller.newMarkerColor == TakeMarker.colors[0])

            controller.cycleNewMarkerColor()
            let chosen = controller.newMarkerColor
            #expect(chosen == TakeMarker.colors[1])

            controller.addMarker()
            #expect(controller.takes[0].markers[0].color == chosen)

            // and the same color while recording, where the marker is queued
            controller.viewerMode = .record
            controller.isRecording = true
            controller.recordingStartDate = Date().addingTimeInterval(-3)
            controller.addMarker()
            #expect(controller.recordingMarkers.last?.color == chosen)
        }
    }

    /// The swatch walks the palette and wraps, so seven clicks come back to the
    /// start — the operator never has to know how long the list is.
    @Test func theSwatchCyclesThePaletteAndWraps() async throws {
        try await ControllerHarness.run { controller, _ in
            var seen: [String] = []
            for _ in TakeMarker.colors.indices {
                seen.append(controller.newMarkerColor)
                controller.cycleNewMarkerColor()
            }
            #expect(seen == TakeMarker.colors)
            #expect(controller.newMarkerColor == TakeMarker.colors[0])
        }
    }

    /// The convention is a unit's, not a session's: it has to survive a
    /// relaunch, which for the controller means the settings blob.
    @Test func theChosenColorIsPersistedAndSurvivesADecode() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.newMarkerColor = "cyan"
            #expect(controller.settings.review.defaultMarkerColor == "cyan")

            let reloaded = CaptureSettings.loaded(from: controller.defaults)
            #expect(reloaded.review.defaultMarkerColor == "cyan")

            // the default writes NO field, so an untouched install stays clean
            controller.newMarkerColor = TakeMarker.colors[0]
            #expect(controller.settings.review.defaultMarkerColor == nil)
            #expect(controller.newMarkerColor == TakeMarker.colors[0])
        }
    }

    /// A settings blob from a downgrade or a hand edit must not put a color the
    /// palette has no swatch for onto every marker of the day.
    @Test func aColorOutsideThePaletteFallsBackToTheDefault() async throws {
        try await ControllerHarness.run(configure: {
            $0.review.defaultMarkerColor = "chartreuse"
        }, { controller, _ in
            #expect(controller.newMarkerColor == TakeMarker.colors[0])
            controller.cycleNewMarkerColor()
            #expect(controller.newMarkerColor == TakeMarker.colors[1])
        })
    }

    // MARK: - the marker's own color on its caption (owner item 23)

    /// Every toast that names ONE marker is shown in that marker's color; the
    /// blanket green said nothing about the marker just placed, and the color IS
    /// the convention the crew reads.
    @Test func markerToastsCarryTheMarkersOwnColor() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try loadedTake(controller, in: root)
            controller.newMarkerColor = "red"

            controller.addMarker()
            #expect(controller.lastNoticeTint == markerColor("red"))

            controller.takes[0].markers = [
                TakeMarker(seconds: 2, timecodeText: "10:00:02:00",
                           color: "blue", note: "gate"),
            ]
            controller.jumpToMarker(forward: true)
            #expect(controller.lastNoticeTint == markerColor("blue"))

            controller.removeNearestMarker() // ±2 frames of the seek target
            #expect(controller.lastNoticeTint == markerColor("blue"))
        }
    }

    /// …and a marker's color must not outlive its toast: the next, unrelated
    /// notice is the neutral green again.
    @Test func theMarkerColorDoesNotLeakOntoTheNextNotice() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try loadedTake(controller, in: root)
            controller.newMarkerColor = "purple"
            controller.addMarker()
            #expect(controller.lastNoticeTint != nil)

            controller.lastNotice = "something else entirely"
            #expect(controller.lastNoticeTint == nil)
        }
    }

    /// Every export bails before opening a save panel when there is nothing to
    /// write — the guard is what keeps them headless, and it is also the only
    /// feedback the operator gets.
    @Test func exportsRefuseAnEmptyDay() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.exportSelectsEDL()
            #expect(controller.lastError == L("edl_no_good_takes"))

            controller.lastError = nil
            controller.exportALE()
            #expect(controller.lastError == L("ale_no_takes"))

            controller.lastError = nil
            controller.exportShiftReport(pdf: true)
            #expect(controller.lastError == L("report_no_takes"))
        }
    }

    /// The ALE is the LOG, not the cut: it carries every take, including the
    /// ones nobody circled and the ones marked bad. An assistant building a bin
    /// needs the rejected takes in it — that a take was rejected is metadata
    /// about the day, not a reason to hide it from the Avid.
    @Test func theALECarriesEveryTakeNotOnlyTheSelects() async throws {
        try await ControllerHarness.run { controller, root in
            var good = ControllerFixtures.take(named: "A", in: root, clip: 1)
            good.rating = .good
            var bad = ControllerFixtures.take(named: "B", in: root, clip: 2)
            bad.rating = .bad
            let unrated = ControllerFixtures.take(named: "C", in: root, clip: 3)
            controller.takes = [good, bad, unrated]

            let ale = try #require(
                ALEExporter.ale(takes: controller.takes,
                                format: controller.signalFormat))
            #expect(ale.contains("A.mov"))
            #expect(ale.contains("B.mov"))
            #expect(ale.contains("C.mov"))
            // and the EDL beside it still carries the circled take only
            #expect(EDLExporter.selectsEDL(
                takes: controller.takes.filter { $0.rating == .good },
                title: "t")?.contains("B.mov") == false)
        }
    }
}
