import Foundation
import Testing

@testable import CaptureCore

/// **The loudness a review copy's level is set from** (ITU-R BS.1770 / EBU
/// R128).
///
/// The one thing that cannot be checked by reasoning is the filter: its
/// coefficients are derived here rather than transcribed, so the derivation is
/// held against the standard's own published 48 kHz table. Everything after
/// that is arithmetic with a definition, and the definition is what these pin.
@Suite struct LoudnessMeterTests {
    /// Interleaved stereo sine, `seconds` long at `rate`.
    private func sine(amplitude: Double, hertz: Double = 997,
                      seconds: Double = 3, rate: Double = 48_000,
                      channels: Int = 2) -> [Double] {
        let frames = Int(seconds * rate)
        var out: [Double] = []
        out.reserveCapacity(frames * channels)
        for frame in 0..<frames {
            let value = amplitude
                * sin(2 * .pi * hertz * Double(frame) / rate)
            for _ in 0..<channels { out.append(value) }
        }
        return out
    }

    private func measure(_ samples: [Double], rate: Double = 48_000,
                         channels: Int = 2) -> Double? {
        var meter = LoudnessMeter(sampleRate: rate, channels: channels)
        meter.add(samples)
        return meter.loudness
    }

    // MARK: - the filter

    /// **The derivation, against the standard's own table.** BS.1770-4 prints
    /// the K-weighting coefficients at 48 kHz; everything else here derives
    /// them from the analog prototype so that a 44.1 kHz file can be measured
    /// at all. If the two ever disagree, every number this app reports about
    /// loudness is wrong by an unknown amount — which is exactly the failure
    /// that cannot be noticed by listening.
    @Test func theDerivedCoefficientsMatchTheStandardsOwnTable() {
        let shelf = Biquad(.shelf(48_000))
        #expect(abs(shelf.b0 - 1.53512485958697) < 1e-9, "\(shelf.b0)")
        #expect(abs(shelf.b1 - -2.69169618940638) < 1e-9, "\(shelf.b1)")
        #expect(abs(shelf.b2 - 1.19839281085285) < 1e-9, "\(shelf.b2)")
        #expect(abs(shelf.a1 - -1.69065929318241) < 1e-9, "\(shelf.a1)")
        #expect(abs(shelf.a2 - 0.73248077421585) < 1e-9, "\(shelf.a2)")

        let highpass = Biquad(.highpass(48_000))
        #expect(highpass.b0 == 1)
        #expect(highpass.b1 == -2)
        #expect(highpass.b2 == 1)
        #expect(abs(highpass.a1 - -1.99004745483398) < 1e-9, "\(highpass.a1)")
        #expect(abs(highpass.a2 - 0.99007225036621) < 1e-9, "\(highpass.a2)")
    }

    /// …and the derivation moves with the rate, which is the whole reason it
    /// is a derivation: a 44.1 kHz file is a real source.
    @Test func anotherSampleRateGetsItsOwnCoefficients() {
        #expect(Biquad(.shelf(44_100)).b0 != Biquad(.shelf(48_000)).b0)
        #expect(Biquad(.highpass(44_100)).a1 != Biquad(.highpass(48_000)).a1)
    }

    // MARK: - the measurement

    /// A decibel is a decibel: six more in, six more out, wherever the signal
    /// started. This is the property everything downstream depends on — the
    /// gain is a DIFFERENCE from a target.
    @Test func aLouderSignalMeasuresLouderByTheSameAmount() throws {
        let quiet = try #require(measure(sine(amplitude: 0.05)))
        let loud = try #require(measure(sine(amplitude: 0.1)))
        let louder = try #require(measure(sine(amplitude: 0.2)))
        #expect(abs((loud - quiet) - 6.0206) < 0.05, "\(loud - quiet)")
        #expect(abs((louder - loud) - 6.0206) < 0.05, "\(louder - loud)")
    }

    /// Two channels of the same signal are twice the energy — 3 dB — which is
    /// the channel sum the standard defines, not an average.
    @Test func theChannelsAreSummedAndNotAveraged() throws {
        let mono = try #require(measure(sine(amplitude: 0.1, channels: 1),
                                        channels: 1))
        let stereo = try #require(measure(sine(amplitude: 0.1)))
        #expect(abs((stereo - mono) - 3.0103) < 0.05, "\(stereo - mono)")
    }

    /// The K-weighting is a FILTER: a rumble at 20 Hz carries as much energy
    /// as the voice and far less loudness, which is what the high-pass is for.
    /// Without it a take recorded next to a generator would be turned down
    /// until the dialogue vanished.
    ///
    /// **14 dB and not more**, and that is the filter rather than a weak test:
    /// the RLB stage is one second-order high-pass at 38 Hz, so an octave
    /// below its corner is about 12 dB down and the shelf adds a little. A
    /// bigger number here would mean a filter this app invented.
    @Test func lowRumbleIsWeightedOutOfTheMeasurement() throws {
        let rumble = try #require(measure(sine(amplitude: 0.5, hertz: 20)))
        let voice = try #require(measure(sine(amplitude: 0.5, hertz: 997)))
        #expect(voice - rumble > 12,
                "the rumble measured \(rumble) against \(voice)")
        #expect(abs((voice - rumble) - 14.0) < 1,
                "the weighting rejects \(voice - rumble) dB at 20 Hz")
    }

    /// **Silence is not a loudness.** A gain computed from a file with nothing
    /// in it is a number nobody measured, and the answer has to be nil rather
    /// than a very small one.
    @Test func silenceHasNoLoudnessAtAll() {
        #expect(measure([Double](repeating: 0, count: 48_000 * 2)) == nil)
        #expect(LoudnessMeter(sampleRate: 48_000, channels: 2).loudness == nil)
    }

    /// A clip too short to fill one 400 ms block is not measurable either —
    /// and says so rather than reporting whatever fraction it saw.
    @Test func aClipShorterThanOneBlockIsNotMeasurable() {
        #expect(measure(sine(amplitude: 0.5, seconds: 0.2)) == nil)
    }

    /// **The relative gate is what the standard is for.** Thirty seconds of
    /// room tone before the slate must not drag the measurement down until the
    /// dialogue is turned up into distortion: the quiet part is gated out, and
    /// the answer is the loud part's own loudness.
    @Test func theQuietPartIsGatedOutOfTheAnswer() throws {
        let tone = sine(amplitude: 0.001, seconds: 8)
        let speech = sine(amplitude: 0.2, seconds: 4)
        let mixed = try #require(measure(tone + speech))
        let alone = try #require(measure(speech))
        #expect(abs(mixed - alone) < 1.5,
                "the room tone pulled \(alone) down to \(mixed)")
    }

    /// …and digital silence never reaches a gate at all: a block with no
    /// energy in it is not a block. Worth its own case because it is the
    /// ordinary shape of a take — the head and the tail of every recording
    /// are exactly this.
    @Test func digitalSilenceIsDroppedBeforeItIsEvenABlock() throws {
        let silence = [Double](repeating: 0, count: 48_000 * 2 * 8)
        let speech = sine(amplitude: 0.2, seconds: 4)
        let padded = try #require(measure(silence + speech))
        let alone = try #require(measure(speech))
        #expect(abs(padded - alone) < 1.5, "\(padded) against \(alone)")
    }

    /// **A file too quiet to be anything is not measurable**, and that is what
    /// the ABSOLUTE gate is for — the relative one cannot help here, because
    /// with nothing loud in the file it would set its threshold from the
    /// quiet and report it as the programme. A take like this is a dead
    /// channel or a mute left on, and a gain computed from it would bring
    /// twelve decibels of nothing up to listen to.
    @Test func aFileTooQuietToBeAnythingIsNotMeasurable() {
        // about −80 LUFS: real samples, ten decibels under the gate
        #expect(measure(sine(amplitude: 0.0001, seconds: 6)) == nil)
        // …and one just above it IS measured, so the gate is a threshold and
        // not a refusal to look at quiet material
        let quiet = measure(sine(amplitude: 0.002, seconds: 6))
        #expect(quiet != nil)
        #expect(abs((quiet ?? 0) - -54) < 2, "\(quiet ?? 0)")
    }

    /// The peak is reported beside the loudness because the gain needs a
    /// ceiling: it is the largest sample seen, whatever the weighting did.
    @Test func thePeakIsTheLargestSampleAndNotTheWeightedOne() {
        var meter = LoudnessMeter(sampleRate: 48_000, channels: 2)
        meter.add(sine(amplitude: 0.75, hertz: 20, seconds: 1))
        #expect(abs(meter.peak - 0.75) < 0.01, "\(meter.peak)")
    }

    /// Int16 is what the dailies reader decodes into, and full scale there is
    /// 32 768 — a scale that is one out reports every take a hair loud.
    @Test func sixteenBitSamplesAreOnTheSameScale() throws {
        var meter = LoudnessMeter(sampleRate: 48_000, channels: 2)
        let frames = 48_000 * 3
        var samples: [Int16] = []
        for frame in 0..<frames {
            let value = Int16((0.1 * 32_768
                * sin(2 * .pi * 997 * Double(frame) / 48_000)).rounded())
            samples.append(value)
            samples.append(value)
        }
        meter.add(samples)
        let integer = try #require(meter.loudness)
        let float = try #require(measure(sine(amplitude: 0.1)))
        #expect(abs(integer - float) < 0.1, "\(integer) against \(float)")
    }
}
