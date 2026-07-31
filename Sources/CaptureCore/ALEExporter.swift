import Foundation

/// Avid Log Exchange (ALE) of the shift's takes — the log an Avid assistant
/// imports into a bin to relink and carry the on-set metadata across.
///
/// The file is three sections in a fixed order (`Heading`, `Column`, `Data`),
/// tab-delimited, each section separated from the next by a blank line. It sits
/// next to the CSV and the EDL rather than inside them because Media Composer
/// reads neither: the CSV is Resolve's metadata table and the EDL is a cut.
///
/// Where the wire format was pinned down, and the two judgement calls:
///
/// - **Line endings are CRLF.** ALE predates Unix line endings in post and the
///   Avid Log Exchange utility itself is a Windows tool. Every reader checked
///   (Media Composer, the OpenTimelineIO adapter, the Autodesk/Flame loader)
///   strips a trailing CR before splitting a line, so CRLF is accepted
///   everywhere a bare LF is and the reverse is not guaranteed — CRLF is the
///   strictly safer of the two, not merely the traditional one.
/// - **`AUDIO_FORMAT` is written `48kHz`.** Files exported by Media Composer
///   itself spell it `48khz`; the format's published keyword list spells it
///   `48kHz`. Both are in wide circulation and the value is a label rather than
///   something parsed into a number, so the documented spelling is used.
///
/// `VIDEO_FORMAT` is an Avid enumeration, not a resolution — see `videoFormat`.
public enum ALEExporter {
    /// Sections are separated by a blank line; every line, including the last,
    /// is terminated.
    private static let newline = "\r\n"

    /// The columns that mean something on set. Order is the file's contract:
    /// the `Column` line defines it and every `Data` row follows it.
    ///
    /// `Tape` is the reel, and it is the SAME string the EDL puts in its reel
    /// field (see `EDLExporter.reelName`) — an assistant conforming the EDL and
    /// importing this log side by side has to see one name for one roll, or the
    /// two do not join up.
    static let columns = ["Name", "Tape", "Start", "End", "Duration", "FPS",
                          "Take", "Scene", "Good Take", "Comments"]

    /// Build the ALE text. `takes` are already filtered/ordered by the caller;
    /// nil when there is nothing to export, matching `EDLExporter.selectsEDL`.
    ///
    /// `format` is the signal the takes were captured from — the only source of
    /// a frame size, since a `Take` carries timing and metadata but no raster.
    /// Without it the heading says `CUSTOM`, which is the honest answer rather
    /// than a guess an Avid project would be conformed against.
    public static func ale(takes: [Take], format: CaptureFormat? = nil) -> String? {
        guard !takes.isEmpty else { return nil }
        var lines = headingLines(takes: takes, format: format)
        lines += ["", "Column", columns.joined(separator: "\t"), "", "Data"]
        lines += takes.enumerated().map { dataLine(for: $1, index: $0) }
        return lines.joined(separator: newline) + newline
    }

    /// The global header: what applies to the whole file. `FIELD_DELIM` is
    /// `TABS` and nothing else — the alternative the format allows is a comma,
    /// and no current tool writes one.
    private static func headingLines(takes: [Take],
                                     format: CaptureFormat?) -> [String] {
        // the project rate: the measured one when a signal is known (23.976 is
        // not expressible as a nominal timecode rate), else the first take's
        let rate = format?.frameRate
            ?? TakeLogExporter.realRate(of: takes[0].startTimecode
                ?? TakeLogExporter.fallbackRate)
        return ["Heading",
                "FIELD_DELIM\tTABS",
                "VIDEO_FORMAT\t\(videoFormat(of: format))",
                "AUDIO_FORMAT\t48kHz",
                "FPS\t\(rateText(rate))"]
    }

    /// One take. Its timecodes are counted on the take's OWN rate, like the
    /// EDL's source side: a day that changed frame rate at lunch otherwise gets
    /// half its log measured against the wrong timebase.
    private static func dataLine(for take: Take, index: Int) -> String {
        let (start, end) = span(of: take)
        return [
            take.url.lastPathComponent,
            EDLExporter.reelName(for: take, index: index),
            start.description,
            end.description,
            TakeLogExporter.durationTimecode(of: take),
            rateText(TakeLogExporter.realRate(of: start)),
            String(take.takeNumber),
            take.scene,
            TakeLogExporter.goodTakeField(rating: take.rating),
            TakeLogExporter.commentsField(rating: take.rating,
                                          comment: take.comment),
        ].map(field).joined(separator: "\t")
    }

    /// A take's Start and End.
    ///
    /// A take with NO start timecode is written as an offset from zero rather
    /// than left blank — the same convention the markers sidecar already uses
    /// for such a take. Blank Start/End cells import as a clip with no position
    /// at all, and the length the operator can see in the app disappears with
    /// them; zero-based ones at least carry the duration across intact.
    private static func span(of take: Take) -> (start: Timecode, end: Timecode) {
        let start = take.startTimecode ?? TakeLogExporter.fallbackRate
        let frames = TakeLogExporter.frameOffset(seconds: take.durationSeconds,
                                                 at: start)
        return (start, Timecode(frameNumber: start.frameNumber + frames,
                                fps: start.fps, isDropFrame: start.isDropFrame))
    }

    /// `VIDEO_FORMAT` is an Avid enumeration — `1080`, `720`, `PAL`, `NTSC` or
    /// `CUSTOM` — not the frame size. Anything wider than HD is `CUSTOM` even
    /// when it is 1080 high, which is what 2K DCI (2048x1080) is.
    private static func videoFormat(of format: CaptureFormat?) -> String {
        guard let format, format.width <= 1920 else { return "CUSTOM" }
        switch format.height {
        case 1080: return "1080"
        case 720: return "720"
        case 576: return "PAL"
        case 486, 480: return "NTSC"
        default: return "CUSTOM"
        }
    }

    /// A frame rate as ALE writes it: `25`, `29.97`, `23.976`. Rounded to three
    /// decimals first, because the real rate behind 29.97 is 30000/1001 and
    /// printing it raw puts `29.970029` in a field Avid shows to a human.
    private static func rateText(_ rate: Double) -> String {
        let rounded = (max(0, min(1000, rate)) * 1000).rounded() / 1000
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%g", rounded)
    }

    /// ALE has no quoting mechanism at all: a tab inside a value shifts every
    /// later column of that row and a newline splits it into two clips, both
    /// silently. Commas need nothing — this is not a CSV, and quoting one the
    /// way the CSV exporter does would put the quotes in the imported metadata.
    private static func field(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}
