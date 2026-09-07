import AudioToolbox
import CoreMedia
import Foundation
import Testing

@testable import TakeShotKit

/// **The sound is 44 ms late, measured — and then it is not.**
///
/// AAC-LC's transform is lapped: the first access unit an encoder produces
/// decodes to the window BEFORE the samples it was handed, so a decoder plays
/// 2112 frames of the codec's own priming and only then the first real sample.
/// The app stamped that first unit at the instant the packet arrived, which
/// tells the receiver to play the priming at the moment the sound began — and
/// everything after it lands 44 ms behind a picture that is on time, for the
/// life of the stream, on the director's feed.
///
/// Nothing said so and nothing measured it. The file's own comment said the
/// opposite: that the first call or two produce nothing and the delay is
/// therefore already accounted for. This suite settles both by encoding a
/// known impulse and decoding the stream back — the same discipline the
/// picture's levels are held to in `SRTEncodeTests`, and for the same reason:
/// a receiver 44 ms out of sync is an afternoon of everybody blaming the
/// camera department.
@Suite(.enabled(if: AACConverter.isSupported,
                "no AAC encoder on this machine"))
struct LiveAudioPrimingTests {
    private static let frames = LiveAudioEncoder.samplesPerAccessUnit
    private static let silentUnits = 3

    /// The codec answers for itself, and the answer is not zero.
    @Test func theCodecReportsItsOwnDelay() {
        #expect(AACConverter.primingFrames > 0, """
            AudioToolbox reported no encoder delay, so the correction below \
            is a no-op and the sound is back where it was
            """)
    }

    /// **Measured end to end: the tone comes out `primingFrames` late.**
    ///
    /// Three units of silence, then a tone. Decoded back, the tone starts at
    /// 3 × 1024 + the priming — not at 3 × 1024. That difference IS the bug,
    /// and stating it as a decoded sample index is what makes the correction
    /// a number rather than an opinion.
    @Test func theEncodedStreamCarriesTheToneLateByThePriming() throws {
        let codec = try AACConverter(channels: 2, bitsPerSecond: 128_000)
        var units: [[UInt8]] = []
        for index in 0..<8 {
            let level: Int16 = index >= Self.silentUnits ? 12_000 : 0
            let block = [Int16](repeating: level, count: Self.frames * 2)
            if let unit = codec.encode(block) { units.append(unit) }
        }
        // The other half of the same measurement, and the half the code's own
        // comment used to get wrong: the encoder does NOT prime by producing
        // nothing. Eight blocks in, eight units out, from the first call.
        #expect(units.count == 8,
                "\(units.count) units for 8 blocks — the encoder skipped some")

        let decoded = try Self.decode(units)
        let tone = try #require(decoded.firstIndex { abs($0) > 3_000 },
                                "the tone never came back out")
        #expect(tone / 2 == Self.silentUnits * Self.frames
                    + AACConverter.primingFrames, """
            the tone landed at frame \(tone / 2), not at \
            \(Self.silentUnits * Self.frames + AACConverter.primingFrames)
            """)
    }

    /// …so the stamps take it off, and the first unit of a run is stamped
    /// where the sound really starts.
    ///
    /// Asked of the anchor rather than of a running encoder: what a receiver
    /// sees is the DIFFERENCE between the audio stamp and the picture stamp
    /// for the same instant, and that is exactly the priming.
    @Test func theAnchorIsThePrimingEarlierThanTheArrival() {
        let clock = LiveClock()
        // The picture leg starts the clock a minute in, so the subtraction is
        // the whole story and the floor is nowhere near.
        let start: TimeInterval = 1_000
        _ = clock.origin(at: start)
        let picture = LiveVideoEncoder(bitsPerSecond: 1_000_000, clock: clock)
        let sound = LiveAudioEncoder(bitsPerSecond: 128_000, clock: clock)

        let moment: TimeInterval = start + 60
        let pictureTicks = picture.ticks(at: moment)
        let soundTicks = sound.anchorForTests(at: moment)
        let priming = Int64(AACConverter.primingFrames)
            * MPEGTSMuxer.clockHz / Int64(LiveAudioEncoder.sampleRate)
        // Within a tick, not to the tick. The subtraction is done in SECONDS
        // rather than in ticks, on purpose — that is what lets `LiveClock`
        // adopt the earlier instant as the origin when the sound leg is the
        // first to stamp — and a double-precision second truncated to 90 kHz
        // can land one tick either way. One tick is 11 µs.
        #expect(abs((pictureTicks - soundTicks) - priming) <= 1, """
            sound leads the picture by \(pictureTicks - soundTicks) ticks, \
            not by the codec's own delay of \(priming)
            """)
    }

    /// A stamp is never negative, whatever order the two legs start in.
    ///
    /// `MPEGTSMuxer.timestamp` masks to 33 bits, so a negative one would reach
    /// the receiver as a PTS twenty-six hours in the future: audio held
    /// forever, with nothing in any log.
    @Test func noOrderOfStartingProducesANegativeStamp() {
        // The sound leg first — `LiveClock` adopts the instant it is given, so
        // the origin moves back by the priming and everything stays positive.
        let soundFirst = LiveClock()
        let sound = LiveAudioEncoder(bitsPerSecond: 128_000, clock: soundFirst)
        #expect(sound.anchorForTests(at: 500) >= 0)

        // …and the picture leg first, by less than the priming: the floor.
        let pictureFirst = LiveClock()
        _ = pictureFirst.origin(at: 500)
        let squeezed = LiveAudioEncoder(bitsPerSecond: 128_000,
                                        clock: pictureFirst)
        #expect(squeezed.anchorForTests(at: 500.01) >= 0,
                "a leg starting 10 ms after the picture stamped in the past")
    }

    /// Decode a run of raw AAC access units back to interleaved 16-bit stereo.
    private static func decode(_ units: [[UInt8]]) throws -> [Int16] {
        var source = AudioStreamBasicDescription(
            mSampleRate: Double(LiveAudioEncoder.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(frames),
            mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0,
            mReserved: 0)
        var destination = AudioStreamBasicDescription(
            mSampleRate: Double(LiveAudioEncoder.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var built: AudioConverterRef?
        try #require(AudioConverterNew(&source, &destination, &built) == noErr)
        let converter = try #require(built)
        defer { AudioConverterDispose(converter) }

        let feed = UnitFeed(units: units)
        var out: [Int16] = []
        while true {
            var wanted = UInt32(frames)
            var pcm = [Int16](repeating: 0, count: frames * 2)
            let status: OSStatus = pcm.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 2,
                                          mDataByteSize: UInt32(raw.count),
                                          mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(
                    converter, UnitFeed.proc,
                    Unmanaged.passUnretained(feed).toOpaque(),
                    &wanted, &list, nil)
            }
            guard status == noErr, wanted > 0 else { break }
            out += pcm[0..<Int(wanted) * 2]
        }
        return out
    }
}

/// The access units one decode pulls, in an allocation that outlives the call —
/// the reason `AACConverter.PCMFeed` exists, in the other direction.
private final class UnitFeed {
    private let units: [[UInt8]]
    private var index = 0
    private var held: [UInt8] = []
    private var description = AudioStreamPacketDescription()

    init(units: [[UInt8]]) { self.units = units }

    static let proc: AudioConverterComplexInputDataProc
        = { _, packets, ioData, descriptions, context in
        guard let context else { packets.pointee = 0; return noErr }
        let feed = Unmanaged<UnitFeed>.fromOpaque(context).takeUnretainedValue()
        guard feed.index < feed.units.count else {
            packets.pointee = 0
            return noErr
        }
        feed.held = feed.units[feed.index]
        feed.index += 1
        feed.description = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(feed.held.count))
        packets.pointee = 1
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = 2
        ioData.pointee.mBuffers.mDataByteSize = UInt32(feed.held.count)
        feed.held.withUnsafeMutableBufferPointer {
            ioData.pointee.mBuffers.mData =
                UnsafeMutableRawPointer($0.baseAddress)
        }
        descriptions?.pointee = withUnsafeMutablePointer(to: &feed.description) {
            $0
        }
        return noErr
    }
}
