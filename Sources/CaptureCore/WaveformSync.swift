import Foundation

/// **Lining sound up with picture by listening to both** (owner: "ну и если
/// ВДРУГ есть возможность – синк дублей не только по таймкоду со звуком но еще
/// и по вейвформе").
///
/// Timecode is the right answer when there is one: it is exact, it costs
/// nothing to read, and `SoundSync` uses it. But a recorder without timecode
/// writes a file with no `bext` at all, and `BroadcastWaveFacts` says plainly
/// that such a file "cannot be matched to anything". This is what it can be
/// matched by instead — the camera's own scratch track and the recordist's
/// file are two recordings of one room, and the loud moments in them line up.
///
/// # What is correlated, and why not the samples
///
/// Not the waveforms: two microphones metres apart, at different gains, on
/// different preamps, are not the same signal sample for sample — their
/// phase relationship changes across the room and across the spectrum. What
/// IS the same is the SHAPE of the loudness over time: a door slam is a door
/// slam on both. So both sides become an envelope of RMS per short window,
/// and the envelopes are correlated.
///
/// # Coarse first, then fine
///
/// A minute of take inside a nine-minute roll is twenty-four thousand possible
/// lags at 20 ms, and each costs a pass over three thousand windows — seventy
/// million operations for ONE pair, and a day is hundreds of pairs. At 200 ms
/// the same search is a hundredth of that, and it lands within one coarse
/// window of the answer; the fine pass then searches only that neighbourhood.
/// The two are the same function with different inputs.
///
/// # It answers with a confidence, and the confidence is the point
///
/// A correlation always has a maximum. What says the maximum MEANS anything is
/// that it stands above the rest of the curve: two recordings of one moment
/// peak sharply, and a take correlated against the wrong roll produces a flat
/// field of noise with a meaningless winner in it. So the answer carries the
/// peak and how far it stands out, and the caller refuses anything that does
/// not clear both — a sound file attached to the wrong take is worse than one
/// attached to nothing.
public enum WaveformSync {
    /// The coarse search window, in seconds.
    public static let coarseWindow = 0.2
    /// …and the fine one, which is about a frame.
    public static let fineWindow = 0.02

    /// How high the best correlation has to be to be believed at all.
    ///
    /// **Measured on both sides** (`WaveformSyncTests`, two mics on one room
    /// at a third of the gain with their own noise, against two unrelated
    /// rooms): the true pair comes out at peak 0.999 / prominence 5.8, and the
    /// unrelated pair at 0.449 / 2.57. Both thresholds sit between the two
    /// with room on either side, which is what makes them thresholds rather
    /// than the numbers that happened to work once.
    public static let minimumPeak = 0.5
    /// …and how far above the REST of the curve it has to stand, in standard
    /// deviations.
    ///
    /// Both halves are needed and the second is the one that does the work. A
    /// correlation always has a maximum; what says it means anything is that
    /// the curve has a spike in it rather than a winner in a field of noise.
    ///
    /// **A ratio to the mean was tried first and is wrong**, which the suite
    /// caught: the mean of a correlation curve is near zero by construction,
    /// so the ratio explodes and calls everything prominent. A distance in
    /// standard deviations is the measure that behaves — four of them is a
    /// peak that is not going to happen by accident over a few hundred lags.
    public static let minimumProminence = 4.0
    /// How much of the picture a lag has to cover before it is even compared.
    ///
    /// Half, and this is the other half of the same lesson: on sparse material
    /// — a few thumps in a quiet room — two segments that each contain ONE
    /// event correlate at almost exactly 1, because a spike matches a spike.
    /// Those coincidences all live at the ENDS of the search, where a handful
    /// of windows overlap, and requiring most of the take to be covered
    /// removes them without touching any real answer: a sound file that covers
    /// less than half a take is not that take's sound.
    public static let minimumCoverage = 0.5

    /// **A sound file timecode cannot place, with the envelope that can.**
    ///
    /// Built once per run rather than once per take: a roll is read to make
    /// one of these, and a day has forty takes.
    public struct Candidate: Sendable {
        public var sound: BroadcastWaveFacts
        /// On the FINE grid; the coarse one is derived for the search.
        public var envelope: [Double]

        public init(sound: BroadcastWaveFacts, envelope: [Double]) {
            self.sound = sound
            self.envelope = envelope
        }
    }

    /// Where a sound file sits against a picture, and how sure that is.
    public struct Alignment: Sendable, Equatable {
        /// Seconds into the SOUND at the picture's first frame — the same
        /// quantity `SoundSync.Match.offsetIntoSound` carries, so the two
        /// kinds of match are interchangeable downstream.
        public var offsetIntoSound: Double
        /// The correlation at that lag, −1…1.
        public var peak: Double
        /// How far the peak stands above the rest of the curve.
        public var prominence: Double

        public init(offsetIntoSound: Double, peak: Double,
                    prominence: Double) {
            self.offsetIntoSound = offsetIntoSound
            self.peak = peak
            self.prominence = prominence
        }

        /// Whether this is an answer rather than the largest number in a field
        /// of noise.
        public var isCredible: Bool {
            peak >= minimumPeak && prominence >= minimumProminence
        }
    }

    /// **An envelope built as the samples arrive**, for a file nobody wants
    /// to hold in memory.
    ///
    /// A nine-minute stereo roll at 48 kHz is a hundred megabytes of Int16,
    /// and a run has several of them beside a transcode that is already using
    /// the machine. The builder keeps one window's worth.
    public struct EnvelopeBuilder {
        private let channels: Int
        private let size: Int
        private var sum = 0.0
        private var filled = 0
        /// Samples left over from a chunk that did not end on a frame
        /// boundary, carried into the next one.
        ///
        /// A decoder hands back whole frames and this should never hold
        /// anything — but dropping a stray sample does not lose a sample, it
        /// SHIFTS every channel after it by one for the rest of the file, and
        /// an envelope of a shifted interleave is an envelope of nothing. Five
        /// lines against a failure mode that would look like a bad match.
        private var pending: [Int16] = []
        private(set) public var values: [Double] = []

        public init(channels: Int, sampleRate: Double, window: Double) {
            self.channels = max(1, channels)
            size = max(1, Int((window * max(1, sampleRate)).rounded()))
        }

        /// One buffer of interleaved samples. Windows that straddle two
        /// buffers are carried across, which is the whole reason this is a
        /// type rather than a function called per buffer.
        public mutating func add(_ samples: [Int16]) {
            let all = pending.isEmpty ? samples : pending + samples
            var index = 0
            while index + channels <= all.count {
                for channel in 0..<channels {
                    let value = Double(all[index + channel])
                    sum += value * value
                }
                filled += 1
                index += channels
                if filled == size {
                    values.append((sum / Double(size * channels)).squareRoot())
                    sum = 0
                    filled = 0
                }
            }
            pending = index < all.count ? Array(all[index...]) : []
        }
    }

    /// A fine envelope averaged down to a coarser grid, in ENERGY.
    ///
    /// Averaging the RMS values themselves would be averaging square roots,
    /// which is not the RMS of the group — the difference is small on smooth
    /// material and systematic on transients, and a search is exactly where a
    /// transient matters.
    public static func coarsened(_ fine: [Double], by factor: Int) -> [Double] {
        guard factor > 1 else { return fine }
        var out: [Double] = []
        out.reserveCapacity(fine.count / factor)
        var index = 0
        while index + factor <= fine.count {
            var energy = 0.0
            for step in index..<(index + factor) {
                energy += fine[step] * fine[step]
            }
            out.append((energy / Double(factor)).squareRoot())
            index += factor
        }
        return out
    }

    /// **Where a sound file sits against a picture, in SECONDS** — the coarse
    /// search and the fine refinement, which is the pair this type exists to
    /// be.
    ///
    /// Both envelopes are on the FINE grid; the coarse ones are derived. The
    /// coarse pass lands within one of its own windows of the answer, so the
    /// fine pass searches exactly that neighbourhood and nothing else — the
    /// two together cost a hundredth of the fine search alone.
    ///
    /// The credibility reported is the COARSE pass's: it is the one that
    /// looked at every possible position and can therefore say whether the
    /// answer stands out. The fine pass is asked a different question — where
    /// exactly, within a fifth of a second — and its own prominence is about a
    /// neighbourhood rather than about the day.
    public static func locate(picture: [Double], sound: [Double],
                              window: Double = fineWindow) -> Alignment? {
        let factor = max(1, Int((coarseWindow / window).rounded()))
        guard let coarse = align(picture: coarsened(picture, by: factor),
                                 sound: coarsened(sound, by: factor)),
              coarse.isCredible else { return nil }
        let centre = Int(coarse.offsetIntoSound) * factor
        let refined = align(picture: picture, sound: sound,
                            lags: (centre - factor)...(centre + factor))
        let lag = refined.map { Int($0.offsetIntoSound) } ?? centre
        return Alignment(offsetIntoSound: Double(lag) * window,
                         peak: coarse.peak, prominence: coarse.prominence)
    }

    /// The RMS envelope of interleaved samples, one value per window.
    ///
    /// Channels are summed before the window is measured rather than after: a
    /// stereo pair of one room is one room, and averaging the two envelopes
    /// separately would halve a sound that appears in one channel only.
    public static func envelope(_ samples: [Int16], channels: Int,
                                sampleRate: Double,
                                window seconds: Double) -> [Double] {
        var builder = EnvelopeBuilder(channels: channels,
                                      sampleRate: sampleRate, window: seconds)
        builder.add(samples)
        return builder.values
    }

    /// The lag that lines `picture` up inside `sound`, in WINDOWS.
    ///
    /// Both are envelopes on the same window size. A positive lag means the
    /// picture starts that many windows into the sound, which is the ordinary
    /// case — a recordist rolls first.
    ///
    /// `lags` bounds the search; nil searches every position at which the
    /// shorter sits inside the longer. Pearson's r at each lag, over the
    /// overlapping part only, so a partial overlap is compared on what the two
    /// actually share.
    public static func align(picture: [Double], sound: [Double],
                             lags: ClosedRange<Int>? = nil) -> Alignment? {
        guard !picture.isEmpty, !sound.isEmpty else { return nil }
        let range = lags ?? (-(picture.count - 1))...(sound.count - 1)
        let covered = Int((Double(picture.count) * minimumCoverage).rounded())
        var curve: [(lag: Int, r: Double)] = []
        for lag in range {
            let overlap = min(sound.count, lag + picture.count) - max(0, lag)
            guard overlap >= covered,
                  let r = correlation(picture: picture, sound: sound, lag: lag)
            else { continue }
            curve.append((lag, r))
        }
        guard let best = curve.max(by: { $0.r < $1.r }), curve.count > 1 else {
            return nil
        }
        return Alignment(offsetIntoSound: Double(best.lag), peak: best.r,
                         prominence: prominence(of: best.r, in: curve))
    }

    /// How far the peak stands above the rest of the curve, in standard
    /// deviations of the rest.
    ///
    /// The peak is taken OUT before the spread is measured: with it left in it
    /// inflates the very deviation it is being compared against, which is how
    /// a sharp answer talks itself down. A curve with no spread at all — every
    /// lag identical, which is a flat envelope — is not prominent at any
    /// height.
    static func prominence(of peak: Double,
                           in curve: [(lag: Int, r: Double)]) -> Double {
        let rest = curve.map(\.r).filter { $0 < peak }
        guard rest.count > 1 else { return 0 }
        let mean = rest.reduce(0, +) / Double(rest.count)
        let variance = rest.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(rest.count)
        guard variance > 0 else { return 0 }
        return (peak - mean) / variance.squareRoot()
    }

    /// Pearson's r between the picture envelope and the part of the sound it
    /// overlaps at `lag`, or nil when they share too little to compare.
    ///
    /// A floor of eight windows, not one: two windows correlate perfectly with
    /// each other by arithmetic, and a match decided on a fifth of a second of
    /// shared material is a coincidence with a number attached.
    static func correlation(picture: [Double], sound: [Double],
                            lag: Int, minimumWindows: Int = 8) -> Double? {
        let start = max(0, lag)
        let end = min(sound.count, lag + picture.count)
        guard end - start >= minimumWindows else { return nil }
        var sumP = 0.0, sumS = 0.0
        for index in start..<end {
            sumP += picture[index - lag]
            sumS += sound[index]
        }
        let n = Double(end - start)
        let meanP = sumP / n
        let meanS = sumS / n
        var covariance = 0.0, varianceP = 0.0, varianceS = 0.0
        for index in start..<end {
            let p = picture[index - lag] - meanP
            let s = sound[index] - meanS
            covariance += p * s
            varianceP += p * p
            varianceS += s * s
        }
        // A flat envelope has no shape to match. Silence against silence is
        // not a match, however well the two agree.
        guard varianceP > 0, varianceS > 0 else { return nil }
        return covariance / (varianceP * varianceS).squareRoot()
    }
}
