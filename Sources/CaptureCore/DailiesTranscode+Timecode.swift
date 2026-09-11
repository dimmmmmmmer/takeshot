@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

/// **The proxy's timecode track.**
///
/// Split out of the transcode when that type reached its length ceiling, and a
/// coherent piece rather than an arbitrary cut: everything here is the one
/// question of where the source's timecode lands on the daily's timeline. The
/// tc32 bytes themselves are `TimecodeTrack`'s, shared with the take writer,
/// because a file whose timecode reads plausibly and lines up with nothing is
/// the failure both of them have to avoid in the same way.
extension DailiesTranscode {
    /// **The source's timecode, carried into the proxy** (owner: "таймкод
    /// дорожку в прокси"): one tc32 sample per anchor, the last running to the
    /// end of the picture.
    ///
    /// **Written at the FIRST frame and closed on the spot**, which is the
    /// third time this file has been taught the same lesson. An
    /// `AVAssetWriter` that is not real time holds every input back until the
    /// laggard catches up, and an input with NO samples at all lags for ever:
    /// with the samples written in `finish()` the run never reached `finish()`
    /// — measured, as a test process that sat at 100 % with no output until it
    /// was killed. The audio legs mark themselves finished the moment they run
    /// dry for the same reason; this one has nothing to wait for, so it is
    /// written and closed in one go.
    ///
    /// The end therefore comes from the PROBE (`framesTotal` at the source's
    /// rate) rather than from the last frame appended, because nobody knows
    /// the last frame yet. The two agree for any file whose duration its own
    /// container states; where they differ the track is short by the
    /// difference, which is a timecode that stops a frame early rather than a
    /// queue that stops entirely.
    ///
    /// A span the writer will not take is DROPPED rather than waited on: the
    /// picture and the sound are what a daily is for, and this is a track the
    /// same run can be asked for again.
    func writeTimecode(_ session: DailiesSession, from first: CMTime) {
        guard let leg = session.timecode else { return }
        timecodeWritten = true
        defer { leg.input.markAsFinished() }
        let end = CMTimeAdd(first, CMTimeMultiply(frameDuration,
                                                  multiplier: Int32(max(1, framesTotal))))
        for (index, anchor) in leg.anchors.enumerated() {
            // The first span starts where the PICTURE starts, whatever the
            // anchor says: an anchor a hair into the clip would leave the
            // frames before it with no timecode at all.
            let from = index == 0
                ? first
                : CMTimeMaximum(first, CMTime(seconds: anchor.seconds,
                                              preferredTimescale: 600))
            let until = index + 1 < leg.anchors.count
                ? CMTimeMinimum(end, CMTime(seconds: leg.anchors[index + 1].seconds,
                                            preferredTimescale: 600))
                : end
            guard until > from, leg.input.isReadyForMoreMediaData,
                  let sample = TimecodeTrack.sample(
                    timecode: anchor.timecode,
                    formatDescription: leg.formatDescription,
                    from: from, until: until) else { continue }
            _ = leg.input.append(sample)
        }
    }
}
