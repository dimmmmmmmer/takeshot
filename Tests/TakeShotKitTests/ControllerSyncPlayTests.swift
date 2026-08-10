import AVFoundation
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Entering and leaving sync-play through the controller: what the selection
/// allows, what a session is built of, and what throws it out again.
@Suite @MainActor struct ControllerSyncPlayTests {
    /// `count` takes in the panel, each backed by a file, oldest first.
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

    /// The gate: 2–4 selected takes and nothing else opens the menu item;
    /// one take is not a comparison and five do not fit the grid.
    @Test func selectionGatesSyncPlayAtTwoToFourTakes() async throws {
        try await ControllerHarness.run { controller, root in
            let takes = try seedTakes(controller, in: root, count: 5)

            for (selected, allowed) in [(0, false), (1, false), (2, true),
                                        (3, true), (4, true), (5, false)] {
                controller.selectedItems = Set(takes.prefix(selected).map(\.url))
                #expect(controller.canStartSyncPlay == allowed,
                        "\(selected) takes selected")
            }

            // a refused start changes nothing
            controller.selectedItems = [takes[0].url]
            controller.startSyncPlay()
            #expect(controller.syncPlay == nil, "one take must not open a grid")

            controller.selectedItems = Set(takes.map(\.url))
            controller.startSyncPlay()
            #expect(controller.syncPlay == nil, "five takes must not open a grid")
        }
    }

    /// Foreign files in the selection are not takes: they neither count
    /// against the 2–4 nor end up in the grid.
    @Test func foreignFilesInTheSelectionAreIgnored() async throws {
        try await ControllerHarness.run { controller, root in
            let takes = try seedTakes(controller, in: root, count: 2)
            let foreign = root.appendingPathComponent("visitor.mov")
            try Data([0x00]).write(to: foreign)
            controller.otherFiles = [foreign]

            controller.selectedItems = Set(takes.map(\.url) + [foreign])
            #expect(controller.canStartSyncPlay)
            #expect(controller.syncPlayTakes.map(\.url) == takes.map(\.url))

            controller.startSyncPlay()
            defer { controller.endSyncPlay() }
            let model = try #require(controller.syncPlay)
            #expect(model.tiles.count == 2)
        }
    }

    /// A session is one player and one tap PER take — separate instances, in
    /// shooting order — and entering it lands the viewer in playback mode with
    /// the single-clip player silenced.
    @Test func aSessionOwnsOnePlayerAndOneTapPerTake() async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            let takes = try seedTakes(controller, in: root, count: 3)
            // selected newest-first on purpose: the grid orders by recordedAt
            controller.selectedItems = Set(takes.reversed().map(\.url))

            controller.startSyncPlay()
            defer { controller.endSyncPlay() }
            let model = try #require(controller.syncPlay)

            #expect(model.tiles.count == 3)
            #expect(model.tiles.map(\.source.url) == takes.map(\.url),
                    "tiles must read in shooting order, oldest first")
            #expect(Set(model.tiles.map { ObjectIdentifier($0.player) }).count == 3,
                    "two tiles share an AVPlayer")
            #expect(Set(model.tiles.map { ObjectIdentifier($0.tap) }).count == 3,
                    "two tiles share a frame tap")
            #expect(controller.viewerMode == .playback)
            #expect(controller.player.rate == 0,
                    "the single-clip player kept running under the grid")
            #expect(controller.isReviewingClip,
                    "the transport menu must stay live for the master transport")
        }
    }

    /// Leaving the mode — explicitly, by opening a take in the single player,
    /// or by switching to record — tears the session down.
    @Test func everyExitPathEndsTheSession() async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            let takes = try seedTakes(controller, in: root, count: 3)
            controller.selectedItems = Set(takes.prefix(2).map(\.url))

            controller.startSyncPlay()
            #expect(controller.syncPlay != nil)
            controller.endSyncPlay()
            #expect(controller.syncPlay == nil)

            controller.startSyncPlay()
            #expect(controller.syncPlay != nil)
            controller.play(url: takes[2].url)
            #expect(controller.syncPlay == nil,
                    "opening a single take must supersede the comparison")
            MediaFixtures.stopPlayback(controller)

            controller.startSyncPlay()
            #expect(controller.syncPlay != nil)
            controller.viewerMode = .record
            #expect(controller.syncPlay == nil,
                    "record mode must not keep a comparison alive")
        }
    }

    /// The shared transport verbs drive the session while it is up, and the
    /// loop-point keys do not leak through to the hidden single player.
    @Test func transportVerbsRouteToTheSession() async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            let takes = try seedTakes(controller, in: root, count: 2)
            controller.selectedItems = Set(takes.map(\.url))

            controller.startSyncPlay()
            defer { controller.endSyncPlay() }
            let model = try #require(controller.syncPlay)

            controller.togglePlayPause()
            #expect(model.isPlaying, "space must drive the master transport")
            controller.togglePlayPause()
            #expect(!model.isPlaying)

            model.seek(to: 1)
            controller.stepPlayback(forward: false)
            #expect(abs(model.position.currentTime - (1 - model.frameDuration))
                    < 1e-9, "a step must move the master playhead one frame")

            let before = controller.transport.inPoint
            controller.toggleLoopPoint(out: false)
            #expect(controller.transport.inPoint == before,
                    "a loop key leaked through to the hidden single player")
        }
    }

    /// What the menu items that act on ONE clip's timeline are enabled by.
    ///
    /// The test above proves the loop key does nothing under the grid — and
    /// "does nothing" was the whole complaint: the Playback menu's in/out
    /// points, its loop switch and its five marker items were all enabled the
    /// moment `isReviewingClip` went true, which the grid makes true. So the
    /// operator got live-looking items that either refused silently
    /// (`toggleLoopPoint`) or went through to the single player parked
    /// underneath — `loopPlayback` looping a clip nobody can see, and
    /// `addMarker` writing into it at the paused playhead.
    ///
    /// This is the enablement, asked from the states an operator passes
    /// through, because a menu's `.disabled(…)` cannot be measured from a
    /// rendered view and the rule is the thing worth pinning anyway.
    @Test func theGridEnablesTheTransportButNotOneClipsTimeline() async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            let takes: [Take] = try seedTakes(controller, in: root, count: 2)

            // fresh: neither, and in particular nothing to mark
            #expect(!controller.isReviewingClip)
            #expect(!controller.isReviewingSingleClip)
            #expect(!controller.isRecording,
                    "the fixture is rolling — the marker gate proves nothing")

            // one clip in the single player: both, so the loop and the markers
            // are offered exactly where they mean something
            controller.viewerMode = .playback
            controller.playbackURL = takes[0].url
            #expect(controller.isReviewingClip)
            #expect(controller.isReviewingSingleClip)

            // the grid: the transport still answers (it routes to the master),
            // the one-clip items must not
            controller.selectedItems = Set(takes.map(\.url))
            controller.startSyncPlay()
            defer { controller.endSyncPlay() }
            #expect(controller.syncPlay != nil,
                    "the grid never opened — the rest of this proves nothing")
            #expect(controller.isReviewingClip,
                    "the grid stopped answering the transport keys")
            #expect(!controller.isReviewingSingleClip,
                    "the grid still enables the loop range and the markers of the clip underneath it")

            // and the stale URL is exactly the trap: it is still set, which is
            // what made the marker items look live and land in the wrong file
            #expect(controller.playbackURL != nil,
                    "no stale clip underneath — this test cannot see the trap")

            // the compare row is the same question one surface along: it drives
            // the single player's composite, which is not under the grid
            #expect(!controller.showsCompareBar,
                    "the compare row is over the grid, whose composite it cannot drive")

            controller.endSyncPlay()
            #expect(controller.showsCompareBar,
                    "leaving the grid left the compare row off the clip it can drive")
            #expect(controller.isReviewingSingleClip,
                    "leaving the grid left the single clip's own items greyed")
        }
    }
}
