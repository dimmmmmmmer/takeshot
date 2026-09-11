import Foundation

/// **Which of the recordist's files belong to a take**, decided on timecode
/// alone.
///
/// Owner: "если у звука и тейков одинаковые таймкоды, чтоб он автоматически
/// подружил нужные тейки". "Одинаковые таймкоды" is the everyday way to say it
/// and it is not what the rule can be: a recordist rolls before the camera and
/// stops after it, routinely by seconds, and on many units the sound runs
/// CONTINUOUSLY across a whole setup. Equal start timecodes would match almost
/// nothing on a real day.
///
/// So the rule is OVERLAP, and the answer is a set in both directions: one
/// sound file legitimately belongs to several takes (a running safety), and one
/// take is legitimately covered by several files (a per-take file plus that
/// safety).
public enum SoundSync {
    /// One file that belongs to a take, and where the take starts inside it.
    public struct Match: Sendable, Equatable {
        public var sound: BroadcastWaveFacts
        /// Seconds into the SOUND file at the picture's first frame.
        ///
        /// Negative — the sound starts after the picture, and the head of the
        /// take has no sound to put under it.
        public var offsetIntoSound: Double

        public init(sound: BroadcastWaveFacts, offsetIntoSound: Double) {
            self.sound = sound
            self.offsetIntoSound = offsetIntoSound
        }
    }

    /// How much the two have to share before the file counts as this take's.
    ///
    /// A second, because the thing being excluded is the file that merely
    /// TOUCHES the take — a recordist who stopped as the camera rolled, or the
    /// next slate's file starting on the tail. Anything with a second of
    /// picture under it is sound somebody recorded for this shot.
    public static let minimumOverlap: Double = 1

    /// Half a day, which is the only sensible place to fold the clock.
    ///
    /// The wrap is the same one the marker exporter already solved for the
    /// same reason (`TakeLogExporter+MarkerTime`): a take that rolled through
    /// midnight ends on a SMALLER timecode than it started on, and a sound
    /// file recorded a minute later reads as twenty-three hours earlier.
    static let halfDay: Double = 12 * 3600

    /// The files that belong to a take.
    ///
    /// Both sides are seconds since midnight and neither involves a frame
    /// rate: the picture's start comes from its timecode at its own REAL rate,
    /// and the sound's from `bext` TimeReference over the sample rate, which is
    /// exact. A file with no `bext` carries no start and matches nothing —
    /// never midnight.
    public static func matches(pictureStart: Double, pictureDuration: Double,
                               in sounds: [BroadcastWaveFacts],
                               minimumOverlap: Double = minimumOverlap)
        -> [Match] {
        let pictureEnd = pictureStart + max(0, pictureDuration)
        return sounds.compactMap { sound -> Match? in
            guard let rawStart = sound.startSecondsSinceMidnight else {
                return nil
            }
            let start = wrapped(rawStart, near: pictureStart)
            let end = start + sound.duration
            let shared = min(pictureEnd, end) - max(pictureStart, start)
            guard shared >= minimumOverlap else { return nil }
            // The offset is EXACT and gets no tolerance of its own. The
            // overlap decides whether a file counts; where it lands is
            // arithmetic on two jam-synced clocks, and a fudge factor applied
            // to correct data is a fudge factor in the daily.
            return Match(sound: sound, offsetIntoSound: pictureStart - start)
        }
    }

    /// A sound start folded onto the picture's side of midnight.
    static func wrapped(_ start: Double, near pictureStart: Double) -> Double {
        if start - pictureStart > halfDay { return start - 2 * halfDay }
        if start - pictureStart < -halfDay { return start + 2 * halfDay }
        return start
    }
}
