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
    public static func selectsEDL(takes: [Take], title: String,
                                  fps defaultFPS: Int = 25,
                                  cdl: CDLLook? = nil) -> String? {
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
            let frames = max(1, Int((take.durationSeconds * realRate).rounded()))
            lines += eventLines(for: take, index: index, recordFrame: recordFrame,
                                frames: frames, timeline: timeline)
            if let cdl { lines += ascLines(for: cdl) }
            lines += markerLines(for: take, recordFrame: recordFrame,
                                 timeline: timeline)
            lines.append("")
            recordFrame += frames
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One event: the cut line, the source clip name and the take comment.
    /// `frames` is the take's length on the RECORD side, already computed at
    /// the master rate by the caller.
    private static func eventLines(for take: Take, index: Int, recordFrame: Int,
                                   frames: Int, timeline: Timeline) -> [String] {
        let fps = timeline.fps
        let dropFrame = timeline.isDropFrame
        // source TCs run at the TAKE's own rate (mixed-fps sessions):
        // using the master rate landed conform on wrong frames
        let sourceFPS = take.startTimecode?.fps ?? fps
        let sourceDF = take.startTimecode?.isDropFrame ?? dropFrame
        let sourceRate = Double(sourceFPS) * (sourceDF ? 1000.0 / 1001.0 : 1)
        let sourceFrames = max(1, Int((take.durationSeconds
            * sourceRate).rounded()))
        let sourceIn = take.startTimecode
            ?? Timecode(frameNumber: 0, fps: sourceFPS, isDropFrame: sourceDF)
        let sourceOut = Timecode(frameNumber: sourceIn.frameNumber + sourceFrames,
                                 fps: sourceFPS, isDropFrame: sourceDF)
        let recordIn = Timecode(frameNumber: recordFrame, fps: fps,
                                isDropFrame: dropFrame)
        let recordOut = Timecode(frameNumber: recordFrame + frames, fps: fps,
                                 isDropFrame: dropFrame)
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

    private static func group(_ rgb: CDLLook.RGB) -> String {
        String(format: "(%.4f %.4f %.4f)", rgb.r, rgb.g, rgb.b)
    }

    /// The take's markers as `* LOC:` locator lines, placed on the record
    /// timeline (Resolve imports these as timeline markers).
    private static func markerLines(for take: Take, recordFrame: Int,
                                    timeline: Timeline) -> [String] {
        take.markers.map { marker in
            let offset = Int((marker.seconds * timeline.realRate).rounded())
            let locator = Timecode(frameNumber: recordFrame + offset,
                                   fps: timeline.fps,
                                   isDropFrame: timeline.isDropFrame)
            var name = marker.note
                .components(separatedBy: .newlines).joined(separator: " ")
            if name.isEmpty {
                name = marker.timecodeText.isEmpty ? "MARKER"
                                                   : marker.timecodeText
            }
            return "* LOC: \(locator.description) "
                + "\(marker.color.uppercased()) \(name)"
        }
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
