import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **The wiring half: does the right identity reach the composer at all.**
///
/// `MultiviewIdentityTests` checks what the composer DOES with an identity —
/// the type size, the caching, the geometry. This checks the other end: that
/// the live grid hands it cameras and the comparison grid hands it takes, from
/// the same expressions the operator's own screen reads, and that the clocks
/// follow the thing they claim to follow.
///
/// Read off `MultiviewComposer.heldIdentity(camera:)` rather than out of the
/// picture, for the reason that suite states at length: a name is glyphs, and
/// this project does not assert on glyphs.
@Suite @MainActor struct ControllerGridIdentityTests {
    // MARK: - the comparison grid

    /// **Every tile says which TAKE it is**, which is the whole point of the
    /// change on this surface: a director watching four takes could not tell
    /// which was which, because the names were SwiftUI chrome on the operator's
    /// screen and the composed picture carried none of it.
    ///
    /// Asserted against the model's own `source.name` rather than against a
    /// literal, because the claim is that ONE string reaches both surfaces —
    /// the tile's on-screen corner and the burned-in plate — and a literal
    /// repeated here would pass even if the two had drifted apart. The literal
    /// is checked once, on the first tile, so the whole thing cannot be green
    /// against two empty strings.
    @Test func everyComparisonTileSaysWhichTakeItIs() async throws {
        try await GridOutputProbe.withGridAndBoard(tiles: 2) { controller, model, _, _ in
            let composer: MultiviewComposer =
                try #require(controller.mirrors.syncGridComposer)
            let first: String = model.tiles[0].source.name
            #expect(first == "TS_A001C01", "the fixture take is named \(first)")
            for index in model.tiles.indices {
                let held = composer.heldIdentity(camera: index)
                #expect(held == .take(label: model.tiles[index].source.name),
                        "tile \(index) reached the picture as \(held as Any)")
            }
        }
    }

    /// **A comparison tile is a take and never a camera**, stated separately
    /// because it is the failure that would look fine.
    ///
    /// `.camera(label:recording:signalPresent:)` with `recording` hard-coded
    /// false would draw
    /// exactly the same picture today and be wrong the moment anybody asked the
    /// identity a question — and it is the shortcut a single flattened struct
    /// would have made the natural thing to write.
    @Test func aComparisonTileIsATakeAndNeverACamera() async throws {
        try await GridOutputProbe.withGridAndBoard(tiles: 2) { controller, model, _, _ in
            let composer: MultiviewComposer =
                try #require(controller.mirrors.syncGridComposer)
            for index in model.tiles.indices {
                let identity = composer.heldIdentity(camera: index)
                #expect(identity?.showsRecordingLamp == false,
                        "tile \(index) can light a REC lamp")
                #expect(identity?.showsNoSignal == false,
                        "tile \(index) can claim a take has no signal")
                if case .camera = identity {
                    Issue.record("tile \(index) reached the picture as a camera")
                }
            }
        }
    }

    /// **The tile clocks follow the transport's playhead**, which is the fact
    /// `SyncPlayModel.moveTimeline` exists to make true by construction.
    ///
    /// The playhead used to be written at five sites. A burned-in clock has to
    /// be PUSHED where the on-screen one merely observes, so a push added at
    /// five sites is four chances to miss one — and a missed one is a
    /// director's monitor whose timecodes stopped while the operator's screen
    /// is still right. That is the exact failure `Pacing` was invented for one
    /// level down, which is why the write was centralised instead.
    ///
    /// Each take counts from its OWN start timecode (10:00:00:00 in the
    /// fixture, 25 fps, four seconds long), so two seconds in reads
    /// 10:00:02:00.
    @Test func theTileClocksFollowTheTransportPlayhead() async throws {
        try await GridOutputProbe.withGridAndBoard(tiles: 2) { controller, model, _, _ in
            let composer: MultiviewComposer =
                try #require(controller.mirrors.syncGridComposer)
            let opened = composer.heldClock(camera: 0)
            #expect(opened == "10:00:00:00", "the grid opened on \(opened as Any)")

            model.seek(to: 2)
            let left = composer.heldClock(camera: 0)
            let right = composer.heldClock(camera: 1)
            #expect(left == "10:00:02:00",
                    "tile 0's clock stayed at \(left as Any) over the seek")
            #expect(right == "10:00:02:00",
                    "tile 1's clock stayed at \(right as Any) over the seek")
            // …and it is the model's own reading, not a second opinion about
            // what a clip position means
            #expect(composer.heldClock(camera: 0) == model.tileTimecodeText(0))
        }
    }

    /// Leaving the comparison takes the pushes with it: no composer, and the
    /// model's hooks are unhooked so a late transport verb cannot reach a
    /// composer that has been dropped.
    @Test func endingTheComparisonUnhooksTheClockPush() async throws {
        try await GridOutputProbe.withGridAndBoard(tiles: 2) { controller, model, _, _ in
            #expect(controller.mirrors.syncGridComposer != nil)
            controller.clearSyncGridPicture()
            #expect(controller.mirrors.syncGridComposer == nil)
            #expect(model.onTimelineMove == nil,
                    "the clock push outlived the composer it pushes to")
            // and a verb after the fact is inert rather than a crash
            model.seek(to: 1)
        }
    }

    // MARK: - the live grid

    /// **Every live tile says which BOARD it is**, from the same expression
    /// Settings, `MulticamGrid` and the `/cameras` page's tag all read.
    ///
    /// Note there is no manual push here: the identity is asserted straight
    /// after the composer is built, because `refreshMonitorTaps` pushes it as
    /// part of bringing the grid up. A grid that opened mid-shift and stayed
    /// anonymous until the next timecode tick would fail this.
    @Test func everyLiveTileSaysWhichBoardItIs() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.naming.cameraLabel = "A CAM"
            controller.ensureLiveEncoder(for: .grid)
            let composer: MultiviewComposer =
                try #require(controller.mirrors.gridComposer,
                             "the grid picture came up with no composer")
            let held = composer.heldIdentity(camera: 0)
            #expect(held == .camera(label: "A CAM", recording: false, signalPresent: true),
                    "camera 0 reached the picture as \(held as Any)")
        }
    }

    /// The REC lamp is the session's recording state and not a constant.
    ///
    /// **What this does and does not prove.** It sets `isRecording` directly —
    /// the idiom five other suites here already use — and pushes, so it pins
    /// that the lamp READS that state rather than being hard-coded false. It
    /// does NOT prove the lamp lights at the instant a writer opens a file:
    /// that is the pipeline's own path and its own suites. Nor does it cover
    /// the rule that matters most in multicam — that each tile's lamp is its
    /// OWN pipeline's state — which needs a second board and is stated at
    /// `pushGridIdentities` and asserted for the page at
    /// `RemoteStatus.CameraState`.
    @Test func theLampFollowsTheRecordingState() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.naming.cameraLabel = "A CAM"
            controller.ensureLiveEncoder(for: .grid)
            let composer: MultiviewComposer =
                try #require(controller.mirrors.gridComposer)
            #expect(composer.heldIdentity(camera: 0)?.showsRecordingLamp
                        == false)

            controller.isRecording = true
            controller.pushGridIdentities()
            #expect(composer.heldIdentity(camera: 0)?.showsRecordingLamp == true,
                    "the REC lamp did not light")
            #expect(composer.heldIdentity(camera: 0)
                        == .camera(label: "A CAM", recording: true, signalPresent: true),
                    "the lamp moved but the name did not survive it")
        }
    }

    /// **The legend follows the board's own signal, and reads the one property
    /// that answers that question.**
    ///
    /// `CaptureController.signalPresent` is written by `CapturePipeline.onSignal`
    /// and by nothing else, and it is what `LiveStatusOverlay` and the menu
    /// bar's readiness dot already read — so this pins that the picture joined
    /// them rather than acquiring an opinion of its own.
    ///
    /// **What it does and does not prove.** It sets the property directly, the
    /// idiom the lamp's test above already uses, so it pins the READ. It does
    /// not prove the badge appears at the instant a cable comes out: that is
    /// the pipeline's own path and its own suites. Nor can it see the case that
    /// matters most for the MAIN board — camera 0 losing signal also stops the
    /// composer's clock, so nothing composes and the far end holds its last
    /// grid. The identity below is correct and undrawn, which is stated at
    /// `pushGridIdentities` and is the same hole the `/cameras` page has.
    ///
    /// The last assertion is the failure that would look fine: a legend wired
    /// to something session-wide would light here too, and would also light on
    /// a B-cam that is perfectly happy.
    @Test func theLegendFollowsTheBoardsOwnSignal() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.naming.cameraLabel = "A CAM"
            controller.ensureLiveEncoder(for: .grid)
            let composer: MultiviewComposer =
                try #require(controller.mirrors.gridComposer)
            #expect(composer.heldIdentity(camera: 0)?.showsNoSignal == false,
                    "a feeding board opened the grid already dark")

            controller.signalPresent = false
            controller.pushGridIdentities()
            #expect(composer.heldIdentity(camera: 0)?.showsNoSignal == true,
                    "the dropout did not reach the picture")
            #expect(composer.heldIdentity(camera: 0)
                        == .camera(label: "A CAM", recording: false,
                                   signalPresent: false),
                    "the dropout landed but the name did not survive it")

            controller.signalPresent = true
            controller.pushGridIdentities()
            #expect(composer.heldIdentity(camera: 0)?.showsNoSignal == false,
                    "the legend outlived the dropout it describes")
        }
    }

    /// **The burned-in clock follows the frame path's own timecode tick.**
    ///
    /// The gap this closes is not hypothetical: the identity is pushed from two
    /// places, and the OPENING push (`refreshMonitorTaps`) is what every other
    /// test here happens to exercise. Delete the per-tick push instead and the
    /// grid would still open correctly labelled and then freeze — a name that is
    /// right and a clock that stopped, on a surface where the operator's own
    /// screen goes on being right.
    ///
    /// Driven through the very closure the controller installs on the pipeline,
    /// not through a re-implementation of it, so what is checked is the wiring
    /// that runs.
    @Test func theBurnedInClockFollowsTheTimecodeTick() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.ensureLiveEncoder(for: .grid)
            let composer: MultiviewComposer =
                try #require(controller.mirrors.gridComposer)
            #expect(composer.heldClock(camera: 0) == nil,
                    "a signal with no timecode still put one in the picture")

            let tick = Timecode(hours: 10, minutes: 0, seconds: 12, frames: 3,
                                fps: 25)
            controller.pipeline.onTimecode?(tick)
            let held = composer.heldClock(camera: 0)
            #expect(held == tick.description,
                    "the tick did not reach the picture: \(held as Any)")
            #expect(held == "10:00:12:03", "the clock reads \(held as Any)")
        }
    }

    /// Nobody watching the grid means nothing to push to — the same discipline
    /// the taps and the encoder pool already follow, checked here because the
    /// identity push is new per-frame work on the timecode tick and would
    /// otherwise be paid by every session whether or not anything is watching.
    @Test func anIdleGridHasNothingToPushTo() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.mirrors.gridComposer == nil)
            controller.pushGridIdentities() // inert, and must stay inert
            #expect(controller.mirrors.gridComposer == nil)
        }
    }
}
