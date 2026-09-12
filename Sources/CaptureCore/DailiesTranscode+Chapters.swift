@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

/// **The proxy's chapter track** (owner: "ого я не знал что так можно, конечно
/// давай прокинем").
///
/// Beside `+Timecode` because it is the same shape and the same trap: an
/// `AVAssetWriter` that is not real time holds every input back until the
/// laggard catches up, and an input with NO samples lags for ever. Both tracks
/// are therefore written at the FIRST frame and closed on the spot — there is
/// nothing either of them is waiting to learn.
extension DailiesTranscode {
    /// Every marker as a chapter, each running to the next.
    ///
    /// The last chapter runs to the END of the picture, which comes from the
    /// PROBE (`framesTotal` at the source's rate) rather than from the last
    /// frame appended — at the first frame nobody knows the last one yet, and
    /// `+Timecode` takes the same reading for the same reason. Where the probe
    /// and the file disagree the final chapter is short by the difference,
    /// which is a chapter that ends early rather than a queue that stops.
    ///
    /// A marker at or past that end is DROPPED. It would be a chapter of no
    /// length, and a zero-length chapter is an entry a player either ignores
    /// or renders on top of its neighbour. A marker dropped on the very last
    /// frame of a take is the one case, and the frame either side of it is on
    /// the same moment.
    ///
    /// The TITLE is the marker's note, and its timecode when it has no note —
    /// which is what the shift report's marker line does with the same pair,
    /// so a chapter and a printed row read the same for one flag.
    func writeChapters(_ session: DailiesSession, from first: CMTime) {
        guard let leg = session.chapters else { return }
        chaptersWritten = true
        defer { leg.input.markAsFinished() }
        let end = CMTimeAdd(first, CMTimeMultiply(
            frameDuration, multiplier: Int32(max(1, framesTotal))))
        for (index, marker) in leg.markers.enumerated() {
            let from = CMTimeMaximum(first, CMTimeAdd(
                first, CMTime(seconds: marker.seconds, preferredTimescale: 600)))
            let until = index + 1 < leg.markers.count
                ? CMTimeMinimum(end, CMTimeAdd(
                    first, CMTime(seconds: leg.markers[index + 1].seconds,
                                  preferredTimescale: 600)))
                : end
            guard until > from, leg.input.isReadyForMoreMediaData,
                  let sample = ChapterTrack.sample(
                    title: title(of: marker),
                    formatDescription: leg.formatDescription,
                    from: from, until: until) else { continue }
            _ = leg.input.append(sample)
        }
    }

    /// What one chapter is called.
    private func title(of marker: TakeMarker) -> String {
        let note = marker.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? marker.timecodeText : note
    }
}
