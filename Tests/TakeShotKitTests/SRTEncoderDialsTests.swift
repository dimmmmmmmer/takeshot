import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox

@testable import TakeShotKit

/// The encoder's two live dials.
///
/// Split from `SRTEncodeTests` at a real seam rather than for size: that suite
/// measures what a FIXED session produces — levels, tags, parameter sets — and
/// this one measures what happens when the session is asked to change while it
/// is running, which is what a viewer arriving mid-stream depends on.
@Suite(.enabled(if: SRTVideoEncoder.isSupported,
                "no H.264 encoder on this machine"))
struct SRTEncoderDialsTests {
    private static func encoder(
        _ frame: CVPixelBuffer,
        sink: @escaping @Sendable (CMSampleBuffer) -> Void
    ) throws -> SRTVideoEncoder {
        try SRTVideoEncoder(
            configuration: SRTVideoEncoder.Configuration(
                width: CVPixelBufferGetWidth(frame),
                height: CVPixelBufferGetHeight(frame),
                framesPerSecond: 25, bitsPerSecond: 8_000_000),
            sink: sink)
    }

    /// A viewer who joins mid-stream sees nothing until the next keyframe, and
    /// at a one-second GOP that is up to a second of black on a phone somebody
    /// just picked up. So a keyframe can be ASKED for, and the ask is answered
    /// by the very next frame rather than at the next interval.
    @Test func aRequestedKeyframeArrivesOnTheNextFrame() throws {
        let frame = try SRTEncodeTests.bands()
        let collected = SampleBox()
        let encoder = try Self.encoder(frame) { collected.store($0) }
        let step: Int64 = MPEGTSMuxer.clockHz / 25
        for index in 0..<4 { encoder.encode(frame, ticks: Int64(index) * step) }
        encoder.requestKeyframe()
        encoder.encode(frame, ticks: 4 * step)
        // invalidate() completes the pending frames before it tears down, which
        // is what makes the sink's collection final here.
        encoder.invalidate()
        let samples: [CMSampleBuffer] = collected.samples
        #expect(samples.count == 5, "the encoder did not return every frame")
        let asked: CMSampleBuffer = try #require(samples.last)
        #expect(MPEGTSMuxer.isKeyframe(asked),
                "the frame after the request is not a keyframe")
        // and the frames before it were NOT keyframes, or the test proves
        // nothing: at a 25-frame interval only the first should be
        #expect(samples.dropFirst().dropLast().allSatisfy {
            !MPEGTSMuxer.isKeyframe($0)
        }, "the stream was all keyframes anyway")
    }

    /// A room of phones joining at once wants ONE keyframe between them. The
    /// requests collapse: the next frame carries it, the one after does not.
    @Test func repeatedRequestsCollapseIntoOneKeyframe() throws {
        let frame = try SRTEncodeTests.bands()
        let collected = SampleBox()
        let encoder = try Self.encoder(frame) { collected.store($0) }
        let step: Int64 = MPEGTSMuxer.clockHz / 25
        encoder.encode(frame, ticks: 0)
        for _ in 0..<3 { encoder.requestKeyframe() }
        encoder.encode(frame, ticks: step)
        encoder.encode(frame, ticks: 2 * step)
        encoder.invalidate()
        let samples: [CMSampleBuffer] = collected.samples
        #expect(samples.count == 3)
        #expect(MPEGTSMuxer.isKeyframe(samples[1]), "the ask was not answered")
        #expect(!MPEGTSMuxer.isKeyframe(samples[2]),
                "three asks produced more than one keyframe")
    }

    /// The bitrate is a dial on a RUNNING session, because rebuilding one costs
    /// the viewer a visible gap. And the average and its one-second burst
    /// ceiling move together: a lowered average left behind its old ceiling
    /// lets a keyframe burst at exactly the rate the link has just said it
    /// cannot carry.
    @Test func theBitrateAndItsBurstCeilingMoveTogether() throws {
        let frame = try SRTEncodeTests.bands()
        let encoder = try Self.encoder(frame) { _ in }
        defer { encoder.invalidate() }
        let before = try #require(encoder.appliedRate)
        #expect(before.average == 8_000_000)
        #expect(before.burstBytesPerSecond == 8_000_000 / 8 * 3 / 2)

        #expect(encoder.setBitsPerSecond(2_000_000).isEmpty,
                "the session refused the new rate")
        let after = try #require(encoder.appliedRate)
        #expect(after.average == 2_000_000)
        #expect(after.burstBytesPerSecond == 2_000_000 / 8 * 3 / 2,
                "the ceiling stayed behind the average")
        #expect(encoder.bitsPerSecond == 2_000_000)
    }

    /// A dial can be handed nonsense — a slider at zero, a computed rate from a
    /// link that reported nothing. The session must not be told it.
    @Test func thereIsAFloorUnderTheBitrate() throws {
        let frame = try SRTEncodeTests.bands()
        let encoder = try Self.encoder(frame) { _ in }
        defer { encoder.invalidate() }
        encoder.setBitsPerSecond(0)
        #expect(encoder.bitsPerSecond >= 64_000)
        let applied = try #require(encoder.appliedRate)
        #expect(applied.average >= 64_000)
    }
}
