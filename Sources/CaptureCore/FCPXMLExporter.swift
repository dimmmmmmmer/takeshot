import Foundation

/// **The day as a timeline, in the one XML both Resolve and Premiere read.**
///
/// The EDL beside this is a cut list and the ALE is a log; neither carries the
/// FILES. An EDL names reels and leaves the assistant to relink, which on a
/// video-assist day means relinking against names that were never on a camera
/// original. FCPXML carries an absolute path per clip, so the timeline opens
/// with the picture already on it (owner: "xml бы тоже уметь экспортировать",
/// and "если еще дрт таймлайн сможем экспортить будет вообще отлично").
///
/// FCPXML 1.10 — the version Resolve 18/19 and Premiere both import. Time is
/// RATIONAL there, never decimal: `1001/24000s`, not `0.0417s`. That is not
/// pedantry about the format, it is the whole reason it can be exact — 23.976
/// has no finite decimal, and a timeline built from rounded decimals drifts a
/// frame every few minutes and lands the markers on the wrong picture. Every
/// time this writes is an integer multiple of the frame duration, expressed
/// over the frame duration's own denominator.
public enum FCPXMLExporter {
    /// A frame's length as the rational FCPXML wants. `1/25s` for PAL,
    /// `1001/24000s` for 23.976 — the NTSC rates are the reason this is a pair
    /// of integers rather than a Double.
    struct FrameDuration: Equatable {
        let numerator: Int
        let denominator: Int

        var text: String { "\(numerator)/\(denominator)s" }

        /// `frames` frames, over this frame duration's own denominator. Always
        /// an exact multiple, which is what makes the timeline conform.
        func time(frames: Int) -> String {
            frames == 0 ? "0s" : "\(frames * numerator)/\(denominator)s"
        }
    }

    /// The frame duration behind a take.
    ///
    /// Decided from the REAL rate rather than from the drop-frame flag: 29.97
    /// non-drop is an ordinary way to shoot and its flag says nothing, while a
    /// take whose timecode numbers at 30 and whose file runs at 29.97 is the
    /// case a nominal reading gets wrong. The flag is the fallback for a take
    /// that carries no rate of its own.
    static func frameDuration(for take: Take) -> FrameDuration {
        let nominal = take.startTimecode?.fps ?? 25
        let real = TakeLogExporter.realRate(for: take)
        // Within half a frame a second of the 1000/1001 rate: NTSC.
        let ntsc = Double(nominal) * 1000.0 / 1001.0
        if abs(real - ntsc) < abs(real - Double(nominal)) {
            return FrameDuration(numerator: 1001, denominator: nominal * 1000)
        }
        return FrameDuration(numerator: 1, denominator: max(1, nominal))
    }

    /// One take, resolved to everything the two elements it becomes have to
    /// say about it. A value rather than six arguments threaded twice: the
    /// asset and the clip must agree on all of them, and the way they stop
    /// agreeing is one call site being edited and not the other.
    private struct Placed {
        let assetID: String
        let formatID: String
        let take: Take
        let frame: FrameDuration
        /// The take's length in its OWN frames.
        let frames: Int
        /// Where the file's timecode starts, in its own frames.
        let start: Int

        /// The same length counted in the SEQUENCE's frames — what the record
        /// side advances by, which is not the clip's own count when the two
        /// run at different rates.
        func recordFrames(on sequence: FrameDuration) -> Int {
            Int((Double(frames) * Double(frame.numerator)
                / Double(frame.denominator)
                * Double(sequence.denominator) / Double(sequence.numerator))
                .rounded())
        }
    }

    /// The document. `takes` are already filtered and ordered by the caller;
    /// nil when there is nothing to write.
    ///
    /// `format` is the only source of a raster — a take carries timing but no
    /// frame size — and with no device attached the sequence falls back to
    /// 1920×1080, which is what the ALE's CUSTOM heading does for the same
    /// reason. The picture on the timeline is the FILE's, whatever this says;
    /// the number only sizes the canvas.
    public static func timeline(takes: [Take], project: String,
                                format: CaptureFormat? = nil) -> String? {
        guard !takes.isEmpty else { return nil }
        // The sequence runs at the FIRST take's rate. A day that mixed rates
        // would need a format per clip, which Resolve honours and Premiere
        // reads as a conform — either way each clip keeps its own, below.
        let sequence = frameDuration(for: takes[0])
        let width = format?.width ?? 1920
        let height = format?.height ?? 1080
        // **One project per shift** (owner: "может нам учитывать
        // многосменность в экспорте хмл"). The RESOURCES stay one list for the
        // whole library, which is what the format wants and what keeps a take
        // appearing in two shifts impossible: the ids run across every day.
        let days = Shifts.split(takes)
        let placed = place(days.flatMap(\.takes), sequence: sequence)
        var resources: [String] = [
            formatElement(id: "r0", frame: sequence, width: width, height: height),
        ]
        for clip in placed where clip.formatID != "r0" {
            resources.append(formatElement(id: clip.formatID, frame: clip.frame,
                                           width: width, height: height))
        }
        resources.append(contentsOf: placed.map(assetElement))
        let title = project.isEmpty ? "TakeShot" : project
        var projects: [String] = []
        var next = 0
        for day in days {
            let clips = placed[next..<(next + day.takes.count)]
            next += day.takes.count
            projects.append(projectElement(
                name: escape(name(title, of: day, ofMany: days.count > 1)),
                clips: Array(clips), sequence: sequence))
        }
        return document(name: escape(title), projects: projects,
                        resources: resources)
    }

    /// A shift's project name: the project alone when it is the only one, and
    /// the project plus the day it was shot when there are several. See
    /// `FCP7XMLExporter.name` — one rule, two writers.
    static func name(_ project: String, of day: Shifts.Day,
                     ofMany: Bool) -> String {
        ofMany ? "\(project) \(Shifts.stamp(day.start))" : project
    }

    /// One shift as one project: its clips laid end to end from zero.
    private static func projectElement(name: String, clips: [Placed],
                                       sequence: FrameDuration) -> String {
        var spine: [String] = []
        var offset = 0
        for clip in clips {
            spine.append(clipElement(clip, offset: sequence.time(frames: offset)))
            offset += clip.recordFrames(on: sequence)
        }
        let dropFrame = clips.first?.take.startTimecode?.isDropFrame == true
        return projectBody(name: name, dropFrame: dropFrame,
                           duration: sequence.time(frames: offset),
                           clips: spine)
    }

    /// Each take with its ids and its numbers worked out once.
    private static func place(_ takes: [Take],
                              sequence: FrameDuration) -> [Placed] {
        takes.enumerated().map { index, take in
            let frame = frameDuration(for: take)
            return Placed(assetID: "a\(index + 1)",
                          formatID: frame == sequence ? "r0" : "r\(index + 1)",
                          take: take, frame: frame,
                          frames: frameCount(of: take, frame: frame),
                          start: startFrames(of: take))
        }
    }

    // MARK: - the elements

    private static func document(name: String, projects: [String],
                                 resources: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
          <resources>
        \(resources.joined(separator: "\n"))
          </resources>
          <library>
            <event name="\(name)">
        \(projects.joined(separator: "\n"))
            </event>
          </library>
        </fcpxml>

        """
    }

    private static func projectBody(name: String, dropFrame: Bool,
                                    duration: String, clips: [String]) -> String {
        """
              <project name="\(name)">
                <sequence format="r0" tcStart="0s" \
        tcFormat="\(dropFrame ? "DF" : "NDF")" duration="\(duration)">
                  <spine>
        \(clips.joined(separator: "\n"))
                  </spine>
                </sequence>
              </project>
        """
    }

    private static func formatElement(id: String, frame: FrameDuration,
                                      width: Int, height: Int) -> String {
        "    <format id=\"\(id)\" frameDuration=\"\(frame.text)\" "
            + "width=\"\(width)\" height=\"\(height)\"/>"
    }

    /// One asset. `hasAudio` is declared and the channel count is NOT.
    ///
    /// A take carries no audio description — there is nothing on `Take` to read
    /// — so `audioChannels="2"` would be an invented fact, the same kind the
    /// EDL refuses to invent when it passes nil for a .cube look rather than
    /// writing an identity SOP. Declaring the flag without the numbers leaves
    /// the NLE to read the file's own tracks, which is what it does anyway.
    ///
    /// Declared rather than omitted because the two mistakes are not equal: a
    /// flag on a silent take costs nothing (the NLE finds no audio and links
    /// none), while omitting it on a take that HAS audio is how the sound
    /// quietly fails to come across.
    private static func assetElement(_ clip: Placed) -> String {
        """
            <asset id="\(clip.assetID)" name="\(escape(clip.take.displayName))" \
        start="\(clip.frame.time(frames: clip.start))" \
        duration="\(clip.frame.time(frames: clip.frames))" \
        hasVideo="1" hasAudio="1" format="\(clip.formatID)">
              <media-rep kind="original-media" src="\(source(of: clip.take))"/>
            </asset>
        """
    }

    private static func clipElement(_ clip: Placed, offset: String) -> String {
        let markers = clip.take.markers.map { marker in
            // On the CLIP's own timeline, which starts at the asset's source
            // timecode — a marker written from zero lands on the wrong frame
            // by exactly the take's start TC.
            let at = clip.start
                + TakeLogExporter.frameOffset(seconds: marker.seconds,
                                              for: clip.take)
            let note = marker.note.isEmpty ? marker.timecodeText : marker.note
            return """
                        <marker start="\(clip.frame.time(frames: at))" \
            duration="\(clip.frame.text)" value="\(escape(note))"/>
            """
        }
        let head = """
                <asset-clip ref="\(clip.assetID)" \
        name="\(escape(clip.take.displayName))" offset="\(offset)" \
        start="\(clip.frame.time(frames: clip.start))" \
        duration="\(clip.frame.time(frames: clip.frames))" \
        format="\(clip.formatID)"
        """
        guard !markers.isEmpty else { return head + "/>" }
        return head + ">\n" + markers.joined(separator: "\n")
            + "\n            </asset-clip>"
    }

    // MARK: - the numbers

    /// The take's length in ITS OWN frames, never zero: a clip of no length is
    /// one Resolve drops from the timeline without saying so, and a take that
    /// records a fraction of a second is still a take that happened.
    static func frameCount(of take: Take, frame: FrameDuration) -> Int {
        let rate = Double(frame.denominator) / Double(frame.numerator)
        return max(1, Int((take.durationSeconds * rate).rounded()))
    }

    /// Where the file's own timecode starts, in frames. Zero for a take that
    /// carries none — the file then reads as starting at 00:00:00:00, which is
    /// what every other export in the app says about it.
    static func startFrames(of take: Take) -> Int {
        take.startTimecode?.frameNumber ?? 0
    }

    /// The file, as the `src` attribute wants it: an absolute file URL with
    /// every reserved character percent-encoded.
    ///
    /// `URL.absoluteString` and not a hand-built "file://" + path: a shooting
    /// day's folder holds spaces, `#` and `&` (a project called "A&B"), and a
    /// path pasted in raw makes the document fail to parse rather than fail to
    /// relink — the error Resolve shows for it names the line, not the file.
    static func source(of take: Take) -> String {
        escape(take.url.absoluteString)
    }

    /// XML text escaping. `&` first, or the ampersands introduced by the other
    /// replacements get escaped a second time.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
