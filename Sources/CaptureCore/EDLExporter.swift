import Foundation

/// CMX 3600 EDL of selected takes: one event per take, cut back to back on
/// the record side, with take markers as locator (`* LOC:`) lines — DaVinci
/// Resolve imports those as timeline markers.
public enum EDLExporter {
    /// Build the EDL text. `takes` are already filtered/ordered by the caller;
    /// nil when there is nothing to export.
    public static func selectsEDL(takes: [Take], title: String,
                                  fps defaultFPS: Int = 25) -> String? {
        guard !takes.isEmpty else { return nil }
        let fps = takes.first?.startTimecode?.fps ?? defaultFPS
        let dropFrame = takes.first?.startTimecode?.isDropFrame ?? false
        var lines = [
            "TITLE: \(title)",
            "FCM: \(dropFrame ? "DROP FRAME" : "NON-DROP FRAME")",
            "",
        ]
        // record timeline starts at 01:00:00:00, takes cut back to back
        var recordFrame = 3600 * fps
        for (index, take) in takes.enumerated() {
            let frames = max(1, Int((take.durationSeconds
                * Double(fps)).rounded()))
            let sourceIn = take.startTimecode
                ?? Timecode(frameNumber: 0, fps: fps, isDropFrame: dropFrame)
            let sourceOut = Timecode(frameNumber: sourceIn.frameNumber + frames,
                                     fps: fps, isDropFrame: dropFrame)
            let recordIn = Timecode(frameNumber: recordFrame, fps: fps,
                                    isDropFrame: dropFrame)
            let recordOut = Timecode(frameNumber: recordFrame + frames, fps: fps,
                                     isDropFrame: dropFrame)
            let reel = reelName(for: take, index: index)
            lines.append(String(
                format: "%03d  %@ V     C        %@ %@ %@ %@",
                index + 1, reel.padding(toLength: 8, withPad: " ",
                                        startingAt: 0),
                sourceIn.description, sourceOut.description,
                recordIn.description, recordOut.description))
            lines.append("* FROM CLIP NAME: \(take.url.lastPathComponent)")
            if !take.comment.isEmpty {
                lines.append("* COMMENT: \(take.comment)")
            }
            for marker in take.markers {
                let offset = Int((marker.seconds * Double(fps)).rounded())
                let locator = Timecode(frameNumber: recordFrame + offset,
                                       fps: fps, isDropFrame: dropFrame)
                let name = marker.timecodeText.isEmpty
                    ? "MARKER" : marker.timecodeText
                lines.append("* LOC: \(locator.description) ORANGE \(name)")
            }
            lines.append("")
            recordFrame += frames
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reels are 8 chars in CMX: the roll when present, else a counter.
    private static func reelName(for take: Take, index: Int) -> String {
        let base = take.roll.isEmpty ? String(format: "TS%03d", index + 1)
                                     : take.roll
        let cleaned = base.replacingOccurrences(of: " ", with: "_")
        return String(cleaned.prefix(8))
    }
}
