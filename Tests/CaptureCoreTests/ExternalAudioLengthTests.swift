import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

/// **A packet retimed onto the stream clock keeps its own length.**
///
/// An external packet is re-stamped on the way in — the USB device speaks the
/// host clock and the take is on the stream's — and the re-stamp was handing
/// CoreMedia a single timing entry whose duration was the WHOLE PACKET's. An
/// audio timing entry carries the duration of one SAMPLE, so that told it every
/// one of 1920 samples lasted 40 ms: a 40 ms packet came out claiming 76.8
/// seconds, 1920 times its own length, on every packet from every USB
/// interface.
///
/// Two things measured against that number, and both of them quietly stopped
/// working — which is the shape this suite exists to make impossible:
///
/// - the writer's own silence padding. `audioWrittenUntil` is where the take's
///   sound has reached, and the pad fires when the picture runs more than a
///   lead ahead of it. A cursor a minute and a quarter into the future is never
///   behind anything, so a sound cart that went quiet mid-take was never padded
///   by the writer at all.
/// - the channel detector, which accumulates seconds of measured audio to
///   decide which channels carry a stream. One packet looked like a minute of
///   evidence, so the answer was settled by the first 40 ms and the window it
///   was supposed to measure over never ran.
struct ExternalAudioLengthTests {
    private func pipeline(anchoredAt seconds: Double = 0) -> CapturePipeline {
        var settings = CaptureSettings()
        settings.audio.audioInputDeviceUID = "cart"
        let pipeline = CapturePipeline(config: .init(settings: settings,
                                                     takeNumber: 1))
        pipeline.audioSourceKind = .external
        pipeline.anchorExternalClock(
            framePTS: CMTime(seconds: seconds, preferredTimescale: 240_000))
        return pipeline
    }

    /// A 40 ms packet is still 40 ms after it has been placed on the stream
    /// clock — and it really did move, so this is not passing on a refusal.
    @Test func anAdmittedPacketKeepsItsOwnLength() throws {
        let pipeline = pipeline()
        var cache: CMAudioFormatDescription?
        let packet = try #require(
            AudioDelayTests.silence(atSeconds: 3, cache: &cache))
        let admitted = try #require(pipeline.admitExternalPacket(packet),
                                    "the packet was refused, not retimed")

        #expect(CMSampleBufferGetPresentationTimeStamp(admitted)
            != CMSampleBufferGetPresentationTimeStamp(packet),
                "nothing was retimed, so this proves nothing")
        let length = CMTimeGetSeconds(CMSampleBufferGetDuration(admitted))
        #expect(abs(length - 0.04) < 0.000_1,
                "a 40 ms packet came out \\(length)s long")
        #expect(CMSampleBufferGetNumSamples(admitted)
            == CMSampleBufferGetNumSamples(packet))
    }

    /// …which is the number the channel detector counts its evidence in.
    @Test func theDetectorIsGivenFortyMillisecondsOfEvidence() throws {
        let pipeline = pipeline()
        var cache: CMAudioFormatDescription?
        let packet = try #require(
            AudioDelayTests.silence(atSeconds: 3, cache: &cache))
        let admitted = try #require(pipeline.admitExternalPacket(packet))
        let seconds = PCMAudio.seconds(of: admitted)
        #expect(abs(seconds - 0.04) < 0.000_1, """
            one packet counted as \\(seconds)s of measurement — the channel \\
            window is settled by the first one that arrives
            """)
    }

    /// …and the one the writer's silence padding measures from. A cursor put
    /// into the future by a packet's own length is never behind the picture,
    /// and the pad that keeps a take's sound continuous never fires.
    @Test func theWritersAudioCursorLandsWhereTheSoundEnds() throws {
        let pipeline = pipeline()
        var cache: CMAudioFormatDescription?
        let packet = try #require(
            AudioDelayTests.silence(atSeconds: 3, cache: &cache))
        let admitted = try #require(pipeline.admitExternalPacket(packet))
        let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(admitted),
                            CMSampleBufferGetDuration(admitted))
        let start = CMTimeGetSeconds(
            CMSampleBufferGetPresentationTimeStamp(admitted))
        #expect(abs(CMTimeGetSeconds(end) - (start + 0.04)) < 0.000_1, """
            the cursor would land \\(CMTimeGetSeconds(end) - start)s past the \\
            packet's start
            """)
    }
}
