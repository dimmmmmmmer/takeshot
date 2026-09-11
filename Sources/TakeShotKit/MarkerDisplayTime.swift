import CaptureCore

/// **What a marker's time reads as on screen** — which is not always what the
/// sidecar stores, and the difference is deliberate.
///
/// A marker on a TAKE carries an absolute timecode: the take's start is known,
/// is written into the sidecar, and is what an editor matches against. A
/// marker on a clip that is NOT a take carries an offset from that clip's own
/// zero, because the sidecar has no anchor to hang an absolute time on — write
/// one and the next read resolves it to twelve hours into a four-second clip
/// and drops it (`TakeLogExporter.markerSeconds`).
///
/// That is right for the FILE and was wrong on the screen: the list printed
/// the stored text, so a row said 00:00:02:03 while the badge over the same
/// picture, counting the clip's own timecode track, said 12:19:57:13 — two
/// answers about one moment, side by side (owner: "посмотри на таймкоды тейка
/// и таймкоды маркера").
///
/// So the file keeps the offset and the screen adds the clip's own start. One
/// function, because three surfaces ask — the list, the toast when a marker is
/// dropped, and the one that says which marker was removed.
enum MarkerDisplayTime {
    /// `clipStart` is the timecode the transport is counting from, or nil for
    /// a clip that has none. `isTake` says the stored text is already absolute.
    static func text(for marker: TakeMarker, clipStart: Timecode?,
                     isTake: Bool) -> String {
        if isTake || clipStart == nil {
            return marker.timecodeText.isEmpty
                ? ClipTimeText.minutesSeconds.text(marker.seconds)
                : marker.timecodeText
        }
        // A fresh marker carrying only the position: `markerTimecode` returns
        // a non-empty stored text unchanged, and the stored text is exactly
        // the offset this is replacing.
        return TakeLogExporter.markerTimecode(
            of: TakeMarker(seconds: marker.seconds), startingAt: clipStart)
    }
}
