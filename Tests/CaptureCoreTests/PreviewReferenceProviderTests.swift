import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// **A reference that PLAYS**, fed into the compare from another engine's queue.
///
/// A pin is one still: deep-copied once, composited until it is replaced. The
/// owner's report is that a reference pinned from playback holds as a still on
/// the record page ("реф видео из плейбека при пине на странице река не играет
/// как видео а остается стиллом"), so a clip has to be able to hand the compare
/// a new frame per frame — without the capture queue ever waiting on the decode
/// that produced it. These pin the pipeline half of that: the provider, the
/// fallback, and the cache that must not be used for a moving frame.
@Suite struct PreviewReferenceProviderTests {
    /// The front half of a vertical wipe at the seam's left, which is where the
    /// reference is: `CompareCompositor.compose` puts `front` on the left.
    private func leftHalf(_ buffer: CVPixelBuffer) -> Int {
        PreviewProbe.level(of: buffer, atFractionX: 0.25)
    }

    /// The moving frame is what gets composited, not the pinned still.
    @Test func aProvidedReferenceFrameIsWhatTheWipeComposites() async throws {
        let pipeline = PreviewProbe.makePipeline()
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0[.decorated]) }
        defer { pipeline.setOnDisplayFrame(nil) }

        // A still pinned first, so a pass that ignored the provider would
        // still find something to composite — and would show 0x40.
        pipeline.setPreviewReference(buffer: PreviewProbe.frame(0x40))
        let moving = PreviewProbe.frame(0x80)
        pipeline.setReferenceFrameProvider { moving }
        defer { pipeline.setReferenceFrameProvider(nil) }
        pipeline.setPreviewCompare(.wipe(axis: .vertical, position: 0.5))

        PreviewProbe.push(pipeline, PreviewProbe.frame(0x20), frame: 1)
        await TestWait.until { collector.count > 0 }
        let presented = try #require(collector.last, "nothing was presented")
        #expect(leftHalf(presented) == 0x80, """
            the wipe composited \(leftHalf(presented)) — that is the pinned \
            still, not the frame the clip is playing
            """)
    }

    /// Clearing the provider puts the pinned still back rather than leaving a
    /// dead closure holding the last decoded frame for ever.
    @Test func aClearedProviderFallsBackToThePinnedStill() async throws {
        let pipeline = PreviewProbe.makePipeline()
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0[.decorated]) }
        defer { pipeline.setOnDisplayFrame(nil) }

        pipeline.setPreviewReference(buffer: PreviewProbe.frame(0x40))
        let moving = PreviewProbe.frame(0x80)
        pipeline.setReferenceFrameProvider { moving }
        pipeline.setPreviewCompare(.wipe(axis: .vertical, position: 0.5))
        PreviewProbe.push(pipeline, PreviewProbe.frame(0x20), frame: 1)
        await TestWait.until { collector.count > 0 }
        try #require(leftHalf(try #require(collector.last)) == 0x80,
                     "the provider never reached the composite")

        pipeline.setReferenceFrameProvider(nil)
        let before = collector.count
        PreviewProbe.push(pipeline, PreviewProbe.frame(0x20), frame: 2)
        await TestWait.until { collector.count > before }
        let presented = try #require(collector.last)
        #expect(leftHalf(presented) == 0x40, """
            after the clip was unpinned the compare shows \(leftHalf(presented)) \
            — the still it was pinned with is 0x40
            """)
    }

    /// **A moving reference is not served out of the fitted cache.**
    ///
    /// That cache keys on the buffer's IDENTITY, and a playing clip's frames
    /// come out of a pool — the same object with different pixels in it, which
    /// is exactly the case `===` cannot see. A pin is a private deep copy and
    /// can never collide, which is why the cache was safe until now.
    @Test func aMovingReferenceIsNotServedFromTheFittedCache() async throws {
        let pipeline = PreviewProbe.makePipeline()
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0[.decorated]) }
        defer { pipeline.setOnDisplayFrame(nil) }

        // ONE buffer, rewritten between frames — a pool handing the same
        // object back is the whole point.
        let recycled = PreviewProbe.frame(0x80)
        pipeline.setReferenceFrameProvider { recycled }
        defer { pipeline.setReferenceFrameProvider(nil) }
        pipeline.setPreviewCompare(.wipe(axis: .vertical, position: 0.5))
        PreviewProbe.push(pipeline, PreviewProbe.frame(0x20), frame: 1)
        await TestWait.until { collector.count > 0 }
        try #require(leftHalf(try #require(collector.last)) == 0x80)

        PreviewProbe.fill(recycled, level: 0xC0)
        let before = collector.count
        PreviewProbe.push(pipeline, PreviewProbe.frame(0x20), frame: 2)
        await TestWait.until { collector.count > before }
        let presented = try #require(collector.last)
        #expect(leftHalf(presented) == 0xC0, """
            the composite still shows \(leftHalf(presented)) — the cached fit \
            of a buffer whose pixels have been replaced
            """)
    }

    /// The difference half reads the same provided frame. Identical pictures
    /// come out exact black, which is the measurement that mode exists for —
    /// and it fails the moment the provider reaches only the wipe arm.
    @Test func theDifferenceHalfReadsTheSameProvidedFrame() async throws {
        let pipeline = PreviewProbe.makePipeline()
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0[.decorated]) }
        defer { pipeline.setOnDisplayFrame(nil) }

        pipeline.setPreviewReference(buffer: PreviewProbe.frame(0x40))
        let moving = PreviewProbe.frame(0x20)
        pipeline.setReferenceFrameProvider { moving }
        defer { pipeline.setReferenceFrameProvider(nil) }
        pipeline.setPreviewCompare(.difference(gain: 16))

        PreviewProbe.push(pipeline, PreviewProbe.frame(0x20), frame: 1)
        await TestWait.until { collector.count > 0 }
        let presented = try #require(collector.last)
        let value = PreviewProbe.level(of: presented, atFractionX: 0.5)
        #expect(value == 0, """
            the difference reads \(value) against a frame identical to the \
            provided one — it is measuring the pinned still instead
            """)
    }
}
