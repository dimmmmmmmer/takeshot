import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// What the player says over the bottom of the picture, and how far up.
///
/// Both halves lived inside an `.overlay` closure in `PlayerArea` — a `let`
/// and an if/else-if nothing could read — and both had already gone wrong. The
/// inset is the one with a note on it: "a drifted copy of that number is the
/// take-failed message hidden behind the play button". It then drifted, because
/// the toast asked "is a clip loaded in playback" while the transport bar it
/// has to clear asked a careful question that excludes stills and the
/// sync-play grid.
@Suite @MainActor struct ViewPlayerToastTests {
    private func plan(error: String? = nil, notice: String? = nil,
                      tint: Color? = nil,
                      transport: CaptureController.TransportBarKind = .none)
        -> PlayerToastPlan? {
        PlayerToastPlan.current(error: error, notice: notice, noticeTint: tint,
                                transport: transport)
    }

    // MARK: - which message

    /// Nothing to say, nothing drawn.
    @Test func aQuietPlayerShowsNoToast() {
        #expect(plan() == nil)
    }

    /// An error outranks a notice. A take that failed matters more than the
    /// marker that was just written, and only one strip is drawn — a notice
    /// winning here is the operator not being told the shot is gone.
    @Test func anErrorOutranksANotice() {
        let both = plan(error: "card full", notice: "marker added")
        #expect(both?.text == "card full")
        #expect(both?.tint == .orange)
    }

    /// A marker toast carries the marker's own colour; everything else is the
    /// neutral confirmation green, so a red marker and a failure never read
    /// the same.
    @Test func aNoticeKeepsItsOwnTintAndFallsBackToGreen() {
        #expect(plan(notice: "marker added", tint: .red)?.tint == .red)
        #expect(plan(notice: "look applied")?.tint == .green)
        #expect(plan(notice: "look applied")?.text == "look applied")
    }

    // MARK: - how far up

    /// Clear of whatever bar is under the picture, and near the edge when
    /// there is none. The two RAW/video bars are the same obstacle.
    @Test func theToastClearsWhateverBarIsUnderThePicture() {
        for kind in [CaptureController.TransportBarKind.video, .raw] {
            #expect(plan(error: "x", transport: kind)?.bottomInset
                    == PlayerToastPlan.insetOverTransport,
                    "\(kind) left the toast under the controls")
        }
        #expect(plan(error: "x", transport: CaptureController.TransportBarKind.none)?
            .bottomInset == PlayerToastPlan.insetOverPicture)
        #expect(PlayerToastPlan.insetOverTransport
                > PlayerToastPlan.insetOverPicture)
    }

    /// **The bar makes room for the corner control, not the other way round**
    /// (owner: "мне кажется стоило не позицию глазика менять в плейбэке а
    /// полоску транспорта не от самого края слева начинать").
    ///
    /// The eye used to be lifted above the bar. It is back in its corner, and
    /// the bar's left edge clears it — so what this pins is that the inset is
    /// actually wide enough for what sits there, derived from the same two
    /// numbers the corner is built from rather than typed a second time.
    @Test func theTransportBarStartsClearOfTheCornerControl() {
        #expect(PlayerToastPlan.transportLeading
                > PlayerToastPlan.cornerPadding
                + PlayerToastPlan.cornerControlWidth,
                "the bar starts on top of the eye")
        // …and not so far in that it reads as a gap: the air is single digits
        #expect(PlayerToastPlan.transportLeading
                - PlayerToastPlan.cornerPadding
                - PlayerToastPlan.cornerControlWidth < 10)
    }

    /// …and every bar mounted over the picture actually takes that inset.
    ///
    /// Asserted on the SOURCE because the alternative is rendering a live
    /// player with a real clip in it, and the regression this guards is a new
    /// mount point or a `.padding(6)` put back — both of which are visible in
    /// the text and neither of which any unit of behaviour can see.
    ///
    /// The comment halves are cut out before matching, because the note ABOVE
    /// those mounts names the constant: an assertion a file's own prose can
    /// satisfy is the trap CLAUDE.md records against `live.html`.
    @Test func everyBarOverThePictureTakesThatInset() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit/PreviewView.swift")
        let code: String = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")
        let mounts = code.components(separatedBy: "TransportBar(").count - 1
        let inset = code.components(
            separatedBy: "PlayerToastPlan.transportLeading").count - 1
        #expect(mounts > 0, "the player mounts no transport bar at all")
        #expect(inset == mounts,
                Comment(rawValue: "\(mounts) bars over the picture and "
                    + "\(inset) of them start clear of the corner"))
    }

    // MARK: - what is under the picture at all

    /// The live signal has no transport under it.
    @Test func recordModeHasNoTransportBar() async throws {
        try await ControllerHarness.run { controller, root in
            controller.playbackURL = root.appendingPathComponent("A001C001.mov")
            #expect(controller.transportBarKind == .none,
                    "a transport appeared over the live signal")
        }
    }

    /// A video clip in the single player gets the AVPlayer transport.
    @Test func aVideoClipGetsTheAVPlayerTransport() async throws {
        try await ControllerHarness.run { controller, root in
            controller.viewerMode = .playback
            controller.playbackURL = root.appendingPathComponent("A001C001.mov")
            #expect(controller.transportBarKind == .video)
        }
    }

    /// A still is not a clip: it has nothing to scrub, and the toast that used
    /// to float 42 points above the bar that is not there now sits where every
    /// other toast does.
    @Test func aStillHasNoTransportBarAndTheToastComesDown() async throws {
        try await ControllerHarness.run { controller, root in
            controller.viewerMode = .playback
            controller.playbackURL = root.appendingPathComponent("grab.png")
            #expect(controller.transportBarKind == .none)
            #expect(PlayerToastPlan.current(
                error: "x", notice: nil, noticeTint: nil,
                transport: controller.transportBarKind)?.bottomInset
                == PlayerToastPlan.insetOverPicture)
        }
    }

    /// A RAW clip the engine really opened gets the engine's own bar.
    @Test func anOpenRawClipGetsTheRawBar() async throws {
        let media = try MediaFixtures.makeDirectory("toast-raw")
        defer { try? FileManager.default.removeItem(at: media) }
        let folder = try RawClipFixtures.clip(frames: 3, in: media)

        try await ControllerHarness.run { controller, _ in
            var error: String?
            controller.viewerMode = .playback
            controller.playbackURL = folder
            controller.rawPlayer = RawPlayerModel(url: folder, error: &error)
            defer { controller.rawPlayer = nil }
            #expect(controller.transportBarKind == .raw)
        }
    }

    /// …and a RAW clip it could NOT open gets none. What is on screen there is
    /// a "could not open" notice, and a transport under it would be driving
    /// whatever clip was open before.
    @Test func aRawClipTheEngineCouldNotOpenGetsNoBar() async throws {
        try await ControllerHarness.run { controller, root in
            controller.viewerMode = .playback
            controller.playbackURL = root.appendingPathComponent("A001.braw")
            #expect(controller.rawPlayer == nil)
            #expect(controller.transportBarKind == .none)
        }
    }

    /// A sync-play grid has two to four clips and no single timeline of its
    /// own, so its master transport is drawn with the grid and the single
    /// player underneath it gets no bar — and the toast comes down with it.
    @Test func aSyncPlayGridHasNoPlayerTransport() async throws {
        let media = try MediaFixtures.makeDirectory("toast-sync")
        defer { try? FileManager.default.removeItem(at: media) }
        var sources: [SyncPlayModel.Source] = []
        for name in ["A", "B"] {
            let url = try await MediaFixtures.writeClip(
                at: media.appendingPathComponent("\(name).mov"), frames: 6)
            sources.append(SyncPlayModel.Source(
                url: url, name: name, startTimecode: MediaFixtures.startTimecode,
                duration: 6.0 / 25.0))
        }

        try await ControllerHarness.run { controller, _ in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }
            controller.viewerMode = .playback
            controller.playbackURL = sources[0].url
            #expect(controller.transportBarKind == .video)

            let grid = SyncPlayModel(sources: sources)
            controller.syncPlay = grid
            defer {
                controller.syncPlay = nil
                grid.shutDown()
            }
            #expect(controller.transportBarKind == .none,
                    "the grid drew the single player's transport under it")
        }
    }
}
