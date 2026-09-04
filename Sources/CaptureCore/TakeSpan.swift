import Foundation

/// Where a take starts and where it ends, on its own timebase.
///
/// # Why this is one place and was four spellings
///
/// "Start TC advanced by the recorded frames" is the only question the OUT
/// point of a take ever asks, and four surfaces asked it separately:
///
/// | asked by | rate used | no start TC |
/// | --- | --- | --- |
/// | `TakeLogExporter.endTimecode` — the shift report PDF and its CSV | real | nil |
/// | `ALEExporter.span` — the Avid log's Start/End columns | real | zero-based |
/// | `EDLExporter.eventLines` — the conform's SOURCE side | real | zero-based |
/// | the takes panel's row, under the file name | **nominal** | zero-based at 25 |
///
/// **The fourth had already drifted, and drop-frame is where it shows.** The
/// panel multiplied `durationSeconds` by the timecode's NOMINAL fps, so a
/// 29.97 DF take was counted at 30 real frames a second and a 59.94 one at 60.
/// Measured, from a start of `10:00:00;00`:
///
/// | rate | take | the panel | every export | apart by |
/// | --- | --- | --- | --- | --- |
/// | 29.97 DF | 10 min | `10:10:00;18` | `10:10:00;00` | 18 frames |
/// | 29.97 DF | 1 min | `10:01:00;02` | `10:00:59;28` | 2 frames |
/// | 59.94 DF | 10 min | `10:10:00;36` | `10:10:00;00` | 36 frames |
/// | 25 / 24 / 30 ND | any | — | — | **0** |
///
/// One frame per thousand, always in the same direction: the panel's OUT point
/// runs AHEAD of the paperwork's. That is the number an operator reads back to
/// the script supervisor over talkback while the office is reading the shift
/// report, and it is the number an assistant matches against the Avid log when
/// a clip will not line up. Nothing about it looks wrong on its own — it is a
/// plausible timecode, a fraction of a second out, on the one rate family
/// (29.97/59.94, i.e. every US broadcast job) where a nominal rate and a real
/// one are different numbers.
///
/// The doc comment on the panel's copy said "at the TC's own fps", which is
/// what this type does and what that code did not.
///
/// # Why the rate is real and not nominal
///
/// `Timecode.frameNumber` is documented as "the real frame ordinal since
/// midnight … two consecutive recorded frames always differ by exactly 1",
/// drop-frame numbering already removed. So the thing being ADDED to it has to
/// be a count of real frames, and a drop-frame camera delivers
/// `fps * 1000/1001` of them a second — which is what
/// `TakeLogExporter.realRate(of:)` says and what `frameOffset(seconds:at:)`
/// counts with. Multiplying by the nominal fps counts frames that were never
/// shot.
public struct TakeSpan: Equatable, Sendable {
    /// The take's first frame.
    public let start: Timecode
    /// The take's last frame plus one — start advanced by `frames`.
    public let end: Timecode
    /// The recorded length in real frames on `start`'s timebase.
    public let frames: Int
    /// True when the take carried NO start timecode and `start` is the
    /// zero-based fallback rather than something a camera sent.
    ///
    /// Carried rather than decided here, because the three consumers want
    /// three different things from it and each of them is right: the shift
    /// report prints an em dash (a blank cell is a clip with no position at
    /// all), the ALE and the EDL write the zero-based span (the length at
    /// least survives the import), and the takes panel shows no range at all
    /// (the row already has the length beside it).
    public let isZeroBased: Bool

    /// The span of `take`, on the take's own timebase.
    public static func of(_ take: Take) -> TakeSpan {
        let start = take.startTimecode ?? TakeLogExporter.fallbackRate
        // On the take's OWN rate: a 23.976 source numbered at 24 was counted
        // at 24 here, so every OUT point ran ahead by a frame every 41 s.
        let frames = TakeLogExporter.frameOffset(seconds: take.durationSeconds,
                                                 for: take)
        return TakeSpan(
            start: start,
            end: Timecode(frameNumber: start.frameNumber + frames,
                          fps: start.fps, isDropFrame: start.isDropFrame),
            frames: frames,
            isZeroBased: take.startTimecode == nil)
    }
}
