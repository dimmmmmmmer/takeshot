import Foundation

/// CMX 3600 EDL of selected takes: one event per take, cut back to back on
/// the record side, with take markers as locator (`* LOC:`) lines — DaVinci
/// Resolve imports those as timeline markers.
public enum EDLExporter {
    /// The record timeline's format, carried as one value instead of threading
    /// the fps/drop-frame pair through every helper.
    private struct Timeline {
        let fps: Int
        let isDropFrame: Bool

        /// drop-frame TC runs at fps*1000/1001 real frames per second
        var realRate: Double {
            Double(fps) * (isDropFrame ? 1000.0 / 1001.0 : 1)
        }
    }

    /// Build the EDL text. `takes` are already filtered/ordered by the caller;
    /// nil when there is nothing to export.
    ///
    /// `cdl` is the session's active look when — and only when — that look is an
    /// ASC CDL. It becomes an `*ASC_SOP`/`*ASC_SAT` pair on every event, which
    /// is how a grade travels from the cart to the colourist inside a conform.
    /// A .cube look passes nil: nine numbers cannot describe a 3D LUT, and
    /// writing an identity SOP instead would tell the colourist the day was
    /// graded flat when it was not.
    /// `ranges` are the in/out marks the operator made during review, keyed by
    /// file name as the transport keys them. A marked take becomes an event
    /// over the PART that was chosen — the source in/out say so — while the
    /// reel it names is the whole take, so an editor can pull the head or the
    /// tail back (owner: "в самом таймлайне клип кидай по ин ауту но сорс
    /// пускай остается полным").
    public static func selectsEDL(takes: [Take], title: String,
                                  fps defaultFPS: Int = 25,
                                  cdl: CDLLook? = nil,
                                  ranges: [String: ClipRange] = [:]) -> String? {
        guard !takes.isEmpty else { return nil }
        let fps = takes.first?.startTimecode?.fps ?? defaultFPS
        let dropFrame = takes.first?.startTimecode?.isDropFrame ?? false
        var lines = [
            "TITLE: \(title)",
            "FCM: \(dropFrame ? "DROP FRAME" : "NON-DROP FRAME")",
            "",
        ]
        let timeline = Timeline(fps: fps, isDropFrame: dropFrame)
        let realRate = timeline.realRate
        // record timeline starts at 01:00:00:00, takes cut back to back
        var recordFrame = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0,
                                   fps: fps, isDropFrame: dropFrame).frameNumber
        for (index, take) in takes.enumerated() {
            // The part the operator chose, on the take's own timebase — and
            // the whole take, which is what the markers are measured from.
            let span = TakeSpan.marked(take, range: ranges[TakeRuntime.key(take)])
            let whole = TakeSpan.of(take)
            // The RECORD side advances by what this event actually shows, at
            // the sequence's rate: a trimmed event that advanced by the whole
            // take's length would leave a gap on the timeline.
            let placed = Placed(
                take: take, span: span, sourceFrames: sourceFrames(of: span),
                head: span.offset(from: whole),
                rate: whole.rate, recordFrame: recordFrame,
                frames: max(1, Int((Double(span.frames) / span.rate
                    * realRate).rounded())))
            lines += eventLines(for: placed, index: index, timeline: timeline)
            if let cdl { lines += ascLines(for: cdl) }
            lines += markerLines(for: placed, timeline: timeline)
            lines.append("")
            recordFrame += placed.frames
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One take's place in the list: the part of it this event shows, how far
    /// into the take that part starts, and where it lands on the record side.
    ///
    /// A value rather than the five arguments the two writers below would both
    /// have taken — which is also what the project's parameter-count limit
    /// says — and a real grouping rather than a bag: the event line and its
    /// locators state the same trim, and the way they stop agreeing is one
    /// call site being edited and not the other.
    private struct Placed {
        let take: Take
        /// The part the operator chose, on the take's own timebase.
        let span: TakeSpan
        /// The same length with this FORMAT's floor under it — see
        /// `sourceFrames(of:)`.
        let sourceFrames: Int

        /// Where the event's source side ends.
        var sourceOut: Timecode {
            Timecode(frameNumber: span.start.frameNumber + sourceFrames,
                     fps: span.start.fps, isDropFrame: span.start.isDropFrame)
        }
        /// Frames into the take that part begins at — 0 for an unmarked take.
        let head: Int
        /// The take's own real frames a second, which `head` is counted in.
        let rate: Double
        /// Where the event sits on the record timeline, and how long it runs
        /// there — both in the sequence's frames.
        let recordFrame: Int
        let frames: Int
    }

    /// **A CMX event of no length is invalid**, so a take that finalized with
    /// nothing in it still cuts one frame here — the floor the record side
    /// below has always had, applied to the SOURCE side as well.
    ///
    /// Here and not in `TakeSpan`, deliberately: where a take ENDED is a fact
    /// about the take and a zero-length one ended where it started
    /// (`TakeSpanTests.aZeroLengthTakeEndsWhereItStarted`), while one frame is
    /// a rule about this document. A marked span is clamped already — this is
    /// only ever the unmarked zero-length case.
    private static func sourceFrames(of span: TakeSpan) -> Int {
        max(1, span.frames)
    }

    /// One event: the cut line, the source clip name and the take comment.
    private static func eventLines(for placed: Placed, index: Int,
                                   timeline: Timeline) -> [String] {
        let take = placed.take
        let fps = timeline.fps
        let dropFrame = timeline.isDropFrame
        // Source TCs run at the TAKE's own rate (mixed-fps sessions): using
        // the master rate landed conform on wrong frames. `TakeSpan` carries
        // that arithmetic, and `marked` narrows it to the part the operator
        // chose — the reel still points at the whole take.
        let sourceIn = placed.span.start
        let sourceOut = placed.sourceOut
        let recordIn = Timecode(frameNumber: placed.recordFrame, fps: fps,
                                isDropFrame: dropFrame)
        let recordOut = Timecode(frameNumber: placed.recordFrame + placed.frames,
                                 fps: fps, isDropFrame: dropFrame)
        let reel = reelName(for: take, index: index)
        var lines = [String(
            format: "%03d  %@ V     C        %@ %@ %@ %@",
            index + 1, reelField(reel),
            sourceIn.description, sourceOut.description,
            recordIn.description, recordOut.description)]
        lines.append("* FROM CLIP NAME: \(take.url.lastPathComponent)")
        if !take.comment.isEmpty {
            // newlines in a comment would inject arbitrary EDL lines
            let flat = take.comment
                .components(separatedBy: .newlines).joined(separator: " ")
            lines.append("* COMMENT: \(flat)")
        }
        return lines
    }

    /// The active ASC CDL as the two standard CMX comments.
    ///
    /// No space after the asterisk, unlike the `* FROM CLIP NAME:` line above
    /// it: `*ASC_SOP` is what Resolve writes and what every CDL reader looks
    /// for, and this pair is machine-read where the others are read by people.
    ///
    /// Four decimals, not more. The ASC's implementor note limits the values to
    /// five digits of precision precisely so all nine fit in one 80-column CMX
    /// comment — six decimals pushes the SOP line to 84 characters and out of
    /// the format it is a comment in.
    private static func ascLines(for cdl: CDLLook) -> [String] {
        ["*ASC_SOP \(group(cdl.slope))\(group(cdl.offset))\(group(cdl.power))",
         String(format: "*ASC_SAT %.4f", cdl.saturation)]
    }

    /// One triple of the SOP, as the ASC prints it. Internal rather than
    /// private because the ALE writes the SAME nine numbers in its own
    /// `ASC_SOP` column (`ALEExporter.ascSOP`) — an assistant conforming the
    /// EDL and importing the log side by side must not find two spellings of
    /// one grade.
    static func group(_ rgb: CDLLook.RGB) -> String {
        String(format: "(%.4f %.4f %.4f)", rgb.r, rgb.g, rgb.b)
    }

    /// **The take's markers as `* LOC:` locator lines**, placed on the record
    /// timeline (Resolve imports these as timeline markers) and measured from
    /// the part that is ON it.
    ///
    /// `Placed.head` is how far into the take the event starts, in the take's
    /// own frames. A marker before that point is not on this event at all, and
    /// one written from the take's first frame would land that far ahead of
    /// where it belongs — on the event before, or off the front of the
    /// timeline.
    ///
    /// Outside the chosen part they are DROPPED rather than clamped: a locator
    /// sitting on the first frame, for a moment that is not in the cut, is a
    /// worse answer than no locator.
    private static func markerLines(for placed: Placed,
                                    timeline: Timeline) -> [String] {
        let headSeconds = placed.rate > 0 ? Double(placed.head) / placed.rate : 0
        return placed.take.markers.compactMap { marker -> String? in
            let offset = Int(((marker.seconds - headSeconds)
                * timeline.realRate).rounded())
            guard offset >= 0, offset < placed.frames else { return nil }
            let locator = Timecode(frameNumber: placed.recordFrame + offset,
                                   fps: timeline.fps,
                                   isDropFrame: timeline.isDropFrame)
            var name = marker.note
                .components(separatedBy: .newlines).joined(separator: " ")
            if name.isEmpty {
                name = marker.timecodeText.isEmpty ? "MARKER"
                                                   : marker.timecodeText
            }
            return "* LOC: \(locator.description) "
                + "\(locatorColor(for: marker.color)) \(name)"
        }
    }

    /// **The app's swatches, mapped onto the palette a `* LOC:` line has.**
    ///
    /// Avid defined the locator convention and its colour set is the one every
    /// conform tool reads: white, red, green, blue, cyan, magenta, yellow,
    /// black. The app's own swatches are the OPERATOR's palette and two of
    /// them — orange and purple — are in nobody's. Written through verbatim,
    /// `ORANGE` is a word the importer does not know on a line it otherwise
    /// understands, and the marker arrives with its colour dropped: the
    /// assistant conforming the day sees a wall of identical locators where
    /// the operator had been colour-coding takes since call time.
    ///
    /// Orange lands on YELLOW and not on RED. Red is what every set uses for
    /// "do not use this one", and moving a note there would make the EDL say
    /// something the operator did not.
    ///
    /// A colour with no mapping lands on WHITE rather than being written
    /// through: an importer that knows white draws the marker, and a marker
    /// drawn in the wrong colour is recoverable in a way one that never
    /// appeared is not.
    static let locatorColors = [
        "orange": "YELLOW", "red": "RED", "yellow": "YELLOW",
        "green": "GREEN", "cyan": "CYAN", "blue": "BLUE",
        "purple": "MAGENTA",
    ]

    static func locatorColor(for swatch: String) -> String {
        locatorColors[swatch.lowercased()] ?? "WHITE"
    }

    /// Reels are 8 chars in CMX: the roll when present, else a counter.
    ///
    /// Not private: the ALE's Tape column is the same reel by definition, and
    /// an assistant conforming this EDL while importing that log has to see one
    /// name for one roll. Two implementations of "the reel of a take" is how
    /// they would drift apart.
    static func reelName(for take: Take, index: Int) -> String {
        let base = take.roll.isEmpty ? String(format: "TS%03d", index + 1)
                                     : take.roll
        // Every kind of whitespace, not just the space character. A tab shifts
        // every column after the reel and a newline ends the event statement
        // early, leaving its second half to be read as an EDL statement of its
        // own — and CMX has no quoting to escape either with. A roll typed into
        // the app cannot carry one (see `NameField.roll`), but a roll restored
        // from a hand-edited log or read off a foreign file's metadata can.
        let cleaned = base.components(separatedBy: .whitespacesAndNewlines)
            .joined(separator: "_")
        return String(cleaned.prefix(8))
    }

    /// The reel in its 8-wide CMX column.
    ///
    /// Padded by CHARACTERS rather than through `padding(toLength:)`, which
    /// counts UTF-16 units: an eight-character reel holding an emoji is
    /// thirteen of those, and asking for eight cut the string through the
    /// middle of a surrogate pair — a replacement character in the file and a
    /// column that no longer lines up. Identical output for anything ASCII,
    /// which is every reel this app will accept from the keyboard.
    private static func reelField(_ reel: String) -> String {
        reel + String(repeating: " ", count: max(0, 8 - reel.count))
    }
}
