import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox

@testable import TakeShotKit

/// A real H.264 encode, measured rather than asserted.
///
/// The one claim in this whole feature that cannot be settled by reading bytes is
/// what the LEVELS come out as. The display buffer is full-range BGRA whose codes
/// are Rec.709-encoded; the stream is video-range YCbCr tagged Rec.709. Nothing in
/// the app performs that conversion — VideoToolbox does, as a side effect of being
/// told what to tag the output with — so whether nominal black lands on black at
/// the far end is a fact about the encoder and not about this code.
///
/// So it is measured the way the record path's levels are: encode a known frame,
/// decode it back, and compare the codes. That is not a substitute for a real
/// receiver, and the file says which parts still need one — but a receiver showing
/// a washed-out picture would be a two-hour hunt, and this settles it in a second.
@Suite(.enabled(if: SRTVideoEncoder.isSupported,
                "no H.264 encoder on this machine"))
struct SRTEncodeTests {
    /// A three-band frame: black, mid grey, white, as the display path would hand
    /// them over. Full range — 0 and 255 are the ends of the display buffer's
    /// scale, which is what `WireDisplayTable` puts nominal black and white on.
    private static func bands(width: Int = 320, height: Int = 192) throws
        -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                            &buffer)
        let result: CVPixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        let stride: Int = CVPixelBufferGetBytesPerRow(result)
        if let base = CVPixelBufferGetBaseAddress(result) {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let levels: [UInt8] = [0, 128, 255]
            for row in 0..<height {
                for column in 0..<width {
                    let level: UInt8 = levels[column * 3 / width]
                    let pixel = row * stride + column * 4
                    bytes[pixel] = level
                    bytes[pixel + 1] = level
                    bytes[pixel + 2] = level
                    bytes[pixel + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }

    /// The mean grey of the pixels in one third of a decoded BGRA frame.
    private static func band(_ buffer: CVPixelBuffer, third: Int) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride: Int = CVPixelBufferGetBytesPerRow(buffer)
        let width: Int = CVPixelBufferGetWidth(buffer)
        let height: Int = CVPixelBufferGetHeight(buffer)
        // The middle half of the band only: an encoder puts ringing on a hard
        // edge, and the question here is what the FLAT area came out as.
        let from: Int = width * third / 3 + width / 12
        let upto: Int = width * (third + 1) / 3 - width / 12
        var total = 0.0
        var count = 0
        for row in height / 4..<(height * 3 / 4) {
            for column in from..<upto {
                total += Double(bytes[row * stride + column * 4 + 1])
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : -1
    }

    /// One encoded sample decoded straight back to BGRA.
    private static func decoded(_ sample: CMSampleBuffer) throws -> CVPixelBuffer {
        let format: CMFormatDescription =
            try #require(CMSampleBufferGetFormatDescription(sample))
        var session: VTDecompressionSession?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session)
        let live: VTDecompressionSession = try #require(session)
        defer { VTDecompressionSessionInvalidate(live) }
        let box = DecodedFrameBox()
        VTDecompressionSessionDecodeFrame(
            live, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { status, _, image, _, _ in
            if status == noErr, let image { box.store(image) }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(live)
        return try #require(box.image)
    }

    /// Encode `frames` frames of one buffer and hand back the samples.
    private static func encode(_ buffer: CVPixelBuffer, frames: Int = 1,
                               framesPerSecond: Int = 25) throws
        -> [CMSampleBuffer] {
        let collected = SampleBox()
        let encoder = try SRTVideoEncoder(
            configuration: SRTVideoEncoder.Configuration(
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                framesPerSecond: framesPerSecond, bitsPerSecond: 8_000_000),
            sink: { collected.store($0) })
        let step: Int64 = MPEGTSMuxer.clockHz / Int64(framesPerSecond)
        for frame in 0..<frames {
            encoder.encode(buffer, ticks: Int64(frame) * step)
        }
        encoder.invalidate()
        return collected.samples
    }

    /// **The levels, measured.** Full-range BGRA in, and after a real encode and
    /// decode the same three bands come back where they went in.
    ///
    /// This is the claim a director's monitor depends on. Had VideoToolbox treated
    /// the BGRA as video-range on the way in, black would come back at 40-odd and
    /// white clipped — the washed-out picture the viewer's own
    /// `AVSampleBufferDisplayLayer` ban exists because of, arriving by a different
    /// route.
    @Test func theDisplayBuffersLevelsSurviveTheEncode() throws {
        let source: CVPixelBuffer = try Self.bands()
        let samples: [CMSampleBuffer] = try Self.encode(source, frames: 3)
        let sample: CMSampleBuffer = try #require(samples.first)
        let back: CVPixelBuffer = try Self.decoded(sample)
        let measured: [Double] = [0, 1, 2].map { Self.band(back, third: $0) }
        // **The tolerance is a decision, and it is why this asserts at all.**
        // The ProRes 4444 case in CLAUDE.md is the cautionary one: it pinned what
        // the HOST's encoder does with codes outside the nominal pair, and came
        // out green here and red on the macOS 15 runner. This is a narrower claim
        // — three codes INSIDE the nominal pair, through one machine's own
        // VideoToolbox in both directions, which is a round trip rather than a
        // convention. 6 of 255 is loose enough for an 8 Mbit/s H.264 of a flat
        // field on any encoder and far tighter than the failure it exists for: a
        // range conversion moves black by 16 and clips white.
        #expect(abs(measured[0] - 0) <= 6,
                "black came back at \(measured[0]) of 255")
        #expect(abs(measured[1] - 128) <= 6,
                "mid grey came back at \(measured[1]) of 255")
        #expect(abs(measured[2] - 255) <= 6,
                "white came back at \(measured[2]) of 255")
    }

    /// …and the stream says it is Rec.709, which is what makes the numbers above
    /// mean anything at the far end.
    @Test func theStreamDeclaresRec709() throws {
        let samples: [CMSampleBuffer] = try Self.encode(try Self.bands())
        let sample: CMSampleBuffer = try #require(samples.first)
        let format: CMFormatDescription =
            try #require(CMSampleBufferGetFormatDescription(sample))
        let extensions: [CFString: Any] = try #require(
            CMFormatDescriptionGetExtensions(format) as? [CFString: Any])
        #expect(extensions[kCMFormatDescriptionExtension_ColorPrimaries]
            as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        #expect(extensions[kCMFormatDescriptionExtension_TransferFunction]
            as? String == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        #expect(extensions[kCMFormatDescriptionExtension_YCbCrMatrix]
            as? String == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    }

    /// **Frame reordering is off, which is why the muxer carries one timestamp.**
    /// Every sample comes out in the order it went in, so presentation order is
    /// coding order and a DTS would be the PTS written twice.
    @Test func thereIsNoFrameReorderingSoOneTimestampIsEnough() throws {
        let samples: [CMSampleBuffer] = try Self.encode(try Self.bands(),
                                                        frames: 12)
        #expect(samples.count == 12, "\(samples.count) samples for 12 frames")
        let stamps: [Int64] = samples.map {
            CMSampleBufferGetPresentationTimeStamp($0).value
        }
        #expect(stamps == stamps.sorted(), "the samples came out reordered")
        for sample in samples {
            let decode: CMTime = CMSampleBufferGetDecodeTimeStamp(sample)
            guard decode.isValid else { continue }
            #expect(decode == CMSampleBufferGetPresentationTimeStamp(sample),
                    "a sample's decode time differs from its presentation time")
        }
    }

    /// The first sample is a keyframe and its parameter sets go into the stream in
    /// front of it. That is what makes a receiver opened twenty minutes into a
    /// setup get a picture rather than a green rectangle.
    @Test func aKeyframeCarriesItsParameterSetsInline() throws {
        let samples: [CMSampleBuffer] = try Self.encode(try Self.bands(),
                                                        frames: 4)
        let first: CMSampleBuffer = try #require(samples.first)
        #expect(MPEGTSMuxer.isKeyframe(first))
        let unit: MPEGTSMuxer.AccessUnit =
            try #require(MPEGTSMuxer.accessUnit(from: first))
        #expect(unit.isKeyframe)
        // The access-unit delimiter, then a sequence parameter set (NAL type 7)
        // and a picture parameter set (8), then the slice.
        let types: [UInt8] = Self.nalTypes(unit.payload)
        #expect(types.first == 9, "no access-unit delimiter: \(types)")
        #expect(types.contains(7), "no sequence parameter set: \(types)")
        #expect(types.contains(8), "no picture parameter set: \(types)")
        // …and every start code is the four-byte one this muxer emits.
        #expect(unit.payload.count >= 4)
        #expect(Array(unit.payload[0..<4]) == [0x00, 0x00, 0x00, 0x01])
    }

    /// An inter frame carries no parameter sets: they are 30-odd bytes and a
    /// receiver already has them by then. Resending per frame would be the
    /// commonest way to make this stream fatter than it needs to be.
    @Test func anInterFrameCarriesNoParameterSets() throws {
        let samples: [CMSampleBuffer] = try Self.encode(try Self.bands(),
                                                        frames: 8)
        // The keyframe interval is one second at 25 fps, so frames 2-8 are inter
        // frames. Find one the encoder agrees is not a sync sample.
        let inter: CMSampleBuffer = try #require(
            samples.dropFirst().first { !MPEGTSMuxer.isKeyframe($0) })
        let unit: MPEGTSMuxer.AccessUnit =
            try #require(MPEGTSMuxer.accessUnit(from: inter))
        #expect(!unit.isKeyframe)
        let types: [UInt8] = Self.nalTypes(unit.payload)
        #expect(!types.contains(7), "an inter frame carries an SPS: \(types)")
        #expect(!types.contains(8), "an inter frame carries a PPS: \(types)")
    }

    /// **The session really applied what it was told.**
    ///
    /// Every other test in this file would pass with the bitrate and the keyframe
    /// interval unset: the stream still encodes, still tags Rec.709 and still
    /// comes out in order — it just comes out at whatever VideoToolbox defaults
    /// to, which is not what the operator typed. The refusals are collected for
    /// exactly this, and this is the only place that reads them.
    @Test func theSessionAppliesEveryPropertyItIsGiven() throws {
        let encoder = try SRTVideoEncoder(
            configuration: SRTVideoEncoder.Configuration(
                width: 320, height: 192, framesPerSecond: 25,
                bitsPerSecond: 6_000_000),
            sink: { _ in })
        defer { encoder.invalidate() }
        #expect(encoder.refusedProperties == [String](),
                "the encoder refused \(encoder.refusedProperties)")
    }

    /// The keyframe interval IS the join time, so it is one second and not ten.
    /// Derived rather than measured — a GOP is what the encoder does with this
    /// number, and the number is ours.
    @Test func theKeyframeIntervalIsOneSecondAtEveryRate() {
        for fps in [24, 25, 30, 50, 60] {
            let configuration = SRTVideoEncoder.Configuration(
                width: 1920, height: 1080, framesPerSecond: fps,
                bitsPerSecond: 8_000_000)
            #expect(configuration.keyframeInterval == fps,
                    "\(fps) fps asks for a \(configuration.keyframeInterval)-frame GOP")
        }
        // …and a rate nothing has stated cannot ask for a GOP of zero.
        let unknown = SRTVideoEncoder.Configuration(
            width: 1920, height: 1080, framesPerSecond: 0,
            bitsPerSecond: 8_000_000)
        #expect(unknown.keyframeInterval == 1)
    }

    /// The NAL unit types in an Annex B payload, in order.
    private static func nalTypes(_ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var index = 0
        while index + 4 < payload.count {
            if payload[index] == 0, payload[index + 1] == 0,
               payload[index + 2] == 0, payload[index + 3] == 1 {
                out.append(payload[index + 4] & 0x1F)
                index += 5
            } else {
                index += 1
            }
        }
        return out
    }
}

/// A box for the decoded frame, because the decode handler runs on
/// VideoToolbox's queue.
final class DecodedFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CVPixelBuffer?

    func store(_ image: CVImageBuffer) {
        lock.withLock { stored = image }
    }

    var image: CVPixelBuffer? { lock.withLock { stored } }
}

/// …and one for the encoded samples, for the same reason.
final class SampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CMSampleBuffer] = []

    func store(_ sample: CMSampleBuffer) {
        lock.withLock { stored.append(sample) }
    }

    var samples: [CMSampleBuffer] { lock.withLock { stored } }
}
