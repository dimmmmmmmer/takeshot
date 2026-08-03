import AVFoundation
import AppKit
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// In/out points belong to the clip they were marked on.
///
/// There is one TransportModel for the whole app, so a range used to survive
/// `replaceCurrentItem` untouched and reappear on the NEXT clip at the same
/// seconds offset: mark a beat 12 s into a 40 s take, load the next take, and
/// the player was already looping over 12 s of somebody else's action — with the
/// range buttons lit, as if the operator had set it there.
@Suite @MainActor struct TransportClipRangeTests {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/takeshot-range/\(name)")
    }

    /// The model on its own: set on A, open B, come back to A.
    @Test func aRangeIsFiledUnderItsOwnClip() {
        let transport = TransportModel()
        let clipA = url("A001C001.mov")
        let clipB = url("A001C002.mov")

        transport.loadClip(clipA)
        transport.position.currentTime = 12
        transport.toggleRangePoint(out: false)
        transport.position.currentTime = 20
        transport.toggleRangePoint(out: true)
        #expect(transport.currentRange == ClipRange(inPoint: 12, outPoint: 20))

        transport.loadClip(clipB)
        #expect(transport.inPoint == nil, "clip B inherited clip A's in point")
        #expect(transport.outPoint == nil, "clip B inherited clip A's out point")

        transport.loadClip(clipA)
        #expect(transport.currentRange == ClipRange(inPoint: 12, outPoint: 20),
                "the range clip A was marked with did not come back")
    }

    /// Clearing a point is a decision too: it has to be remembered as "no range"
    /// rather than fall back to what the clip had earlier.
    @Test func clearingARangeIsRememberedAsCleared() {
        let transport = TransportModel()
        let clipA = url("A001C001.mov")

        transport.loadClip(clipA)
        transport.position.currentTime = 5
        transport.toggleRangePoint(out: false)
        transport.loadClip(url("other.mov"))
        transport.loadClip(clipA)
        #expect(transport.inPoint == 5)

        transport.position.currentTime = 5
        transport.toggleRangePoint(out: false) // clicking the point clears it
        #expect(transport.inPoint == nil)
        transport.loadClip(url("other.mov"))
        transport.loadClip(clipA)
        #expect(transport.inPoint == nil, "a cleared range came back")
    }

    /// A still or a RAW clip is not driven by this transport. The outgoing range
    /// still has to be filed, and nothing may be adopted — otherwise this
    /// model's empty range would be written over the RAW engine's own.
    @Test func contentThisTransportDoesNotDriveKeepsItsHandsOff() {
        let transport = TransportModel()
        let clip = url("A001C001.mov")
        let still = url("reference.png")

        transport.loadClip(clip)
        transport.position.currentTime = 8
        transport.toggleRangePoint(out: false)

        transport.loadClip(still, driving: false)
        #expect(transport.inPoint == nil, "a still showed the clip's in point")

        transport.storeRange(ClipRange(inPoint: 1, outPoint: 2), for: still)
        transport.loadClip(clip)
        #expect(transport.inPoint == 8, "the clip's own range was lost to a still")
        #expect(transport.storedRange(for: still)
                    == ClipRange(inPoint: 1, outPoint: 2))
    }

    @Test func aDeletedClipTakesItsRangeWithIt() {
        let transport = TransportModel()
        let clip = url("A001C001.mov")

        transport.loadClip(clip)
        transport.position.currentTime = 3
        transport.toggleRangePoint(out: false)
        transport.forgetClip(clip)

        #expect(transport.inPoint == nil)
        #expect(transport.storedRange(for: clip).isEmpty)
        transport.loadClip(clip)
        #expect(transport.currentRange.isEmpty,
                "the deleted clip's range survived into the file that replaced it")
    }

    /// The glyphs, checked by looking at them rather than by their names.
    ///
    /// The IN button used to carry the arrow that runs into a line on the RIGHT —
    /// how every NLE draws the END of a range — and OUT carried the left one, so
    /// both read backwards. What makes each glyph read as one end of a range is
    /// which side its vertical bar is on, and that is measured here: the bar is
    /// the tallest column of ink in the symbol, so the densest column says which
    /// half it sits in. Renaming the symbols to another mistaken pair, or Apple
    /// redrawing them, both fail here.
    @Test func theRangeGlyphsPutTheirBarOnTheSideTheyMark() throws {
        let inBar = try Self.barPosition(of: TransportModel.inPointSymbol)
        let outBar = try Self.barPosition(of: TransportModel.outPointSymbol)

        #expect(inBar < 0.5, "the IN glyph's bar sits at \(inBar) — right of centre")
        #expect(outBar > 0.5, "the OUT glyph's bar sits at \(outBar) — left of centre")
        #expect(TransportModel.inPointSymbol != TransportModel.outPointSymbol)
    }

    /// Where the symbol's heaviest column of ink is, as a 0…1 fraction of its
    /// width. For these glyphs that is the vertical bar: the arrow shaft is one
    /// row high and the head is a chevron, so neither can out-weigh a stroke
    /// spanning the full height.
    private static func barPosition(of name: String) throws -> Double {
        let symbol = try #require(
            NSImage(systemSymbolName: name, accessibilityDescription: nil),
            "\(name) is not a symbol in this macOS release")
        let configured = try #require(symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 128, weight: .regular)))
        let data = try #require(configured.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: data))
        var columns = [Double](repeating: 0, count: rep.pixelsWide)
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                columns[x] += Double(rep.colorAt(x: x, y: y)?
                    .alphaComponent ?? 0)
            }
        }
        let heaviest = try #require(columns.indices.max { columns[$0] < columns[$1] })
        return Double(heaviest) / Double(max(1, rep.pixelsWide - 1))
    }

    /// The same thing through the controller, on real media: the range follows
    /// the clip across `play(url:)`, which is where the carry-over showed up.
    @Test func openingAnotherTakeDoesNotCarryTheRangeOver() async throws {
        let media = try MediaFixtures.makeDirectory("range-per-clip")
        defer { try? FileManager.default.removeItem(at: media) }
        let clipA = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("A001C001.mov"), frames: 12)
        let clipB = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("A001C002.mov"), frames: 12)

        try await ControllerHarness.run { controller, _ in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }
            let transport = controller.transport

            controller.play(url: clipA)
            // set the range synchronously: the 10 Hz position observer can only
            // run at a suspension point, and there is none between these lines
            transport.position.currentTime = 0.2
            transport.toggleRangePoint(out: false)
            transport.position.currentTime = 0.4
            transport.toggleRangePoint(out: true)
            #expect(transport.inPoint == 0.2)

            controller.play(url: clipB)
            #expect(transport.inPoint == nil,
                    "the next take opened with the previous take's loop range")
            #expect(transport.outPoint == nil)

            controller.play(url: clipA)
            #expect(transport.currentRange
                        == ClipRange(inPoint: 0.2, outPoint: 0.4),
                    "reopening the take lost the range marked on it")
        }
    }

    /// The RAW engine is rebuilt for every clip, so it never carried a range
    /// over — it simply forgot. Its in/out is in frames, and it comes back
    /// through the same per-clip store.
    @Test func aRawClipGetsItsOwnRangeBack() async throws {
        let media = try MediaFixtures.makeDirectory("range-raw")
        defer { try? FileManager.default.removeItem(at: media) }
        let clip = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("A001C001.mov"), frames: 12)
        // a CinemaDNG "clip": the engine opens the folder and falls back to
        // 1920x1080/24 without ever decoding the frame
        let sequence = media.appendingPathComponent("A002")
        try FileManager.default.createDirectory(at: sequence,
                                                withIntermediateDirectories: true)
        try Data("frame".utf8).write(to: sequence.appendingPathComponent("0001.dng"))

        try await ControllerHarness.run { controller, _ in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }

            controller.play(url: sequence)
            let raw = try #require(controller.rawPlayer)
            raw.pause()
            let fps = raw.frameRate
            raw.inFrame = Int(fps * 2)
            raw.outFrame = Int(fps * 3)

            controller.play(url: clip)
            #expect(controller.rawPlayer == nil)
            #expect(controller.transport.inPoint == nil,
                    "the AVPlayer transport adopted the RAW clip's range")

            controller.play(url: sequence)
            let reopened = try #require(controller.rawPlayer)
            reopened.pause()
            #expect(reopened.inFrame == Int(fps * 2),
                    "the RAW clip came back without the in point marked on it")
            #expect(reopened.outFrame == Int(fps * 3))
        }
    }

    // MARK: - playback starts inside the range (owner item 38)

    /// The decision on its own, without a player attached.
    ///
    /// The bug: the loop was enforced at the OUT point alone — the periodic
    /// observer seeks back when time passes it, the end-of-item observer does
    /// the same at the tail — and nothing ever put the playhead INSIDE the
    /// range to begin with. A fresh `AVPlayerItem` starts at zero, so the first
    /// pass over a clip with a range on it played the whole lead-in and only
    /// then began looping.
    @Test func theRangeDecidesWherePlaybackBegins() {
        let transport = TransportModel()
        transport.loadClip(url("A001C001.mov"))

        // no range: nothing to decide, the playhead stays where it is
        #expect(transport.rangeStart(forPlayheadAt: 0) == nil)
        #expect(transport.rangeStart(forPlayheadAt: 7) == nil)

        transport.inPoint = 4
        transport.outPoint = 9
        #expect(transport.rangeStart(forPlayheadAt: 0) == 4,
                "playback from the head ignored the in point")
        #expect(transport.rangeStart(forPlayheadAt: 3.9) == 4)
        // already inside it: left alone, so a pause and a resume do not jump
        #expect(transport.rangeStart(forPlayheadAt: 4) == nil)
        #expect(transport.rangeStart(forPlayheadAt: 6) == nil)
        // at or past the out point: the next play restarts the range
        #expect(transport.rangeStart(forPlayheadAt: 9) == 4)
        #expect(transport.rangeStart(forPlayheadAt: 20) == 4)

        // an out point with no in point sends it back to the head
        transport.inPoint = nil
        #expect(transport.rangeStart(forPlayheadAt: 0) == nil)
        #expect(transport.rangeStart(forPlayheadAt: 9) == 0)

        // with looping off the out point is not enforced anywhere, so it does
        // not reposition the start either; an in point still does
        transport.isLooping = false
        #expect(transport.rangeStart(forPlayheadAt: 9) == nil)
        transport.inPoint = 4
        #expect(transport.rangeStart(forPlayheadAt: 0) == 4)
    }

    /// And through the controller, on real media: opening a clip that carries a
    /// range puts the FIRST delivered position inside it.
    ///
    /// The assertion is on the player's own clock immediately after the open,
    /// which is the reading the old code answered with 0 — a poll for "is it in
    /// the range yet" would go green either way once playback reached the out
    /// point and wrapped, which is precisely the behaviour being fixed.
    @Test func openingAClipWithARangeStartsInsideIt() async throws {
        let media = try MediaFixtures.makeDirectory("range-start")
        defer { try? FileManager.default.removeItem(at: media) }
        // 2 s at 25 fps, so there is a lead-in worth measuring
        let clip = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("A001C001.mov"), frames: 50)

        try await ControllerHarness.run { controller, _ in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }
            let transport = controller.transport

            // the range is on file before the clip is ever opened — a mark made
            // in an earlier session, restored from takeshot-ranges.csv
            transport.storeRange(ClipRange(inPoint: 1.2, outPoint: 1.8),
                                 for: clip)

            controller.play(url: clip)
            #expect(transport.inPoint == 1.2, "the range was not adopted")

            let first = controller.player.currentTime().seconds
            #expect(first >= 1.15,
                    "playback opened at \(first)s, outside the 1.2–1.8 range")
            #expect(first <= 1.85)
            #expect(transport.position.currentTime >= 1.15,
                    "the transport readout still says the head of the clip")
        }
    }

    /// A clip with no range is left where it always started, and one whose
    /// range is only an OUT point starts at the head — the fix must not turn
    /// every open into a seek.
    @Test func aClipWithoutAnInPointStillOpensAtTheHead() async throws {
        let media = try MediaFixtures.makeDirectory("range-start-none")
        defer { try? FileManager.default.removeItem(at: media) }
        let plain = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("A001C001.mov"), frames: 50)
        let outOnly = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("A001C002.mov"), frames: 50)

        try await ControllerHarness.run { controller, _ in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }
            controller.transport.storeRange(ClipRange(inPoint: nil, outPoint: 1.5),
                                            for: outOnly)

            controller.play(url: plain)
            #expect(controller.player.currentTime().seconds < 0.2)

            controller.play(url: outOnly)
            #expect(controller.player.currentTime().seconds < 0.2,
                    "an out point on its own moved the start of the clip")
        }
    }

    /// The RAW engine had the same bug and it is fixed in the same place: a
    /// clip opened with an in point marked on it starts on that frame.
    @Test func aRawClipWithARangeAlsoStartsInsideIt() async throws {
        try await ControllerHarness.run { _, root in
            // a long enough sequence that a range has somewhere to sit; the
            // frames are never decoded, only counted
            let folder = root.appendingPathComponent("A002.dng-sequence")
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
            for index in 1...80 {
                try Data("frame".utf8).write(to: folder.appendingPathComponent(
                    String(format: "frame_%06d.dng", index)))
            }
            var error: String?
            let raw = try #require(RawPlayerModel(url: folder, error: &error),
                                   "the DNG folder was refused: \(error ?? "-")")
            raw.pause()
            #expect(raw.frameCount == 80)
            raw.inFrame = 40
            raw.outFrame = 60

            #expect(raw.startOfPlayback() == 40,
                    "the loop would have started at the head again")
            raw.currentFrame = 50 // already inside: left where it is
            #expect(raw.startOfPlayback() == 50)
            raw.currentFrame = 60 // at the out point: back round
            #expect(raw.startOfPlayback() == 40)

            // no range, no repositioning
            raw.inFrame = nil
            raw.outFrame = nil
            raw.currentFrame = 7
            #expect(raw.startOfPlayback() == 7)
        }
    }

    /// Deleting the clip in the player releases its range along with everything
    /// else the controller was holding for it.
    @Test func deletingATakeForgetsItsRange() async throws {
        try await ControllerHarness.run { controller, root in
            let take = ControllerFixtures.take(named: "takeshot-test-range",
                                               in: root)
            try ControllerFixtures.placeholder(for: take)
            controller.takes = [take]
            controller.transport.loadClip(take.url)
            controller.transport.position.currentTime = 2
            controller.transport.toggleRangePoint(out: false)

            controller.deleteTake(take)

            #expect(controller.transport.inPoint == nil)
            #expect(controller.transport.storedRange(for: take.url).isEmpty)
        }
    }
}
