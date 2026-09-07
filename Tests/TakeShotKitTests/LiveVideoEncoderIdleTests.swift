import CaptureCore
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **An idle set encodes nothing**, which is the property the whole shared-encoder
/// design is arranged around — and the one that made a test flake when it was
/// first put in, so it is worth pinning as arithmetic rather than as timing.
///
/// Nobody watching means no `VTCompressionSession` is ever created at all: not a
/// session sitting idle, not a session encoding into a sink that discards. The
/// consequence a caller has to know about is on the other side of the same
/// coin — a frame offered while nothing is subscribed is DROPPED, not held, so
/// whoever subscribes gets the next frame rather than the last one.
@Suite(.enabled(if: SRTVideoEncoder.isSupported,
                "no H.264 encoder on this machine"))
struct LiveVideoEncoderIdleTests {
    @Test func nothingIsEncodedWhileNothingIsWatching() async throws {
        let encoder = LiveVideoEncoder(bitsPerSecond: 4_000_000)
        defer { encoder.stop() }
        let buffer = try SRTFixtures.displayBuffer()
        for _ in 0..<5 {
            encoder.offer(buffer, framesPerSecond: 25)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(!encoder.hasSinks)
        #expect(encoder.appliedBitsPerSecond == nil,
                "a session was built for nobody")
    }

    /// And the moment something IS watching, the next frame reaches it.
    @Test func theFirstFrameAfterASinkArrivesReachesIt() async throws {
        let encoder = LiveVideoEncoder(bitsPerSecond: 4_000_000)
        defer { encoder.stop() }
        let samples = SampleCounter()
        encoder.addSink(samples) { _ in samples.count() }
        let buffer = try SRTFixtures.displayBuffer()
        let deadline = Date().addingTimeInterval(5)
        while samples.total == 0, Date() < deadline {
            encoder.offer(buffer, framesPerSecond: 25)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(samples.total > 0, "a subscribed sink got nothing")
        #expect(encoder.appliedBitsPerSecond == 4_000_000)
    }
}

/// Samples that reached a sink. Its identity is the sink's key, so it is a
/// class; the count is touched from VideoToolbox's thread, so it is locked.
final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func count() { lock.withLock { stored += 1 } }
    var total: Int { lock.withLock { stored } }
}

/// **The shared encoder declares the colour it was HANDED, and follows it when
/// it changes.**
///
/// One `VTCompressionSession` serves SRT, the web remote and everything else
/// watching the same picture, and it is rebuilt when the raster or the rate
/// moves. The COLOUR was not in that identity and was not read at all: the
/// session declared Rec.709 as a constant, over a display buffer this app had
/// itself tagged Rec.2020 whenever the camera was sending PQ or HLG. The
/// director's laptop drew wide-gamut coordinates as narrow ones — a
/// desaturated picture next to a correct one on the cart, which is the version
/// of this that costs an hour of arguing about which screen is lying.
@Suite(.enabled(if: SRTVideoEncoder.isSupported,
                "no H.264 encoder on this machine"))
struct LiveVideoEncoderColourTests {
    /// The primaries the far end reads off a sample.
    private static func primaries(_ sample: CMSampleBuffer) -> String? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let extensions = CMFormatDescriptionGetExtensions(format)
                as? [CFString: Any]
        else { return nil }
        return extensions[kCMFormatDescriptionExtension_ColorPrimaries]
            as? String
    }

    /// Offer one buffer until a sample comes back, and hand back that sample.
    private static func encodeOne(_ encoder: LiveVideoEncoder,
                                  _ buffer: CVPixelBuffer,
                                  into box: SampleBox) async throws
        -> CMSampleBuffer {
        let before = box.samples.count
        let deadline = Date().addingTimeInterval(5)
        while box.samples.count == before, Date() < deadline {
            encoder.offer(buffer, framesPerSecond: 25)
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(box.samples.last, "no sample came back in 5 s")
    }

    @Test func aCameraChangingToHDRChangesWhatTheStreamDeclares() async throws {
        let encoder = LiveVideoEncoder(bitsPerSecond: 4_000_000)
        defer { encoder.stop() }
        let box = SampleBox()
        encoder.addSink(box) { box.store($0) }

        // An SDR day: untagged, which IS Rec.709 and is almost every day.
        let sdr = try SRTFixtures.displayBuffer()
        let first = try await Self.encodeOne(encoder, sdr, into: box)
        #expect(Self.primaries(first)
                == kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
                "an SDR frame was declared \(Self.primaries(first) ?? "nothing")")

        // The camera is swapped for one sending PQ. `CapturePipeline` tone maps
        // the frame into a Rec.709 curve and tags it Rec.2020 primaries, which
        // is what the display buffer really holds.
        let hdr = try SRTFixtures.displayBuffer()
        ColorTags.tag(hdr, preset: ColorTags.rec2020Preset)
        let second = try await Self.encodeOne(encoder, hdr, into: box)
        #expect(Self.primaries(second)
                == kCVImageBufferColorPrimaries_ITU_R_2020 as String,
                """
                the session went on declaring \
                \(Self.primaries(second) ?? "nothing") after the signal changed
                """)
    }
}
