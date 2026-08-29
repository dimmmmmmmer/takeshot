import AVFoundation
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Everything else the grid was invisible to.
///
/// `ControllerPlaybackEngineTests` covers the RULE — which of the three engines
/// owns the picture — and the four surfaces found by pulling on the first one.
/// This suite is the systematic sweep that followed: every place that asks
/// about `player`, `rawPlayer`, `playbackURL` or the playhead, walked rather
/// than stumbled into, and the ones where a grid changes the right answer.
///
/// They are ordered by CONSEQUENCE, which is also the order they were fixed in.
/// A marker verb writing into a take parked under a grid is data loss; a still
/// written of the wrong take is a wrong deliverable on disk; a scope tracing it
/// is a wrong measurement; a badge stating its raster is a wrong number. The
/// sweep's own finding is that the first three existed and only the last had
/// been looked for.
enum GridFixture {
    /// `count` takes in the panel, each backed by a file, oldest first.
    @MainActor
    static func seedTakes(_ controller: CaptureController, in root: URL,
                          count: Int) throws -> [Take] {
        let takes = (1...count).map { index in
            ControllerFixtures.take(
                named: "TS_A001C0\(index)", in: root, clip: index,
                recordedAt: Date(timeIntervalSinceNow: Double(index) * 10))
        }
        for take in takes {
            try ControllerFixtures.placeholder(for: take)
        }
        controller.takes = takes
        return takes
    }

    /// A grid up, with the single player left parked on a take — which is what
    /// `startSyncPlay` really leaves behind.
    @MainActor
    static func withGrid(
        _ body: (CaptureController, SyncPlayModel, Take) async throws -> Void
    ) async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            let takes = try seedTakes(controller, in: root, count: 2)
            // the single player is left holding a take, the way it is after an
            // operator reviews one and then selects two for comparison
            controller.playbackURL = takes[0].url
            controller.viewerMode = .playback
            controller.playbackFPS = 25
            controller.playbackStartTC = takes[0].startTimecode

            controller.selectedItems = Set(takes.map(\.url))
            controller.startSyncPlay()
            defer { controller.endSyncPlay() }
            let model = try #require(controller.syncPlay)
            try #require(controller.playbackURL != nil,
                         "the grid cleared the parked clip; this suite is moot")

            try await body(controller, model, takes[0])
        }
    }
}

@Suite @MainActor struct ControllerGridSweepTests {
    // MARK: - the rest of the marker menu

    /// The three items that act on the CLIP's marker list — go to previous, go
    /// to next, clear them all — are not enabled by the rule that enables
    /// DROPPING one.
    ///
    /// This is the sharpest thing the systematic sweep turned up, and it is the
    /// already-fixed delete one blast radius up. The submenu is gated on
    /// `canDropMarker`, which is `isReviewingSingleClip || isRecording` — and
    /// the second half is about the take being WRITTEN, not about the clip in
    /// the player. So with the camera rolling the submenu opens whatever the
    /// viewer shows, while these three read `playbackMarkers`: over a grid that
    /// was the parked take's list, and "clear all markers" took EVERY flag on a
    /// file the operator cannot see, then rewrote the sidecar to match.
    /// `removeNearestMarker` cost one marker within ±2 frames; this costs the
    /// take's.
    @Test func theMarkerMenuCannotClearAParkedTakesFlagsOverAGrid() async throws {
        try await GridFixture.withGrid { controller, _, parked in
            controller.takes[0].markers = [
                TakeMarker(seconds: 1, timecodeText: "10:00:01:00"),
                TakeMarker(seconds: 3, timecodeText: "10:00:03:00"),
            ]
            // the camera rolls while the operator compares — the video-assist
            // workflow, and the state that opens the submenu over a grid
            controller.isRecording = true
            controller.recordingStartDate = Date(timeIntervalSinceNow: -2)
            defer { controller.isRecording = false }
            try #require(controller.canDropMarker,
                         "the rolling camera does not open the submenu; this is moot")

            #expect(!controller.hasPlaybackMarkers,
                    "the menu offers the parked take's flags over a grid")

            controller.clearPlaybackMarkers()
            #expect(controller.takes[0].markers.count == 2,
                    "clear-all wiped the parked take \(parked.url.lastPathComponent)")

            // and the two that only MOVE take nothing either — the position
            // they would seek to belongs to a file that is not on screen
            controller.jumpToMarker(forward: true)
            controller.jumpToMarker(forward: false)
            #expect(controller.takes[0].markers.count == 2)

            // leaving the grid gives all three back: the guard is about the
            // grid, not about the marker list
            controller.endSyncPlay()
            #expect(controller.hasPlaybackMarkers, "the menu did not come back")
            controller.clearPlaybackMarkers()
            #expect(controller.takes[0].markers.isEmpty,
                    "the guard outlived the grid")
        }
    }

    /// The same guard, with no grid in sight.
    ///
    /// `isRecording` opens the submenu in RECORD mode too, over a clip left
    /// loaded from an earlier review — so the identical clear-all was offered
    /// for it, and the grid is not what made that wrong. Asserted separately
    /// because a fix that only knew about grids would leave this half standing.
    @Test func theMarkerMenuCannotClearALoadedClipWhileRecording() async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            let takes = try GridFixture.seedTakes(controller, in: root, count: 1)
            controller.takes[0].markers = [
                TakeMarker(seconds: 1, timecodeText: "10:00:01:00")
            ]
            // reviewed a moment ago, then the operator went back to the camera
            controller.playbackURL = takes[0].url
            controller.viewerMode = .record
            controller.isRecording = true
            controller.recordingStartDate = Date(timeIntervalSinceNow: -2)
            defer { controller.isRecording = false }
            try #require(controller.canDropMarker)

            #expect(!controller.hasPlaybackMarkers,
                    "the menu offers a clip's flags while the viewer is on the camera")
            controller.clearPlaybackMarkers()
            #expect(controller.takes[0].markers.count == 1,
                    "clear-all wiped a clip that is not on screen")
        }
    }

    // MARK: - the release list

    /// Trashing a take that is a TILE ends the comparison.
    ///
    /// `trashAndRelease` lets go of every reference by name — the selection, the
    /// in/out table, the single player, the RAW engine, the compare slot — and
    /// the grid was the one holder missing from that list, because
    /// `playbackURL` names none of its 2–4 files. The reachable case is the
    /// workflow rather than a corner: a grid is built FROM the selection and
    /// `trashSelection` walks that same selection, so comparing four takes and
    /// binning the three that failed left the grid decoding and transport-locking
    /// files that were already in the Trash and already out of the CSV.
    @Test func trashingATakeThatIsOnTheGridEndsTheComparison() async throws {
        try await GridFixture.withGrid { controller, model, parked in
            try #require(controller.syncPlayShows(model.tiles[0].source.url))
            let doomed = try #require(
                controller.takes.first { $0.url == model.tiles[0].source.url })

            controller.deleteTake(doomed)

            #expect(controller.syncPlay == nil,
                    "the grid is still showing a take that is in the Trash")
            #expect(!controller.takes.contains { $0.url == doomed.url })
            _ = parked
        }
    }

    /// …and trashing a take the grid is NOT showing leaves the comparison up.
    /// The release is about the files the grid holds, not about deleting.
    @Test func trashingATakeTheGridIsNotShowingLeavesItUp() async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            let takes = try GridFixture.seedTakes(controller, in: root, count: 3)
            controller.viewerMode = .playback
            controller.selectedItems = Set(takes.prefix(2).map(\.url))
            controller.startSyncPlay()
            defer { controller.endSyncPlay() }
            try #require(controller.syncPlay != nil)
            try #require(!controller.syncPlayShows(takes[2].url))

            controller.deleteTake(takes[2])

            #expect(controller.syncPlay != nil,
                    "an unrelated delete closed the comparison")
        }
    }

    // MARK: - the grab

    /// Grab Frame over a grid writes nothing, and the control says so first.
    ///
    /// The grid is 2–4 pictures and the app composites none of them, so there is
    /// no frame to write — but `playbackURL` still names the parked take, so the
    /// bare `playbackURL != nil` was true and the grab put a PNG of the WRONG
    /// take beside the footage, named and stamped like any other deliverable.
    /// The parked clip is a REAL movie here, not a placeholder, and that is the
    /// point of the fixture: with a placeholder the grab fails on the decode and
    /// the test passes for the wrong reason — it proves the app tried, not that
    /// it wrote nothing. A decodable clip in the single player is what makes the
    /// unguarded press actually land a PNG of the wrong take on disk.
    @Test func aGrabOverAGridWritesNoStill() async throws {
        let media = try MediaFixtures.makeDirectory("grab-grid")
        defer { try? FileManager.default.removeItem(at: media) }
        let parked = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("parked.mov"), frames: 12)

        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }
            let takes = try GridFixture.seedTakes(controller, in: root, count: 2)

            // the workflow exactly: review a take, then select two to compare
            controller.play(url: parked)
            try #require(controller.player.currentItem != nil)
            controller.selectedItems = Set(takes.map(\.url))
            controller.startSyncPlay()
            defer { controller.endSyncPlay() }
            try #require(controller.syncPlay != nil)
            try #require(controller.playbackURL == parked,
                         "the grid cleared the parked clip; this test is moot")

            #expect(!controller.canGrabFrame,
                    "the camera button is live over a grid")

            controller.grabFrame()
            let hotkeys = HotkeyManager(defaults: InMemoryDefaults())
            hotkeys.perform(.grabFrame, controller: controller)

            // the full budget spent proves the write did NOT happen, rather
            // than catching it before it landed
            let wrote = await ControllerWait.until(
                { controller.recentlyAddedURL != nil }, timeout: .seconds(3))
            #expect(!wrote, "a still of the parked take was written")
            #expect(controller.lastError == nil,
                    "the grid press said something; it matches a greyed control")
        }
    }

    /// The same grab from the OTHER arm — and this is the arm an operator
    /// actually reaches on set, because the camera is usually rolling while a
    /// comparison goes up. `canGrabFrame` read
    /// `isCapturing || (playbackURL != nil && syncPlay == nil)`, so the grid
    /// excluded only the PLAYBACK arm: with the camera rolling the button
    /// stayed lit and the hotkey stayed live over a grid, while `grabFrame()`
    /// opened with `guard syncPlay == nil` and returned. A lit button, a live
    /// hotkey, no still and no toast to say why — the control and the method
    /// answering different questions, which is the shape every defect in this
    /// suite has. The rolling-with-no-grid case is asserted FIRST so a fix that
    /// simply darkens the button forever cannot pass.
    @Test func aGrabOverAGridIsDarkWhileTheCameraRolls() async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }
            let takes = try GridFixture.seedTakes(controller, in: root, count: 2)

            controller.isCapturing = true
            #expect(controller.canGrabFrame,
                    "a rolling camera with no grid must still grab")

            controller.selectedItems = Set(takes.map(\.url))
            controller.startSyncPlay()
            defer { controller.endSyncPlay() }
            try #require(controller.syncPlay != nil)
            try #require(controller.isCapturing,
                         "the grid stopped the camera; this test is moot")

            #expect(!controller.canGrabFrame,
                    "the camera button is lit over a grid while rolling")

            controller.grabFrame()
            let hotkeys = HotkeyManager(defaults: InMemoryDefaults())
            hotkeys.perform(.grabFrame, controller: controller)

            let wrote = await ControllerWait.until(
                { controller.recentlyAddedURL != nil }, timeout: .seconds(3))
            #expect(!wrote, "a still was written over a comparison")
            #expect(controller.lastError == nil,
                    "the grid press said something; it matches a greyed control")
        }
    }

    // MARK: - the readouts

    /// The scopes measure the picture on screen or nothing, never the parked one.
    ///
    /// A wrong TIMECODE is a wrong number; a wrong SCOPE is a wrong measurement,
    /// and it is the one an operator judges exposure by. Both playback analyzers
    /// asked `viewerMode == .playback`, which a grid satisfies, so a waveform
    /// left open went on tracing the parked take's paused frame under four
    /// others. Keeping the last trace — right when a panel closes over a picture
    /// that is still there — is wrong here, where the picture it describes has
    /// gone.
    /// Driven through the REAL analyzer rather than a seeded value, and the
    /// waveform is switched on BEFORE the grid: with the scopes off,
    /// `scopesEnabled` is false whatever the rule says and every assertion here
    /// passes for a reason that has nothing to do with the grid. A real clip is
    /// played until it has actually produced a trace, so what the grid has to
    /// clear is a measurement that genuinely exists.
    @Test func theScopesStopMeasuringTheParkedTakeOverAGrid() async throws {
        let media = try MediaFixtures.makeDirectory("scopes-grid")
        defer { try? FileManager.default.removeItem(at: media) }
        let parked = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("parked.mov"), frames: 30)

        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }
            let takes = try GridFixture.seedTakes(controller, in: root, count: 2)

            controller.play(url: parked)
            controller.showScopesOverlay = true
            controller.playbackTap.queue.sync {} // the setters are queue-async
            try #require(controller.playbackTap.scopesEnabled,
                         "the analyzer never came on; this test is moot")
            let traced = await ControllerWait.untilWritten {
                controller.scopes.data != nil
            }
            try #require(traced, "the parked clip never produced a trace")

            controller.selectedItems = Set(takes.map(\.url))
            controller.startSyncPlay()
            defer { controller.endSyncPlay() }
            try #require(controller.playbackURL == parked,
                         "the grid cleared the parked clip; this test is moot")

            controller.playbackTap.queue.sync {}
            #expect(!controller.playbackTap.scopesEnabled,
                    "the scopes are still analyzing the parked take")
            #expect(!controller.playbackTap.running,
                    "the parked tap is still decoding under the grid")
            #expect(controller.scopes.data == nil,
                    "the last trace of the parked take is still on the panel")

            // …and a trace analyzed a moment before the grid opened does not
            // creep back in over it: the tap delivers on the main queue, so the
            // clear alone would only win a race
            let creptBack = await ControllerWait.until(
                { controller.scopes.data != nil }, timeout: .seconds(1))
            #expect(!creptBack, "a stale measurement landed under the grid")

            // and both come back with the single player's picture
            controller.endSyncPlay()
            controller.playbackTap.queue.sync {}
            #expect(controller.playbackTap.running,
                    "the tap did not restart when the grid closed")
            #expect(controller.playbackTap.scopesEnabled,
                    "the analyzer did not come back")
        }
    }

    /// The raster-and-rate badge states no format over a grid rather than the
    /// parked take's — the neighbour of the timecode badge, wrong the same way.
    ///
    /// It must not fall through to the LIVE format either: that would trade a
    /// wrong clip's number for a wrong source's, on the readout the brief puts
    /// top right.
    @Test func theFormatBadgeStatesNoFormatOverAGrid() async throws {
        try await GridFixture.withGrid { controller, _, _ in
            controller.playbackFormatText = "2160p24"
            #expect(controller.playbackFormatBadgeText == formatFallbackText,
                    "the badge shows \(controller.playbackFormatBadgeText ?? "nil")")
            #expect(controller.playbackFormatBadgeText != "2160p24")

            controller.endSyncPlay()
            #expect(controller.playbackFormatBadgeText == "2160p24",
                    "the single player's format did not come back")
        }
    }

    /// The phone's marker count follows the press it claims to describe.
    ///
    /// Its own comment says it mirrors `addMarker`'s routing branch for branch;
    /// it was written as `viewerMode == .playback, playbackURL != nil` while
    /// `addMarker` moved to `isReviewingSingleClip`, and the two then disagreed
    /// about exactly one state. Over a grid with the camera rolling the footer
    /// counted the parked take's flags while the press was landing on the take
    /// being written — the "shows 0 even when I place one" report, from the
    /// other side.
    @Test func thePhoneCountsWhatAMarkerPressWouldLandOn() async throws {
        try await GridFixture.withGrid { controller, _, _ in
            controller.takes[0].markers = [
                TakeMarker(seconds: 1, timecodeText: "10:00:01:00")
            ]
            controller.isRecording = true
            controller.recordingStartDate = Date(timeIntervalSinceNow: -2)
            defer { controller.isRecording = false }

            controller.perform(remote: .marker)

            #expect(controller.recordingMarkers.count == 1,
                    "the press did not reach the take being written")
            let counted = controller.remoteStatus().markerCount
            #expect(counted == 1,
                    "the phone counts \(counted), the parked take's list")
        }
    }
}
