import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The RAW engine's transport: the buttons under a CinemaDNG clip.
///
/// The arithmetic here was reachable before `RawClipFixtures` and most of it is
/// covered by `TransportClipRangeTests` and `ModelRawReviewTests`. What was
/// left when the long-tail wave ran out of length is three things an operator
/// does constantly and nothing had ever asked for: clearing a range point by
/// clicking it again, scrubbing WITHOUT stopping, and the scopes following a
/// paused seek.
@Suite @MainActor struct ModelRawTransportTests {
    private func scratch(_ name: String) throws -> URL {
        try MediaFixtures.makeDirectory(name)
    }

    // MARK: - clicking a point again clears it

    /// The IN and OUT buttons are toggles, and the tolerance is what makes them
    /// usable: the playhead is put there by a scrub, and landing on the exact
    /// frame again by hand is not something anyone can do. Within a frame or
    /// two of the point, the button clears it.
    ///
    /// The engine files the range with the controller on the spot rather than
    /// on the way out — it is thrown away and rebuilt per clip, so a quit with
    /// the clip still open would otherwise lose the marks. Clearing has to
    /// report too: a clear that stayed silent would be restored on the next
    /// open, and the point the operator just took off would come back.
    @Test func clickingARangePointAgainClearsItAndSaysSo() throws {
        let root = try scratch("raw-range-clear")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try RawClipFixtures.player(frames: 30, in: root)
        var reports = 0
        model.onRangeChanged = { reports += 1 }

        model.currentFrame = 10
        model.toggleRangePoint(out: false)
        model.currentFrame = 25
        model.toggleRangePoint(out: true)
        #expect(model.inFrame == 10)
        #expect(model.outFrame == 25)
        #expect(reports == 2)

        // back to the in point, near enough that the button reads as "this one"
        model.currentFrame = 11
        model.toggleRangePoint(out: false)
        #expect(model.inFrame == nil, "clicking the in point again kept it")
        #expect(model.outFrame == 25, "clearing the in point took the out point")
        #expect(reports == 3, "the cleared in point was never filed")

        model.currentFrame = 24
        model.toggleRangePoint(out: true)
        #expect(model.outFrame == nil, "clicking the out point again kept it")
        #expect(reports == 4, "the cleared out point was never filed")
    }

    /// Two frames away is the point; three frames away is a new one. Stated
    /// because the tolerance is the difference between a toggle an operator can
    /// hit and one that only ever adds — and because the same click has to MOVE
    /// the point when it lands clear of it.
    @Test func aClickClearOfThePointMovesItInstead() throws {
        let root = try scratch("raw-range-move")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try RawClipFixtures.player(frames: 30, in: root)

        model.currentFrame = 10
        model.toggleRangePoint(out: false)
        model.currentFrame = 12 // two frames off: a new point, not a clear
        model.toggleRangePoint(out: false)
        #expect(model.inFrame == 12,
                "a click two frames off the in point cleared it instead of moving it")

        model.currentFrame = 13 // one frame off: the same point
        model.toggleRangePoint(out: false)
        #expect(model.inFrame == nil)
    }

    /// A range that would run backwards takes the other end with it. The clip
    /// has one direction and an out point before its in point is a loop the
    /// play loop cannot run — better to drop the older mark than to keep a
    /// range that plays nothing.
    @Test func aPointSetPastItsPartnerDropsThePartner() throws {
        let root = try scratch("raw-range-invert")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try RawClipFixtures.player(frames: 30, in: root)

        model.currentFrame = 20
        model.toggleRangePoint(out: false)
        model.currentFrame = 10
        model.toggleRangePoint(out: true) // an out point before the in point
        #expect(model.outFrame == 10)
        #expect(model.inFrame == nil, "the range was left running backwards")

        model.currentFrame = 5
        model.toggleRangePoint(out: false)
        model.currentFrame = 25
        model.toggleRangePoint(out: false) // an in point past the out point
        #expect(model.inFrame == 25)
        #expect(model.outFrame == nil, "the range was left running backwards")
    }

    /// A toggle that changes nothing files nothing. The range is written to the
    /// controller's store on every report, and a clip whose marks are being
    /// re-filed on clicks that did nothing is a store that cannot be trusted to
    /// mean the operator touched something.
    @Test func aToggleThatChangesNothingIsNotFiled() throws {
        let root = try scratch("raw-range-noop")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try RawClipFixtures.player(frames: 4, in: root)
        var reports = 0

        // a clip whose only frame is 0: setting the out point at 0 clears the
        // in point at 0 with it, and the second press puts it straight back
        model.currentFrame = 0
        model.toggleRangePoint(out: false)
        model.onRangeChanged = { reports += 1 }
        model.toggleRangePoint(out: false) // clears it
        model.toggleRangePoint(out: false) // sets it again
        #expect(reports == 2)
        #expect(model.inFrame == 0)
    }

    // MARK: - scrubbing without stopping

    /// A scrub while the clip is running resumes from where it was dropped.
    ///
    /// `seek` pauses to get the decode loop out of the way and then has to put
    /// it back: without that, dragging the scrubber during a review stops
    /// playback, and the operator presses play again at every check. It resumes
    /// at the frame under the pointer and NOT at the in point, which is the
    /// whole reason `startPlaying(at:)` exists beside `play()`.
    ///
    /// The scrub goes BACKWARDS, past the in point, and that is what makes the
    /// claim unambiguous: playback was running from 20 upwards, so a frame
    /// below 12 on screen can only have come from the resume. Had the resume
    /// gone through `play()` it would have started at the in point and those
    /// four frames would never be decoded.
    @Test func aScrubWhileRunningResumesWhereItWasDropped() async throws {
        let root = try scratch("raw-seek-resume")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, presented) = try RawClipFixtures.player(frames: 30, in: root)
        model.inFrame = 12 // an in point ABOVE where the scrub lands

        model.startPlaying(at: 20)
        #expect(model.isPlaying)
        #expect(await ControllerWait.untilWritten { presented.count > 0 })

        model.seek(to: 8)
        #expect(model.isPlaying, "a scrub during playback stopped the clip")
        #expect(model.currentFrame == 8)
        #expect(await ControllerWait.untilWritten {
                    presented.all.contains { (8..<12).contains($0) }
                },
                "the resume snapped to the in point: \(presented.all)")
    }

    /// A scrub on a PAUSED clip leaves it paused. The same call does both jobs
    /// and only one of them may start the decode loop — a player that begins
    /// running because the operator moved the scrubber is one that cannot be
    /// used to look at a frame.
    @Test func aScrubOnAPausedClipLeavesItPaused() async throws {
        let root = try scratch("raw-seek-paused")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, presented) = try RawClipFixtures.player(frames: 20, in: root)

        model.seek(to: 8)
        #expect(!model.isPlaying)
        #expect(await ControllerWait.untilWritten { presented.last == 8 })
        // full budget on purpose: this waits for frames that must NOT arrive
        _ = await ControllerWait.until({ presented.last != 8 },
                                       timeout: .milliseconds(500))
        #expect(model.currentFrame == 8,
                "the paused clip ran on to \(model.currentFrame)")
    }

    // MARK: - the scopes follow a paused seek

    /// With the scopes open, stepping to a frame analyses THAT frame.
    ///
    /// The decode loop feeds the scopes at a stride while a clip runs, and a
    /// paused clip is re-analysed on demand — but a paused SEEK is neither, and
    /// it is what a DIT does all day: step to the frame, read the waveform.
    /// Without this the scopes keep showing the frame before the step, which
    /// looks like an instrument that works.
    @Test func aPausedSeekAnalysesTheFrameItLandedOn() async throws {
        let root = try scratch("raw-seek-scopes")
        defer { try? FileManager.default.removeItem(at: root) }
        // frame N is N+1 white columns on black, so the analysed frame's own
        // proportion of white says WHICH frame the scopes were handed
        let (model, _) = try RawClipFixtures.player(frames: 24, in: root)
        let seen = ScopeReadings()
        model.onScopeData = { seen.record($0) }
        model.scopesEnabled = true

        model.seek(to: 15)
        #expect(await ControllerWait.untilWritten { seen.count == 1 },
                "a paused seek with the scopes open ran no analysis")

        model.seek(to: 3)
        #expect(await ControllerWait.untilWritten { seen.count == 2 },
                "the second step was not analysed")
        // 16 of 32 columns white against 4 of 32: the scopes are looking at the
        // frame the playhead names, not at the one before it
        // #require rather than #expect: indexing an empty array below would
        // take the whole run down with a trap instead of reporting a failure
        let bright: [Double] = seen.brightShares
        try #require(bright.count == 2)
        #expect(bright[0] > bright[1],
                "the two steps analysed the same picture: \(bright)")
    }

    /// The seek that is cancelled by another one before its decode lands
    /// analyses nothing. The generation check is what stops a fast scrub
    /// flooding the analyser with frames the operator has already left.
    @Test func aSeekOvertakenByAnotherLeavesNoTrace() async throws {
        let root = try scratch("raw-seek-overtaken")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try RawClipFixtures.player(frames: 24, in: root)
        let seen = ScopeReadings()
        model.onScopeData = { seen.record($0) }
        model.scopesEnabled = true

        for frame in 0..<12 { model.seek(to: frame) }
        #expect(await ControllerWait.untilWritten { seen.count >= 1 })
        _ = await ControllerWait.until({ seen.count >= 12 },
                                       timeout: .milliseconds(500))
        #expect(seen.count < 12,
                "all twelve overtaken seeks reached the analyser")
        #expect(model.currentFrame == 11)
    }

    /// Scope passes and how bright the frame each one saw was. They land on the
    /// main actor while the test polls from a concurrency worker, so the
    /// storage goes behind a lock.
    private final class ScopeReadings: @unchecked Sendable {
        private let lock = NSLock()
        private var shares: [Double] = []

        var count: Int { lock.withLock { shares.count } }
        var brightShares: [Double] { lock.withLock { shares } }

        func record(_ data: ScopeData) {
            let bins: [Int] = data.histY
            let total: Double = bins.reduce(0.0) { $0 + Double($1) }
            guard total > 0 else { return }
            // the top eighth of the scale: the fixture's white columns
            let bright: Double = bins.suffix(bins.count / 8)
                .reduce(0.0) { $0 + Double($1) }
            lock.withLock { shares.append(bright / total) }
        }
    }
}
