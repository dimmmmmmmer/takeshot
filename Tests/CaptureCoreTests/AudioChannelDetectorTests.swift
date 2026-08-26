@preconcurrency import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

/// What "this channel carried signal" is allowed to mean, and how long it takes
/// to be allowed to mean the opposite.
///
/// The whole feature rests on two numbers, and both of them are here rather than
/// in a comment: the floor (exact digital silence, and nothing above it) and the
/// window (one second before a channel's silence counts as an answer). A future
/// reader improving this into "peak above -60 dBFS over the last half second"
/// has to make these fail first, which is the point.
@Suite struct AudioChannelDetectorTests {
    /// A packet whose channel `loud` carries a peak of `peak`, and whose other
    /// channels are bit-exact zero.
    private static func levels(channels: Int, carrying loud: [Int],
                               peak: Int16 = 12_000) -> [Float] {
        var samples = [Int16](repeating: 0, count: 480 * channels)
        for channel in loud {
            for frame in 0..<480 {
                samples[frame * channels + channel] =
                    frame % 2 == 0 ? peak : Int16(-Int(peak))
            }
        }
        var cache: CMAudioFormatDescription?
        let buffer: CMSampleBuffer? = samples.withUnsafeBytes { raw in
            PCMAudio.makeSampleBuffer(bytes: raw.baseAddress!, sampleFrames: 480,
                                      channelCount: channels, ptsSeconds: 0,
                                      formatCache: &cache)
        }
        guard let buffer else { return [] }
        return PCMAudio.peakLevels(of: buffer)
    }

    /// The floor, pinned where it actually lives: exact digital silence reads
    /// `PCMAudio.silenceLevel`, and the SMALLEST non-zero sample an Int16 can
    /// carry reads above it. That gap is the whole measurement — remove it (by
    /// raising the floor past -90.3 dBFS, say) and the detector stops asking
    /// "is this channel carrying a stream" and starts asking "is it loud", which
    /// is the question standby cannot answer.
    @Test func exactSilenceIsTheOnlyThingBelowASingleSample() {
        let quiet: [Float] = Self.levels(channels: 2, carrying: [])
        #expect(quiet == [PCMAudio.silenceLevel, PCMAudio.silenceLevel])

        let faintest: [Float] = Self.levels(channels: 2, carrying: [1], peak: 1)
        #expect(faintest[0] == PCMAudio.silenceLevel)
        #expect(faintest[1] > PCMAudio.silenceLevel,
                "one LSB read as silence: \(faintest[1])")
        // …and it is nowhere near any floor anyone would pick by preference:
        // 20·log10(1/32767). A -60 dBFS gate would throw this channel away.
        #expect(abs(faintest[1] - -90.309) < 0.01,
                "the smallest non-zero peak moved: \(faintest[1])")
    }

    /// The answer itself: two channels of a sixteen-channel declaration carry,
    /// so two channels are recorded.
    @Test func onlyTheChannelsCarryingAStreamAreRecorded() {
        var detector = AudioChannelDetector()
        let levels: [Float] = Self.levels(channels: 16, carrying: [0, 1])
        for _ in 0..<25 { detector.note(levels: levels, seconds: 0.04) }

        #expect(detector.detectedMask == 0b11,
                "the mask was \(String(describing: detector.detectedMask))")
    }

    /// The window, from both sides. 24 packets is 0.96 s and answers nothing;
    /// the 25th reaches exactly one second and answers.
    ///
    /// Both directions on purpose: a detector that answered instantly would pass
    /// the second half of this and a detector that never answered would pass the
    /// first, and each of those is a different bug.
    @Test func theAnswerIsWithheldUntilASecondHasBeenObserved() {
        var detector = AudioChannelDetector()
        let levels: [Float] = Self.levels(channels: 16, carrying: [0, 1])
        for _ in 0..<24 { detector.note(levels: levels, seconds: 0.04) }

        #expect(detector.observed < AudioChannelDetector.minimumObservation)
        #expect(detector.detectedMask == nil,
                "0.96 s of standby was enough to call fourteen channels dead")

        detector.note(levels: levels, seconds: 0.04)
        #expect(detector.detectedMask == 0b11)
    }

    /// Accumulated, never a sliding window: a channel that carried a minute ago
    /// and is between words now is still a channel.
    ///
    /// This is the one an ordinary "recent peak" implementation fails, and it is
    /// the difference between recording the sound department's ISO tracks and
    /// recording whichever of them happened to be talking at take open.
    @Test func aChannelThatWentQuietAgainIsStillRecorded() {
        var detector = AudioChannelDetector()
        detector.note(levels: Self.levels(channels: 16, carrying: [0, 1, 5]),
                      seconds: 0.04)
        let quiet: [Float] = Self.levels(channels: 16, carrying: [0, 1])
        for _ in 0..<30 { detector.note(levels: quiet, seconds: 0.04) }

        let mask: Int? = detector.detectedMask
        #expect(mask == 0b100011, "channel 6 was dropped for going quiet: \(mask as Any)")
    }

    /// Nothing carrying is not an answer, it is the absence of one.
    ///
    /// A source that is bit-exact zero everywhere has told us it is silent, not
    /// which of its channels are real — and the two failure directions are not
    /// symmetric: following a signal up costs padded bandwidth, following it
    /// down costs footage. So this says nothing, the caller records everything,
    /// and `takeAudioStarved` stays reachable for the camera muted by mistake.
    @Test func aSourceWithNothingOnAnyChannelIsNotAnAnswer() {
        var detector = AudioChannelDetector()
        let silent: [Float] = Self.levels(channels: 16, carrying: [])
        for _ in 0..<100 { detector.note(levels: silent, seconds: 0.04) }

        #expect(detector.observed > AudioChannelDetector.minimumObservation * 3)
        #expect(detector.detectedMask == nil,
                "a silent source was read as a channel layout")
    }

    /// A source that renegotiates its own channel count is a new LAYOUT, and the
    /// old evidence is indexed by a width that no longer exists.
    ///
    /// Left alone, a mask carrying bit 8 from a sixteen-channel embed would
    /// survive into a two-channel one and name no channel it has — which is a
    /// take with no audio track at all, from a measurement that was trying to
    /// give it one.
    @Test func aChangeOfChannelCountStartsTheMeasurementOver() {
        var detector = AudioChannelDetector()
        let wide: [Float] = Self.levels(channels: 16, carrying: [8, 9])
        for _ in 0..<40 { detector.note(levels: wide, seconds: 0.04) }
        #expect(detector.detectedMask == 0b1100000000)

        let narrow: [Float] = Self.levels(channels: 2, carrying: [0])
        detector.note(levels: narrow, seconds: 0.04)
        #expect(detector.detectedMask == nil, "the old width's answer survived")
        for _ in 0..<40 { detector.note(levels: narrow, seconds: 0.04) }
        #expect(detector.detectedMask == 0b1)
    }

    /// A reset is a new source: the board restarting, or the operator moving
    /// between the embed and a USB cart.
    @Test func resetForgetsWhatTheOldSourceWasCarrying() {
        var detector = AudioChannelDetector()
        let levels: [Float] = Self.levels(channels: 16, carrying: [0, 1])
        for _ in 0..<40 { detector.note(levels: levels, seconds: 0.04) }
        #expect(detector.detectedMask == 0b11)

        detector.reset()

        #expect(detector.detectedMask == nil)
        #expect(detector.observed == 0)
        #expect(detector.carrying == 0)
    }

    /// Empty levels and zero-length packets are not observation, and must not
    /// advance the clock towards an answer — a source delivering nothing would
    /// otherwise talk itself into one.
    @Test func nothingIsObservedFromAnEmptyPacket() {
        var detector = AudioChannelDetector()
        for _ in 0..<100 { detector.note(levels: [], seconds: 0.04) }
        for _ in 0..<100 {
            detector.note(levels: Self.levels(channels: 2, carrying: [0]),
                          seconds: 0)
        }

        #expect(detector.observed == 0)
        #expect(detector.detectedMask == nil)
    }

    /// A packet's length comes from the packet. The fallback path matters
    /// because a detector that silently never accumulated would silently never
    /// answer, and the feature would look like it had simply been left out.
    @Test func aPacketReportsItsOwnLengthInSeconds() throws {
        var cache: CMAudioFormatDescription?
        let samples = [Int16](repeating: 0, count: 1920 * 2)
        let buffer: CMSampleBuffer = try #require(
            samples.withUnsafeBytes { raw in
                PCMAudio.makeSampleBuffer(bytes: raw.baseAddress!,
                                          sampleFrames: 1920, channelCount: 2,
                                          ptsSeconds: 0, formatCache: &cache)
            }, "the fixture packet could not be built")

        #expect(abs(PCMAudio.seconds(of: buffer) - 0.04) < 0.0005,
                "1920 frames at 48 kHz measured \(PCMAudio.seconds(of: buffer)) s")
    }

    /// …and a packet that does NOT state its own duration is measured from its
    /// sample count and the stream's rate instead.
    ///
    /// The fallback is the whole reason the helper exists rather than a call to
    /// `CMSampleBufferGetDuration` at the site. A source whose buffers carry no
    /// timing would otherwise accumulate nothing for ever, the measurement
    /// would never answer, and the feature would be indistinguishable from one
    /// that had been left out — the failure mode with no symptom.
    @Test func aPacketWithNoStatedDurationIsMeasuredFromItsSamples() throws {
        var cache: CMAudioFormatDescription?
        let samples = [Int16](repeating: 0, count: 1920 * 2)
        let stated: CMSampleBuffer = try #require(
            samples.withUnsafeBytes { raw in
                PCMAudio.makeSampleBuffer(bytes: raw.baseAddress!,
                                          sampleFrames: 1920, channelCount: 2,
                                          ptsSeconds: 0, formatCache: &cache)
            }, "the fixture packet could not be built")
        var timing = CMSampleTimingInfo(duration: CMTime.invalid,
                                        presentationTimeStamp: CMTime.zero,
                                        decodeTimeStamp: CMTime.invalid)
        var untimed: CMSampleBuffer?
        let status: OSStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: stated,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleBufferOut: &untimed)
        let packet: CMSampleBuffer = try #require(
            status == noErr ? untimed : nil,
            "an untimed copy could not be made (status \(status))")
        try #require(!CMSampleBufferGetDuration(packet).isNumeric,
                     "the copy still states a duration, so this proves nothing")

        #expect(abs(PCMAudio.seconds(of: packet) - 0.04) < 0.0005,
                "an untimed packet measured \(PCMAudio.seconds(of: packet)) s")
    }
}
