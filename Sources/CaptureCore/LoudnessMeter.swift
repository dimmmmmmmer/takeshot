import Foundation

/// **How loud a take actually is**, to ITU-R BS.1770 / EBU R128 — the
/// measurement a review copy's level is set from.
///
/// # Why loudness and not a peak
///
/// A peak is set by a door slam and says nothing about dialogue. Two takes
/// with identical peaks can be six decibels apart to listen to, which is the
/// whole reason broadcast stopped normalising to peaks in 2010. What a
/// director watching rushes on a laptop needs is for every take to be as loud
/// as the last one, and that is a loudness.
///
/// # The measurement, in the order it happens
///
/// 1. **K-weighting**: two biquads in series per channel — a high shelf that
///    approximates the head's acoustic effect, then a high-pass that takes the
///    rumble out. The coefficients are DERIVED from the standard's analog
///    prototype rather than transcribed, so any sample rate is measurable;
///    `theDerivedCoefficientsMatchTheStandardsOwnTable` holds the derivation
///    to the published 48 kHz table, which is what makes deriving them safe.
/// 2. **400 ms blocks, overlapping by 75 %** — a step of 100 ms. The overlap
///    is not a refinement: without it a loud moment that straddles a boundary
///    is split between two quieter blocks and gated out of both.
/// 3. **Two gates.** An absolute one at −70 LUFS drops silence, and then a
///    relative one at 10 LU below the ungated mean drops the quiet parts —
///    which is what stops a take with thirty seconds of room tone before the
///    slate from measuring as a whisper and being turned up until the dialogue
///    distorts.
///
/// # What it is not
///
/// The peak it reports beside the loudness is a SAMPLE peak, not a true peak:
/// a true-peak meter oversamples by four to find what the reconstruction
/// filter will do between samples, and that is a different measurement with a
/// different cost. It is used here as a ceiling on the gain rather than as a
/// number anybody reads, and a sample peak is conservative in the direction
/// that matters — see `AudioGain`.
public struct LoudnessMeter {
    /// The standard's own offset, from the definition of LKFS.
    public static let offset = -0.691
    /// Blocks quieter than this are silence.
    public static let absoluteGate = -70.0
    /// …and then anything more than this far below the ungated mean.
    public static let relativeGate = -10.0
    /// One block, in seconds, and the step between blocks.
    public static let blockSeconds = 0.4
    public static let stepSeconds = 0.1

    private let channels: Int
    private let blockFrames: Int
    private let stepFrames: Int
    /// Two biquads per channel, in series.
    private var shelf: [Biquad]
    private var highpass: [Biquad]
    /// Mean-square accumulator for the block in flight, per channel, kept as a
    /// ring so the 75 % overlap costs one pass over the samples rather than
    /// four.
    private var window: [[Double]]
    private var windowFilled = 0
    private var cursor = 0
    private var frames = 0
    /// Every block's mean square, summed over the weighted channels.
    private var blocks: [Double] = []
    private var peakValue = 0.0

    public init(sampleRate: Double, channels: Int) {
        self.channels = max(1, channels)
        blockFrames = max(1, Int((Self.blockSeconds * sampleRate).rounded()))
        stepFrames = max(1, Int((Self.stepSeconds * sampleRate).rounded()))
        shelf = (0..<self.channels).map { _ in Biquad(.shelf(sampleRate)) }
        highpass = (0..<self.channels).map { _ in Biquad(.highpass(sampleRate)) }
        window = Array(repeating: Array(repeating: 0, count: blockFrames),
                       count: self.channels)
    }

    /// Interleaved 16-bit samples, as the dailies reader decodes them.
    public mutating func add(_ samples: [Int16]) {
        add(samples.map { Double($0) / 32_768 })
    }

    /// Interleaved samples in −1…1.
    public mutating func add(_ samples: [Double]) {
        var index = 0
        while index + channels <= samples.count {
            for channel in 0..<channels {
                let raw = samples[index + channel]
                peakValue = max(peakValue, abs(raw))
                let weighted = highpass[channel].run(shelf[channel].run(raw))
                window[channel][cursor] = weighted * weighted
            }
            cursor = (cursor + 1) % blockFrames
            windowFilled = min(blockFrames, windowFilled + 1)
            frames += 1
            if windowFilled == blockFrames, frames % stepFrames == 0 {
                closeBlock()
            }
            index += channels
        }
    }

    /// The gated loudness in LUFS, or nil when nothing cleared the gates —
    /// which is silence, and a gain computed from silence is a number nobody
    /// measured.
    public var loudness: Double? {
        let loud = blocks.filter {
            Self.offset + 10 * log10($0) > Self.absoluteGate
        }
        // **The absolute gate is the one that can empty the set.** Nothing
        // above −70 LUFS is a dead channel or a mute left on, and there is no
        // programme to report. The relative gate below cannot empty it in
        // turn — its threshold is ten decibels under the ENERGY mean, and
        // some block is always at least at that mean — so the second nil here
        // is unreachable by argument and is kept as the shape of the helper
        // rather than as a case anybody can produce.
        guard let ungated = Self.mean(of: loud) else { return nil }
        let threshold = Self.offset + 10 * log10(ungated) + Self.relativeGate
        guard let mean = Self.mean(of: loud.filter {
            Self.offset + 10 * log10($0) > threshold
        }) else { return nil }
        return Self.offset + 10 * log10(mean)
    }

    /// The mean of some block energies, or nil when there are none — and nil
    /// rather than a 0/0 that turns into a NaN threshold three lines later.
    private static func mean(of blocks: [Double]) -> Double? {
        guard !blocks.isEmpty else { return nil }
        let mean = blocks.reduce(0, +) / Double(blocks.count)
        return mean > 0 ? mean : nil
    }

    /// The largest absolute sample seen, 0…1.
    public var peak: Double { peakValue }

    /// The block in flight, weighted and summed across channels.
    ///
    /// Stereo weights are 1.0 and so is centre; only the surround channels
    /// carry 1.41, and a daily is a stereo downmix by the time it reaches
    /// here. Stated rather than implied: a weight of 1 is a decision.
    private mutating func closeBlock() {
        var sum = 0.0
        for channel in 0..<channels {
            let mean = window[channel].reduce(0, +) / Double(blockFrames)
            sum += mean
        }
        guard sum > 0 else { return }
        blocks.append(sum)
    }
}

/// One direct-form-I biquad, which is all a K-weighting filter is.
struct Biquad {
    /// The two filters of the K-weighting, as the standard's analog
    /// prototypes. Deriving them per sample rate rather than transcribing the
    /// 48 kHz table is what lets a 44.1 kHz source be measured at all.
    enum Kind {
        case shelf(Double)
        case highpass(Double)
    }

    let b0, b1, b2, a1, a2: Double
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(_ kind: Kind) {
        switch kind {
        case .shelf(let rate):
            // The standard's stage 1: a high shelf, +4 dB, at 1681.97 Hz.
            let f0 = 1681.974450955533
            let gain = 3.999843853973347
            let q = 0.7071752369554196
            let k = tan(.pi * f0 / max(1, rate))
            let vh = pow(10, gain / 20)
            let vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            b0 = (vh + vb * k / q + k * k) / a0
            b1 = 2 * (k * k - vh) / a0
            b2 = (vh - vb * k / q + k * k) / a0
            a1 = 2 * (k * k - 1) / a0
            a2 = (1 - k / q + k * k) / a0
        case .highpass(let rate):
            // Stage 2: the RLB high-pass at 38.14 Hz.
            let f0 = 38.13547087602444
            let q = 0.5003270373238773
            let k = tan(.pi * f0 / max(1, rate))
            b0 = 1
            b1 = -2
            b2 = 1
            a1 = 2 * (k * k - 1) / (1 + k / q + k * k)
            a2 = (1 - k / q + k * k) / (1 + k / q + k * k)
        }
    }

    mutating func run(_ x0: Double) -> Double {
        let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x0
        y2 = y1
        y1 = y0
        return y0
    }
}
