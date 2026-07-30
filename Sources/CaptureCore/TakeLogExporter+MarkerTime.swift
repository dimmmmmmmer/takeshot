import Foundation

/// Positions on a take's own timebase: the conversion between a marker's
/// timecode and its offset in seconds, and the frame counting the shift report
/// measures durations with.
///
/// Its own file because three callers share it and none of them owns it: the
/// markers sidecar writes and reads the timecode column through it, `+Report`
/// counts a take's length with the same frame arithmetic, and the controller
/// anchors a recording's markers on the finished take with it — one
/// implementation, so a marker cannot land on a different frame depending on
/// whether the app has been restarted since.
extension TakeLogExporter {
    /// The Timecode column for one marker.
    ///
    /// Never blank: the column is the only record of the position now, and a
    /// marker flagged while recording a source with no timecode at all has no
    /// text of its own — writing it out empty would lose the marker.
    ///
    /// A take with no start timecode gets a DERIVED offset even when the marker
    /// does have text of its own. That text is the camera's absolute timecode,
    /// and with no take start to subtract it from there is nothing to resolve it
    /// against: read back it becomes a position measured from midnight, i.e. ten
    /// hours past the end of a five-second take. Such a take's positions are
    /// offsets from zero on both sides of the file — which is also what the
    /// player shows for it (`playbackTimecodeText`).
    public static func markerTimecode(of marker: TakeMarker,
                                      in take: Take) -> String {
        guard let start = take.startTimecode else {
            return offsetTimecode(seconds: marker.seconds, from: fallbackRate)
        }
        if !marker.timecodeText.isEmpty { return marker.timecodeText }
        return offsetTimecode(seconds: marker.seconds, from: start)
    }

    /// `rate` advanced by `seconds`, on its own timebase.
    private static func offsetTimecode(seconds: Double,
                                       from rate: Timecode) -> String {
        Timecode(frameNumber: rate.frameNumber
                     + frameOffset(seconds: seconds, at: rate),
                 fps: rate.fps, isDropFrame: rate.isDropFrame).description
    }

    /// Offset in seconds of a marker timecode inside a take — the inverse of
    /// `markerTimecode`. nil when the text is not a timecode at all.
    ///
    /// The result is frame-quantized, because the file's value is: a marker is
    /// one frame of the take, and both ends of the round trip land on the same
    /// frame from then on.
    public static func markerSeconds(timecodeText: String,
                                     start: Timecode?) -> Double? {
        let rate = start ?? fallbackRate
        guard let marker = Timecode(text: timecodeText, fps: rate.fps)
        else { return nil }
        var frames = marker.frameNumber - rate.frameNumber
        // A take that rolled through midnight ends on a SMALLER timecode than
        // it started on; without the wrap its markers land before the take.
        if frames < 0 {
            frames += Timecode.dayFrames(fps: rate.fps,
                                         isDropFrame: rate.isDropFrame)
        }
        return Double(frames) / realRate(of: rate)
    }

    /// The rows belonging to one take, resolved onto its own timebase and
    /// ordered. A row that cannot be resolved is dropped rather than silently
    /// landing on frame zero, under the head of every take.
    public static func markers(_ rows: [MarkerRow], of take: Take) -> [TakeMarker] {
        rows.compactMap { row -> TakeMarker? in
            if let seconds = markerSeconds(timecodeText: row.timecodeText,
                                           start: take.startTimecode),
               isInside(seconds: seconds, take) {
                return TakeMarker(seconds: seconds,
                                  timecodeText: row.timecodeText,
                                  color: row.color, note: row.note)
            }
            // an old file's Seconds column, for a marker whose timecode this
            // build cannot make sense of
            guard let seconds = row.legacySeconds else { return nil }
            return TakeMarker(seconds: seconds, color: row.color, note: row.note)
        }
        .sorted { $0.seconds < $1.seconds }
    }

    /// Whether a resolved position can belong to this take at all.
    ///
    /// Only asked of a take with NO start timecode, where the column is an
    /// offset by convention (see `markerTimecode`) and a sidecar written against
    /// a take that still had its timecode track resolves hours past the end. A
    /// take WITH a start timecode has a known anchor, so its arithmetic is not
    /// in doubt and a marker is kept even if the file has since been trimmed.
    ///
    /// The slack is a second, not a frame: those markers are positioned on the
    /// wall clock from the REC press, which starts before the first written
    /// frame, so one near the end can sit just past the file's duration. It is
    /// still four orders of magnitude short of the absolute timecode this
    /// rejects. A take whose duration could not be read has nothing to compare
    /// against and vetoes nothing.
    private static func isInside(seconds: Double, _ take: Take) -> Bool {
        guard take.startTimecode == nil, take.durationSeconds > 0 else { return true }
        return seconds <= take.durationSeconds + 1
    }

    /// Seconds → frames on a timecode's own timebase.
    static func frameOffset(seconds: Double, at rate: Timecode) -> Int {
        max(0, Int((seconds * realRate(of: rate)).rounded()))
    }

    /// Real frames per second behind a timecode's numbering: drop-frame runs at
    /// 1000/1001 of its nominal rate, so 30 DF is 29.97 real frames a second.
    static func realRate(of timecode: Timecode) -> Double {
        Double(max(1, timecode.fps)) * (timecode.isDropFrame ? 1000.0 / 1001.0 : 1)
    }

    /// Timebase assumed for a take with no start timecode (a manual take on a
    /// source that carries none) — the same 25 fps the duration field falls back
    /// to. Both ends of the sidecar use it, so the round trip is exact; only a
    /// timecode written by an older build against a different rate can land on a
    /// neighbouring frame.
    static let fallbackRate = Timecode(frameNumber: 0, fps: 25)
}
