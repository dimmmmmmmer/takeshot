import Foundation

/// **The day as a timeline in FCP7 XML** — `xmeml`, the `.xml` every edit
/// suite still reads (owner: "таймлайн хмл мне нужен .xml а не fcpxml").
///
/// # Why a second timeline writer and not a rename
///
/// FCPXML 1.10 next door is the modern interchange and Resolve 18/19 and
/// Premiere both import it. It is also, outside those two, the format nothing
/// else reads: Media Composer, Vegas, Edius, Lightworks, Flame, an online
/// house's asset manager and every "send me an XML" plugin written before 2013
/// speak `xmeml` version 5 and nothing newer. On a video-assist day the
/// timeline is sent to whoever is cutting, and that is not always the two
/// applications the newer format covers.
///
/// The two are therefore both kept and they are genuinely different documents,
/// not one format with two extensions:
///
/// | | FCPXML 1.10 | FCP7 XML (here) |
/// | --- | --- | --- |
/// | time | rational seconds, `1001/24000s` | integer FRAMES |
/// | rate | the frame duration itself | nominal timebase + an NTSC flag |
/// | sound | declared on the asset, linked by the NLE | its own track, linked here |
///
/// # Where frames make this exact, and where they do not
///
/// FCPXML is rational because a decimal cannot state 23.976; this format is
/// integer frames for the same end by the other road — a frame count has no
/// rounding in it at all, and the rate that turns it back into time is a
/// nominal timebase with a flag saying whether it runs at 1000/1001 of itself.
/// So `<timebase>24</timebase><ntsc>TRUE</ntsc>` IS 23.976, exactly, and every
/// position on the timeline is a whole number of frames.
///
/// What that cannot express is a timeline of MIXED rates. The sequence has one
/// timebase, and a clip at another rate is placed at a record position counted
/// in the sequence's frames while its own in/out stay in its own — which is
/// what an NLE conforms on import. A day shot at one rate, which is nearly
/// every day, has no such joint at all.
public enum FCP7XMLExporter {
    /// A rate as `xmeml` states one: the nominal integer timebase and whether
    /// it is the NTSC 1000/1001 version of it.
    ///
    /// Two fields rather than a Double because the file has two fields, and
    /// because the pair is exact where a Double is not: 24 + NTSC is 23.976
    /// with no decimal anywhere in the document.
    struct Rate: Equatable {
        let timebase: Int
        let ntsc: Bool

        /// Real frames a second — what a duration in seconds is counted with.
        var real: Double {
            Double(max(1, timebase)) * (ntsc ? 1000.0 / 1001.0 : 1)
        }
    }

    /// The rate behind a take.
    ///
    /// Decided from the REAL rate rather than from the drop-frame flag, for
    /// `FCPXMLExporter.frameDuration`'s reason: 29.97 non-drop is an ordinary
    /// way to shoot and its flag says nothing, while a take whose timecode
    /// numbers at 30 and whose file runs at 29.97 is exactly the case a
    /// nominal reading gets wrong.
    static func rate(for take: Take) -> Rate {
        let nominal = take.startTimecode?.fps ?? 25
        let real = TakeLogExporter.realRate(for: take)
        let ntsc = Double(nominal) * 1000.0 / 1001.0
        return Rate(timebase: max(1, nominal),
                    ntsc: abs(real - ntsc) < abs(real - Double(nominal)))
    }

    /// One take with every number the four elements it becomes have to agree
    /// about. A value rather than arguments threaded four times: the file, the
    /// picture clip, the sound clip and the link between them all state the
    /// same lengths, and the way they stop agreeing is one call site being
    /// edited and not the others.
    struct Placed {
        let take: Take
        let rate: Rate
        /// 1-based position in ITS OWN track — `clipindex` in the link
        /// elements, which is per sequence and restarts every shift.
        let index: Int
        /// 1-based position in the DOCUMENT, which every element id is built
        /// from. Two numbers because a multi-shift export has two countings:
        /// ids must be unique across the whole file and a clip index must not
        /// be, and writing one number into both roles is how a second day's
        /// links point at the first day's clips.
        let id: Int
        /// The WHOLE file's length in ITS OWN frames — the media's extent,
        /// which `<file><duration>` declares however little of it is used.
        let frames: Int
        /// How far into the file the clip starts, in the file's own frames —
        /// zero unless the operator marked an in point.
        let head: Int
        /// How much of the file the clip USES, in the file's own frames (owner:
        /// "в самом таймлайне клип кидай по ин ауту но сорс пускай остается
        /// полным"). The whole of it unless review narrowed it; the file stays
        /// whole either way, so the handles are there to pull back out.
        let used: Int
        /// The USED length in the SEQUENCE's frames, which is what the record
        /// side advances by and is not the clip's own count at a mixed rate.
        let recordFrames: Int
        /// Where this clip sits on the timeline, in sequence frames.
        let offset: Int
        /// The file's own timecode start, in its own frames.
        let start: Int
        /// The raster declared for this file. The same one the sequence
        /// declares — a take carries timing but no frame size — and stated on
        /// the file as well because some readers size a clip from there rather
        /// than from the sequence, and a file with no raster at all links as a
        /// clip of no width. The FCPXML writer makes the identical claim on
        /// its per-clip `<format>` elements.
        let width: Int
        let height: Int

        /// The clip's out point on the FILE's own line — where `<out>` goes.
        var tail: Int { head + used }

        var fileID: String { "file-\(id)" }
        /// Picture and sound get their own ids out of one counter, so a
        /// reader that resolves `linkclipref` finds exactly one clip.
        var videoID: String { "clipitem-\(id * 2 - 1)" }
        var audioID: String { "clipitem-\(id * 2)" }
    }

    /// The frame size the document declares, on the sequence's canvas and on
    /// every file in it. One value because the two always agree — and because
    /// a pair threaded through `place` would be two of the arguments the
    /// project's parameter-count limit allows it.
    struct Raster: Equatable {
        let width: Int
        let height: Int
    }

    /// What a sequence says about itself before its clips: its element id,
    /// its name, the rate every position on it is counted on, how long it is,
    /// and the raster its canvas takes.
    struct Head {
        let id: String
        let name: String
        let rate: Rate
        let duration: Int
        let width: Int
        let height: Int
    }

    /// The document. `takes` are already filtered and ordered by the caller;
    /// nil when there is nothing to write.
    ///
    /// `format` is the only source of a raster — a take carries timing but no
    /// frame size — and with no device attached the sequence falls back to
    /// 1920×1080, which is what the ALE's CUSTOM heading does for the same
    /// reason. The picture on the timeline is the FILE's, whatever this says;
    /// the number only sizes the canvas.
    /// `ranges` are the in/out marks made during review, keyed the way the
    /// transport keys them. A marked take lands on the timeline as the part
    /// that was chosen — `<in>`/`<out>` say which — while the `<file>` keeps
    /// the whole take's duration, so the editor can drag either end back.
    public static func timeline(takes: [Take], project: String,
                                format: CaptureFormat? = nil,
                                ranges: [String: ClipRange] = [:]) -> String? {
        guard !takes.isEmpty else { return nil }
        let raster = Raster(width: format?.width ?? 1920,
                            height: format?.height ?? 1080)
        let width = raster.width
        let height = raster.height
        let days = Shifts.split(takes)
        let title = project.isEmpty ? "TakeShot" : project
        var sequences: [String] = []
        var id = 1
        for (index, day) in days.enumerated() {
            let rate = rate(for: day.takes[0])
            let placed = place(day.takes, sequence: rate, raster: raster,
                               from: id, ranges: ranges)
            id += placed.count
            let duration = (placed.last?.offset ?? 0)
                + (placed.last?.recordFrames ?? 0)
            sequences.append(sequenceElement(
                Head(id: "sequence-\(index + 1)",
                     name: escape(name(title, of: day, ofMany: days.count > 1)),
                     rate: rate, duration: duration,
                     width: width, height: height),
                video: placed.map(videoClip), audio: placed.map(audioClip)))
        }
        return document(sequences)
    }

    /// **One sequence per shift, named by the day it was shot** (owner: "может
    /// нам учитывать многосменность в экспорте хмл").
    ///
    /// A single-shift export keeps the project's bare name, which is what
    /// every timeline this app has written says and what an assistant reads on
    /// the bin. The date appears only when there is a second day to tell it
    /// apart from — a name that grew a date for every export would rename the
    /// one timeline most days produce, for nothing.
    static func name(_ project: String, of day: Shifts.Day,
                     ofMany: Bool) -> String {
        ofMany ? "\(project) \(Shifts.stamp(day.start))" : project
    }

    /// Each take with its numbers worked out once, laid end to end.
    static func place(_ takes: [Take], sequence: Rate, raster: Raster,
                      from id: Int = 1,
                      ranges: [String: ClipRange] = [:]) -> [Placed] {
        var offset = 0
        var placed: [Placed] = []
        for (index, take) in takes.enumerated() {
            let own = rate(for: take)
            let whole = frames(of: take, at: own)
            // The part review chose, counted in the FILE's own frames — the
            // same window the shift report's runtime is measured over, so a
            // clip on the timeline and a duration on the paperwork cannot
            // disagree about what was picked.
            let window = TakeRuntime.window(of: take,
                                            range: ranges[TakeRuntime.key(take)])
            // Clamped INTO the file before either number is used, for the
            // reason `FCPXMLExporter.place` states: a mark within half a frame
            // of the end rounds to the file's length, and a clip that starts
            // one past its own last frame is not a clip.
            let head = min(window.map { frames(seconds: $0.start, at: own) } ?? 0,
                           max(0, whole - 1))
            let tail = min(window.map { frames(seconds: $0.end, at: own) } ?? whole,
                           whole)
            let used = max(1, tail - head)
            // The RECORD side advances by what the clip SHOWS, at the
            // sequence's rate: an advance by the whole file would open a gap.
            let record = max(1, Int((Double(used) / own.real
                * sequence.real).rounded()))
            placed.append(Placed(take: take, rate: own, index: index + 1,
                                 id: id + index, frames: whole,
                                 head: head, used: used,
                                 recordFrames: record, offset: offset,
                                 start: take.startTimecode?.frameNumber ?? 0,
                                 width: raster.width, height: raster.height))
            offset += record
        }
        return placed
    }

    /// Seconds into a file, in that file's own frames.
    static func frames(seconds: Double, at rate: Rate) -> Int {
        guard seconds.isFinite else { return 0 }
        return max(0, Int((seconds * rate.real).rounded()))
    }

    /// A take's length in frames at `rate`, never zero: a clip of no length is
    /// one an NLE drops from the timeline without saying so, and a take that
    /// recorded a fraction of a second is still a take that happened.
    ///
    /// A length that cannot be read counts as one frame for the same reason —
    /// the file is on the timeline and can be looked at, which is a better
    /// answer than a clip that silently is not there.
    static func frames(of take: Take, at rate: Rate) -> Int {
        guard take.durationSeconds.isFinite else { return 1 }
        return max(1, Int((take.durationSeconds * rate.real).rounded()))
    }

    /// XML text escaping. `&` first, or the ampersands introduced by the other
    /// replacements get escaped a second time.
    static func escape(_ text: String) -> String {
        FCPXMLExporter.escape(text)
    }
}
