import Foundation
import Testing

@testable import CaptureCore

/// **Lining sound up with picture by listening to both** (owner: "синк дублей
/// не только по таймкоду со звуком но еще и по вейвформе").
///
/// The signals here are shaped like what this really meets: two microphones on
/// one room, at different gains, with different noise, one of them recording
/// for much longer than the other. What must never happen is a confident
/// answer about two recordings that have nothing to do with each other — a
/// sound file attached to the wrong take is worse than one attached to
/// nothing.
@Suite struct WaveformSyncTests {
    private let rate = 48_000.0

    /// **A room, recorded from `from` for `seconds`.**
    ///
    /// The loudness contour is a function of ABSOLUTE time — a deterministic
    /// aperiodic walk — so two recordings of the same room that start at
    /// different moments really are recordings of the same thing, which is
    /// the whole situation being tested. `gain` and `noise` are what make them
    /// two different recordings: a boom and a camera mic are metres apart, at
    /// different gains, on different preamps.
    ///
    /// **Aperiodic on purpose.** The first version of this fixture modulated
    /// at fixed rates — syllables at exactly 4 Hz under a phrase at 0.17 —
    /// and a periodic envelope correlates with itself at many lags, so the
    /// right answer had no room to stand out. Real material does not repeat;
    /// a fixture that does is testing a harder problem than the one this
    /// solves, and failing it for the wrong reason.
    ///
    /// `room` is which room: two different values are two different scenes.
    /// `events` makes the material SPARSE instead of continuous: a few thumps
    /// in a quiet room, which is the shape the guards exist for — on it, any
    /// two segments that each contain one event correlate at almost exactly 1.
    private func room(from start: Double, seconds: Double, gain: Double = 1,
                      noise: Double = 0.02, seed: UInt64 = 1,
                      room: UInt64 = 100,
                      events: [Double]? = nil) -> [Int16] {
        var random = SeededRandom(seed)
        let frames = Int(seconds * rate)
        var out = [Int16](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let t = start + Double(frame) / rate
            // Spelled out step by step rather than as one expression: the
            // older compiler on CI times out type-checking a chain of this
            // shape (docs/ARCHITECTURE.md), and it costs nothing to split.
            let noiseValue: Double = (random.next() - 0.5) * 2 * noise
            let level: Double = events == nil
                ? contour(at: t, room: room) : 0
            let carrier: Double = sin(2 * .pi * 220 * t)
            var value: Double = noiseValue + gain * 0.5 * level * carrier
            for event in events ?? [] where t >= event && t < event + 0.25 {
                let age: Double = t - event
                let decay: Double = exp(-age * 12)
                let thump: Double = sin(2 * .pi * 180 * age)
                value += gain * 0.6 * decay * thump
            }
            let scaled: Double = value * 32_767
            let sample = Int16(max(-32_767, min(32_767, scaled)))
            out[frame * 2] = sample
            out[frame * 2 + 1] = sample
        }
        return out
    }

    /// The room's loudness at an absolute moment: a random value every 50 ms,
    /// interpolated. Deterministic in `t` and `room` and in nothing else.
    private func contour(at t: Double, room: UInt64) -> Double {
        let step = 0.05
        let index = Int((t / step).rounded(.down))
        let fraction = t / step - Double(index)
        let a = hashed(index, room: room)
        let b = hashed(index + 1, room: room)
        return a + (b - a) * fraction
    }

    private func hashed(_ index: Int, room: UInt64) -> Double {
        var x = UInt64(bitPattern: Int64(index)) &+ room &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 33
        x = x &* 0xFF51_AFD7_ED55_8CCD
        x ^= x >> 33
        x = x &* 0xC4CE_B9FE_1A85_EC53
        x ^= x >> 33
        return Double(x >> 11) / Double(UInt64(1) << 53)
    }

    /// Deterministic noise: a run that matched differently on a second pass
    /// would be a flaky suite about a flaky feature.
    private struct SeededRandom {
        private var state: UInt64
        init(_ seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
    }

    private func envelope(_ samples: [Int16],
                          window: Double = WaveformSync.coarseWindow) -> [Double] {
        WaveformSync.envelope(samples, channels: 2, sampleRate: rate,
                              window: window)
    }

    // MARK: - the envelope

    @Test func theEnvelopeIsOneValuePerWindow() {
        let samples = room(from: 0, seconds: 2)
        #expect(envelope(samples).count == 10)
        #expect(envelope(samples, window: 0.02).count == 100)
    }

    /// A window that cannot be filled is not a window: a clip shorter than one
    /// has no envelope at all rather than a partial one nobody can compare.
    @Test func aClipShorterThanOneWindowHasNoEnvelope() {
        #expect(envelope(room(from: 0, seconds: 0.1)).isEmpty)
        #expect(WaveformSync.envelope([], channels: 2, sampleRate: rate,
                                      window: 0.2).isEmpty)
    }

    /// The envelope follows the room rather than the carrier: two recordings
    /// of one moment at different GAINS have envelopes that differ by a
    /// factor, which is exactly what a correlation is blind to.
    @Test func theEnvelopeFollowsTheRoomAndNotTheGain() throws {
        let loud = envelope(room(from: 0, seconds: 4, gain: 1, noise: 0))
        let quiet = envelope(room(from: 0, seconds: 4, gain: 0.25, noise: 0))
        #expect(loud.count == quiet.count)
        let ratios = zip(loud, quiet).map { $0 / max(1e-9, $1) }
        let mean = ratios.reduce(0, +) / Double(ratios.count)
        #expect(abs(mean - 4) < 0.2, "the gains differ by \(mean)")
        #expect(ratios.allSatisfy { abs($0 - mean) < 0.5 },
                "the shape changed with the gain")
    }

    // MARK: - the alignment

    /// **The whole feature**: the same room, recorded twice at different
    /// gains with different noise, one of them starting four seconds earlier.
    @Test func theSameRoomLinesUpWhereverItStarted() throws {
        let sound = room(from: 0, seconds: 14, gain: 1, seed: 1)
        // the picture starts 4 s into the sound, at a third of the gain, with
        // its own noise
        let picture = room(from: 4, seconds: 8, gain: 0.35, noise: 0.05,
                           seed: 9)
        let found: WaveformSync.Alignment = try #require(
            WaveformSync.align(picture: envelope(picture),
                               sound: envelope(sound)))
        #expect(found.isCredible,
                Comment(rawValue: "peak \(found.peak), "
                    + "prominence \(found.prominence)"))
        // 4 s at the coarse window is lag 20
        #expect(abs(found.offsetIntoSound - 20) <= 1,
                "the lag came out \(found.offsetIntoSound)")
    }

    /// …and a picture that starts BEFORE the sound is a negative lag, which is
    /// the recordist rolling late and the head of the take having no sound.
    @Test func aPictureThatStartsFirstIsANegativeLag() throws {
        // the recordist rolled three seconds after the camera
        let picture = room(from: 0, seconds: 12, seed: 3)
        let sound = room(from: 3, seconds: 8, gain: 0.8, noise: 0.03, seed: 4)
        let found: WaveformSync.Alignment = try #require(
            WaveformSync.align(picture: envelope(picture),
                               sound: envelope(sound)))
        #expect(found.isCredible)
        #expect(abs(found.offsetIntoSound - -15) <= 1,
                "the lag came out \(found.offsetIntoSound)")
    }

    /// **The case that must never produce a confident answer.** Two rooms with
    /// nothing in common still have a best lag — there is always a maximum —
    /// and what says it means nothing is that it does not stand out.
    ///
    /// Sparse material on purpose: this is the shape that produced a peak of
    /// 0.9999 and an infinite prominence before the coverage floor and the
    /// standard-deviation measure, because a single thump matches a single
    /// thump at the very edge of the search.
    @Test func twoUnrelatedRecordingsAreNotCredible() throws {
        let sound = room(from: 0, seconds: 14, seed: 11, room: 100)
        let picture = room(from: 0, seconds: 8, seed: 77, room: 7)
        let found: WaveformSync.Alignment = try #require(
            WaveformSync.align(picture: envelope(picture),
                               sound: envelope(sound)))
        #expect(!found.isCredible,
                Comment(rawValue: "peak \(found.peak), "
                    + "prominence \(found.prominence)"))
    }

    /// Silence against silence is not a match, however well the two agree: an
    /// envelope with no shape in it has nothing to correlate.
    @Test func silenceAgainstSilenceIsNotAMatch() {
        let quiet = [Double](repeating: 0, count: 40)
        #expect(WaveformSync.correlation(picture: quiet, sound: quiet,
                                         lag: 0) == nil)
        #expect(WaveformSync.align(picture: quiet, sound: quiet) == nil)
    }

    /// A match decided on a fifth of a second of shared material is a
    /// coincidence with a number attached.
    @Test func aSliverOfOverlapIsNotComparedAtAll() {
        let a: [Double] = (0..<20).map { Double($0 % 5) }
        let b: [Double] = (0..<20).map { Double(($0 + 2) % 5) }
        // three windows of overlap
        #expect(WaveformSync.correlation(picture: a, sound: b, lag: 17) == nil)
        #expect(WaveformSync.correlation(picture: a, sound: b, lag: 8) != nil)
    }

    /// The search can be bounded, which is what makes the fine pass cheap: it
    /// only ever looks in the neighbourhood the coarse pass found.
    @Test func theSearchCanBeBoundedToANeighbourhood() throws {
        let sound = room(from: 0, seconds: 14, seed: 1)
        let picture = room(from: 4, seconds: 8, gain: 0.35, noise: 0.05,
                           seed: 9)
        let fine = WaveformSync.fineWindow
        let coarse: WaveformSync.Alignment = try #require(
            WaveformSync.align(picture: envelope(picture),
                               sound: envelope(sound)))
        // the same answer, in fine windows, searched only around the coarse one
        let centre = Int(coarse.offsetIntoSound
            * WaveformSync.coarseWindow / fine)
        let step = Int(WaveformSync.coarseWindow / fine)
        let refined: WaveformSync.Alignment = try #require(
            WaveformSync.align(picture: envelope(picture, window: fine),
                               sound: envelope(sound, window: fine),
                               lags: (centre - step)...(centre + step)))
        #expect(abs(Double(refined.offsetIntoSound) * fine - 4) < 0.1,
                "the refined lag is \(Double(refined.offsetIntoSound) * fine)s")
    }

    @Test func nothingToAlignIsNoAnswer() {
        #expect(WaveformSync.align(picture: [], sound: [1, 2, 3]) == nil)
        #expect(WaveformSync.align(picture: [1, 2, 3], sound: []) == nil)
    }
    // MARK: - coarse to fine

    /// **The pair this type exists to be**: the coarse pass finds the second,
    /// the fine pass finds the frame, and the answer comes back in seconds.
    @Test func locateFindsTheOffsetToTheFrame() throws {
        let sound = room(from: 0, seconds: 14, seed: 1)
        let picture = room(from: 4.06, seconds: 8, gain: 0.35, noise: 0.05,
                           seed: 9)
        let fine = WaveformSync.fineWindow
        let found: WaveformSync.Alignment = try #require(
            WaveformSync.locate(picture: envelope(picture, window: fine),
                                sound: envelope(sound, window: fine)))
        // a frame at 25 fps is 40 ms and the fine window is 20
        #expect(abs(found.offsetIntoSound - 4.06) <= 0.04,
                Comment(rawValue: "the offset came out "
                    + "\(found.offsetIntoSound)s"))
        #expect(found.isCredible)
    }

    /// …and it refuses rather than guessing: the credibility it reports is the
    /// COARSE pass's, which is the one that looked everywhere.
    @Test func locateRefusesTwoUnrelatedRecordings() {
        let fine = WaveformSync.fineWindow
        let sound = room(from: 0, seconds: 14, seed: 11, room: 100)
        let picture = room(from: 0, seconds: 8, seed: 77, room: 7)
        #expect(WaveformSync.locate(
            picture: envelope(picture, window: fine),
            sound: envelope(sound, window: fine)) == nil)
    }

    /// The builder carries a window across buffer boundaries — a file arrives
    /// in whatever chunks the decoder feels like, and an envelope that reset
    /// at every chunk would be an envelope of the chunking.
    @Test func theBuilderCarriesAWindowAcrossBuffers() {
        let samples = room(from: 0, seconds: 2)
        let whole = WaveformSync.envelope(samples, channels: 2,
                                          sampleRate: rate, window: 0.2)
        var builder = WaveformSync.EnvelopeBuilder(channels: 2,
                                                   sampleRate: rate,
                                                   window: 0.2)
        // chunks that do not divide the window at all
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + 7_777)
            builder.add(Array(samples[index..<end]))
            index = end
        }
        #expect(builder.values.count == whole.count)
        for (a, b) in zip(builder.values, whole) {
            #expect(abs(a - b) < 1e-9, "\(a) against \(b)")
        }
    }

    /// Averaging RMS values would be averaging square roots, which is not the
    /// RMS of the group — the difference is systematic on transients, and a
    /// search is exactly where a transient matters.
    @Test func coarseningAveragesEnergyAndNotAmplitude() {
        let fine: [Double] = [0, 0, 0, 4]
        let coarse = WaveformSync.coarsened(fine, by: 4)
        #expect(coarse.count == 1)
        // energy mean: sqrt(16/4) = 2, not the amplitude mean of 1
        #expect(abs(coarse[0] - 2) < 1e-9, "\(coarse[0])")
        #expect(WaveformSync.coarsened(fine, by: 1) == fine)
        // a tail too short to fill a group is dropped rather than half-counted
        #expect(WaveformSync.coarsened([1, 1, 1], by: 2).count == 1)
    }

    // MARK: - sparse material, which is what the guards are for

    /// **The shape that produced a confident wrong answer.** Two unrelated
    /// recordings of a quiet room with a few thumps in it: before the coverage
    /// floor and the standard-deviation measure this came back at peak 0.9999
    /// with an infinite prominence, because at the very edge of the search a
    /// single thump matches a single thump and the mean of a correlation curve
    /// is near zero by construction.
    @Test func twoSparseRecordingsDoNotMatchEachOther() throws {
        let sound = room(from: 0, seconds: 14, seed: 11,
                         events: [1, 3, 5.5, 8])
        let picture = room(from: 0, seconds: 8, seed: 77,
                           events: [0.4, 2.2, 4.9, 6.6])
        let found: WaveformSync.Alignment = try #require(
            WaveformSync.align(picture: envelope(picture),
                               sound: envelope(sound)))
        #expect(!found.isCredible,
                Comment(rawValue: "peak \(found.peak), "
                    + "prominence \(found.prominence)"))
    }

    /// …and the same sparse room really does line up when it IS the same room,
    /// so the guards are a threshold rather than a refusal to work on sparse
    /// sound.
    @Test func theSameSparseRoomStillLinesUp() throws {
        let events: [Double] = [1, 2.5, 5, 6.2, 9, 11.5, 12.8]
        let sound = room(from: 0, seconds: 14, seed: 1, events: events)
        let picture = room(from: 0, seconds: 11, gain: 0.4, noise: 0.03,
                           seed: 9, events: events.map { $0 - 3 })
        let found: WaveformSync.Alignment = try #require(
            WaveformSync.align(picture: envelope(picture),
                               sound: envelope(sound)))
        #expect(found.isCredible,
                Comment(rawValue: "peak \(found.peak), "
                    + "prominence \(found.prominence)"))
        #expect(abs(found.offsetIntoSound - 15) <= 1,
                Comment(rawValue: "the lag came out \(found.offsetIntoSound)"))
    }

    /// **The peak is taken OUT before the spread is measured.** With it left
    /// in it inflates the very deviation it is being compared against, which
    /// is how a sharp answer talks itself down — pinned directly, because on
    /// good material the difference is a fraction no end-to-end case can be
    /// made to depend on without being fragile.
    @Test func theSpreadIsMeasuredWithoutThePeakInIt() {
        // a flat field with one spike in it
        var curve: [(lag: Int, r: Double)] = (0..<40).map { ($0, 0.1) }
        curve[20] = (20, 0.9)
        let without = WaveformSync.prominence(of: 0.9, in: curve)
        // …and what the same curve says with the spike left in the spread
        let rest: [Double] = curve.map(\.r)
        let mean: Double = rest.reduce(0, +) / Double(rest.count)
        let variance: Double = rest.reduce(0) {
            $0 + ($1 - mean) * ($1 - mean)
        } / Double(rest.count)
        let with: Double = (0.9 - mean) / variance.squareRoot()
        #expect(without > with * 3,
                Comment(rawValue: "\(without) against \(with)"))
        // a curve with no spread at all is not prominent at any height
        #expect(WaveformSync.prominence(
            of: 1, in: (0..<10).map { ($0, 0.5) }) == 0)
    }

}
