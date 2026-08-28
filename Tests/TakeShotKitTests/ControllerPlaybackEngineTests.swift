import AVFoundation
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Which engine is driving the picture under review, and the two readouts that
/// used to answer it for themselves.
///
/// Playback is three engines, not one, and the sync-play GRID is the case every
/// surface forgets: `startSyncPlay` pauses the single player and leaves it
/// holding the clip that was open before, so every question asked of
/// `player`/`rawPlayer` still has a plausible-looking answer while the grid is
/// on screen. The shared-rule wave found the transport bar and the toast
/// disagreeing about exactly this; these are the next two.
@Suite @MainActor struct ControllerPlaybackEngineTests {
    private func seedTakes(_ controller: CaptureController, in root: URL,
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

    /// A grid up, with the single player left parked on `parked` — which is
    /// what `startSyncPlay` really leaves behind.
    private func withGrid(
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

    // MARK: - the rule

    /// The precedence, over all four combinations of the two engines that can
    /// pre-empt the single player.
    ///
    /// The grid outranks the RAW engine and that is the content: a raw player
    /// stays LOADED underneath a grid (`startSyncPlay` pauses it, it does not
    /// let go of it), so answering `.raw` there would be the same parked-engine
    /// mistake one door along.
    @Test func theGridOutranksEveryParkedEngine() {
        #expect(PlaybackEngine.current(hasGrid: true, hasRawPlayer: true) == .grid)
        #expect(PlaybackEngine.current(hasGrid: true, hasRawPlayer: false) == .grid)
        #expect(PlaybackEngine.current(hasGrid: false, hasRawPlayer: true) == .raw)
        #expect(PlaybackEngine.current(hasGrid: false, hasRawPlayer: false)
                == .single)
    }

    /// The engine and the transport VERBS name the same three in the same
    /// order.
    ///
    /// This is the invariant that broke. `togglePlayPause`, `skipPlayback` and
    /// `stepPlayback` route grid → raw → single; the two readouts asked
    /// raw → single and skipped the grid entirely. Held against each other here
    /// rather than restated, so a precedence that agrees today and not tomorrow
    /// turns something red.
    @Test func theEngineAgreesWithHowTheTransportVerbsRoute() async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            let takes = try seedTakes(controller, in: root, count: 2)
            controller.viewerMode = .playback

            // single: the verb reaches the AVPlayer transport
            controller.playbackURL = takes[0].url
            #expect(controller.playbackEngine == .single)

            // raw: a real RAW clip claims the picture, and the verb reaches it
            let (raw, _) = try RawClipFixtures.player(frames: 4, in: root)
            defer { controller.rawPlayer = nil }
            controller.rawPlayer = raw
            #expect(controller.playbackEngine == .raw)
            controller.togglePlayPause()
            #expect(raw.isPlaying, "the verb did not reach the RAW engine")
            controller.togglePlayPause()

            // grid: it pre-empts the raw player, which is still loaded
            controller.selectedItems = Set(takes.map(\.url))
            controller.startSyncPlay()
            defer { controller.endSyncPlay() }
            let model = try #require(controller.syncPlay)
            #expect(controller.rawPlayer != nil,
                    "the grid let go of the raw player; the precedence is moot")
            #expect(controller.playbackEngine == .grid)
            controller.togglePlayPause()
            #expect(model.isPlaying, "the verb did not reach the grid")
            #expect(!raw.isPlaying, "the verb reached the parked RAW engine")
            controller.togglePlayPause()
        }
    }

    // MARK: - the timecode badge

    /// Over a grid the badge says it has no timecode, instead of stating the
    /// parked clip's.
    ///
    /// 2–4 takes with 2–4 start timecodes on one master timeline have no single
    /// timecode — which is why the grid's own transport shows elapsed time and
    /// each TILE carries its own TC. What the badge used to show was
    /// `player.currentTime()` of a player that is paused and holding a
    /// different take: a confident, wrong number on the readout the brief puts
    /// top left.
    @Test func theBadgeShowsNoTimecodeOverAGridRatherThanTheParkedClips() async throws {
        try await withGrid { controller, model, parked in
            #expect(controller.playbackTimecodeText == timecodeFallbackText,
                    "the badge shows \(controller.playbackTimecodeText) over a grid")

            // and what it is NOT showing is the parked take's own timecode —
            // which is what it said before, and is a real timecode from a real
            // file that is not on screen
            let parkedTC = try #require(parked.startTimecode).description
            #expect(controller.playbackTimecodeText != parkedTC)

            // the tiles still carry theirs: the information is not lost, it is
            // shown where it means something. The exact offset arithmetic is
            // `SyncPlaySchedule`'s to pin; what matters here is that the tile
            // states a timecode at all, so the badge is giving up nothing.
            #expect(model.tileTimecodeText(0) != timecodeFallbackText,
                    "the tile has no timecode either")
            #expect(model.tileTimecodeText(0).hasPrefix("10:"),
                    "the tile lost the take's hour: \(model.tileTimecodeText(0))")

            // leaving the grid gives the badge back
            controller.endSyncPlay()
            #expect(controller.playbackTimecodeText == parkedTC,
                    "the single player's readout did not come back")
        }
    }

    /// …and the 10 Hz tick that re-reads it runs while the grid is rolling.
    ///
    /// Fixing the text alone would have changed nothing visible: the badge only
    /// re-renders when `playbackIsRunning` says something is moving, and that
    /// asked two of the three engines, so over a grid it went still.
    @Test func theBadgeClockRunsWhileTheGridIsRolling() async throws {
        try await withGrid { controller, model, _ in
            #expect(!controller.playbackIsRunning,
                    "a paused grid is not running")

            controller.togglePlayPause()
            try #require(model.isPlaying)
            #expect(controller.playbackIsRunning,
                    "the badge clock is still while the grid plays")

            controller.togglePlayPause()
            #expect(!model.isPlaying)
            #expect(!controller.playbackIsRunning)
        }
    }

    /// The same clock over the other two engines, so the arm above is not the
    /// only one that works.
    @Test func theBadgeClockFollowsTheSingleAndRawEnginesToo() async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            controller.viewerMode = .playback
            #expect(!controller.playbackIsRunning)

            let (raw, _) = try RawClipFixtures.player(frames: 6, in: root)
            defer { controller.rawPlayer = nil }
            controller.rawPlayer = raw
            #expect(!controller.playbackIsRunning)
            raw.play()
            #expect(controller.playbackIsRunning,
                    "a rolling RAW clip does not move the badge")
            raw.pause()
            #expect(!controller.playbackIsRunning)
        }
    }

    // MARK: - the marker press

    /// A marker press over a grid does not land in the take the single player
    /// is parked on.
    ///
    /// `canDropMarker` has said since the long-tail wave that "the sync-play
    /// grid is not [a timeline a flag belongs on]", and that reached the menu
    /// item and never the method — so the two surfaces that do not go through
    /// the menu, the hotkey and the phone, still wrote a marker into a file the
    /// operator cannot see, at the paused player's position.
    /// `playbackAcceptsMarkers` cannot catch it: `playbackURL` is exactly where
    /// it was.
    @Test func aMarkerPressOverAGridLandsNowhere() async throws {
        try await withGrid { controller, _, parked in
            try #require(controller.playbackAcceptsMarkers,
                         "the parked take would accept a marker; this is the trap")
            try #require(!controller.canDropMarker,
                         "the grid is supposed to be excluded")

            controller.addMarker()

            #expect(controller.takes[0].markers.isEmpty,
                    "a marker landed in the parked take \(parked.url.lastPathComponent)")
            #expect(controller.playbackMarkers.isEmpty)

            // …and the same press through the two surfaces that bypass the menu
            let hotkeys = HotkeyManager(defaults: InMemoryDefaults())
            hotkeys.perform(.addMarker, controller: controller)
            controller.perform(remote: .marker)
            #expect(controller.takes[0].markers.isEmpty,
                    "the hotkey or the phone still marks the parked take")

            // leaving the grid gives the press back — the guard is about the
            // grid and not about markers
            controller.endSyncPlay()
            controller.addMarker()
            #expect(controller.takes[0].markers.count == 1,
                    "the guard outlived the grid")
        }
    }

    /// …and neither does the press that DELETES one.
    ///
    /// The half that costs something. `removeNearestMarker` read the parked
    /// player's position and the parked take's list, and its ±2 frame reach
    /// makes that reachable rather than theoretical: an operator who marks a
    /// moment, then selects that take and three others to compare, has left the
    /// playhead sitting exactly on the marker they just placed. The remove
    /// hotkey over the grid then took it, out of a file not on screen, with a
    /// toast naming a timecode from somewhere else.
    @Test func theRemoveMarkerPressOverAGridTakesNothing() async throws {
        try await withGrid { controller, _, _ in
            // a marker exactly under the parked playhead — the worst case
            controller.takes[0].markers = [
                TakeMarker(seconds: 0, timecodeText: "10:00:00:00")
            ]
            try #require(controller.playbackMarkers.count == 1)

            controller.removeNearestMarker()
            let hotkeys = HotkeyManager(defaults: InMemoryDefaults())
            hotkeys.perform(.removeMarker, controller: controller)

            #expect(controller.takes[0].markers.count == 1,
                    "the remove press took a marker out of the parked take")

            // and it comes back once the grid is gone — the guard is about the
            // grid, not about deleting
            controller.endSyncPlay()
            controller.removeNearestMarker()
            #expect(controller.takes[0].markers.isEmpty,
                    "the guard outlived the grid")
        }
    }

    /// The position every marker verb reads is the grid's own master playhead,
    /// not the parked player's.
    ///
    /// No caller depends on this today — they are all gated to the single clip
    /// — and it is asserted anyway, because "wrong but currently unreachable"
    /// is exactly what `canDropMarker` was before the hotkey found it.
    @Test func thePlaybackPositionFollowsTheGridsOwnPlayhead() async throws {
        try await withGrid { controller, model, _ in
            #expect(controller.playbackPositionSeconds == 0)

            model.seek(to: 1.5)
            let position: Double = controller.playbackPositionSeconds
            #expect(abs(position - 1.5) < 1e-9,
                    "the position is \(position), not the grid's 1.5")
        }
    }

    /// Over a grid with the camera ROLLING the press falls through to the
    /// recording, which is the other half of `canDropMarker` and is a real
    /// timeline. The guard must not cost the operator the one marker that
    /// matters most.
    @Test func aMarkerPressOverAGridWhileRollingMarksTheTake() async throws {
        try await withGrid { controller, _, _ in
            controller.isRecording = true
            controller.recordingStartDate = Date(timeIntervalSinceNow: -2)
            defer { controller.isRecording = false }
            #expect(controller.canDropMarker,
                    "a rolling camera is a timeline whatever is on the viewer")

            controller.addMarker()

            #expect(controller.recordingMarkers.count == 1,
                    "the marker did not reach the take being written")
            #expect(controller.takes[0].markers.isEmpty,
                    "it reached the parked take as well")
        }
    }

    /// The menu item and the method are enabled by the same rule.
    ///
    /// The menu bar spelled `canDropMarker` out a second time, which is how the
    /// method came to be missing it. Asserted across the states rather than by
    /// reading the source, so it survives either one being rewritten.
    @Test func theMenuItemAndTheMethodAgreeAboutTheGrid() async throws {
        try await withGrid { controller, _, _ in
            let model = MenuBarModel(controller: controller)
            let marker = try #require(
                model.items.first { $0.command == .addMarker })
            #expect(!marker.enabled, "the menu offers a marker over a grid")
            #expect(marker.enabled == controller.canDropMarker)

            controller.endSyncPlay()
            let enabled = try #require(
                model.items.first { $0.command == .addMarker })
            #expect(enabled.enabled, "the menu did not come back")
            #expect(enabled.enabled == controller.canDropMarker)
        }
    }
}
