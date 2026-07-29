import AVFoundation
import Foundation
import Testing
@testable import TakeShotKit

/// The loop range under the player. The operator sets it by clicking IN and OUT
/// at the playhead while a stunt runs back ten times, so the two points are
/// edited independently and out of order — and an inverted range (in after out)
/// makes the loop in `TransportModel.attach` seek backwards forever.
///
/// The invariant this suite defends: whenever both points are set, in < out.
@MainActor
struct ModelTransportTests {
    private func model(at seconds: Double) -> TransportModel {
        let model = TransportModel()
        model.position.currentTime = seconds
        return model
    }

    @Test func setsInAndOutAtThePlayhead() {
        let model = model(at: 2)
        model.toggleRangePoint(out: false)
        #expect(model.inPoint == 2)
        model.position.currentTime = 7
        model.toggleRangePoint(out: true)
        #expect(model.outPoint == 7)
        #expect(model.inPoint == 2)
    }

    /// Clicking the same button again at (or very near) the point clears it —
    /// the only way to drop a loop point without moving the playhead exactly.
    @Test func clickingNearAnExistingPointClearsIt() {
        let model = model(at: 5)
        model.toggleRangePoint(out: false)
        model.toggleRangePoint(out: true)
        #expect(model.inPoint == nil, "out at the in point must drop the in point")
        #expect(model.outPoint == 5)

        model.position.currentTime = 5.05 // within the 0.1 s tolerance
        model.toggleRangePoint(out: true)
        #expect(model.outPoint == nil)
    }

    @Test func aPointJustOutsideTheToleranceMovesRatherThanClears() {
        let model = model(at: 5)
        model.toggleRangePoint(out: true)
        model.position.currentTime = 5.2
        model.toggleRangePoint(out: true)
        #expect(model.outPoint == 5.2)
    }

    /// Setting OUT before the existing IN drops the IN rather than leaving an
    /// inverted range behind.
    @Test func outBeforeInClearsIn() {
        let model = model(at: 9)
        model.toggleRangePoint(out: false)
        model.position.currentTime = 3
        model.toggleRangePoint(out: true)
        #expect(model.outPoint == 3)
        #expect(model.inPoint == nil)
    }

    @Test func inAfterOutClearsOut() {
        let model = model(at: 3)
        model.toggleRangePoint(out: true)
        model.position.currentTime = 9
        model.toggleRangePoint(out: false)
        #expect(model.inPoint == 9)
        #expect(model.outPoint == nil)
    }

    /// Whatever order the operator clicks in, the pair is never inverted.
    @Test func noSequenceOfClicksLeavesAnInvertedRange() {
        let model = TransportModel()
        let script: [(Double, Bool)] = [
            (1, false), (4, true), (6, false), (2, true), (2, false),
            (9, true), (9, false), (0, false), (5, true), (5, true),
            (3, false), (3, true), (7, false), (1, true), (8, true),
        ]
        for (time, out) in script {
            model.position.currentTime = time
            model.toggleRangePoint(out: out)
            if let inPoint = model.inPoint, let outPoint = model.outPoint {
                #expect(inPoint < outPoint,
                        "inverted range \(inPoint)…\(outPoint) after \(time)/\(out)")
            }
        }
    }

    /// The rate is remembered while paused: the transport's speed buttons are
    /// used to set up a slow-motion review before hitting play.
    @Test func rateIsRememberedWhileThereIsNoPlayer() {
        let model = TransportModel()
        model.setRate(0.25)
        #expect(model.desiredRate == 0.25)
        model.setRate(2)
        #expect(model.desiredRate == 2)
    }

    /// `attach` installs a periodic observer, a status observation and a
    /// notification observer; `detach` has to take all three back off. Removing
    /// a time observer from the wrong player, or twice, traps — so re-attaching
    /// and detaching without a matching attach are both exercised.
    @Test func detachIsSafeBeforeAndAfterRepeatedAttaches() {
        let model = TransportModel()
        model.detach() // never attached
        let first = AVPlayer()
        let second = AVPlayer()
        model.attach(first)
        model.attach(second) // implicit detach of `first`
        model.detach()
        model.detach() // idempotent
        // a player with no item never reports a numeric duration, so nothing
        // the observers saw can have reached the transport
        #expect(model.duration == 0)
    }

    /// With no player the transport is inert rather than crashing — the window
    /// is laid out before any clip is loaded.
    @Test func transportControlsAreInertWithoutAPlayer() {
        let model = TransportModel()
        model.togglePlay()
        model.skip(5)
        model.seek(to: 12)
        #expect(!model.isPlaying)
        #expect(model.currentTime == 0)
        #expect(model.duration == 0)
        #expect(model.isLooping)
    }
}
