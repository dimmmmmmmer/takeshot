import CaptureCore
import Foundation

/// Flagging the moment: the color the next marker is born with, dropping one at
/// the playhead, and taking one back.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more. Editing and navigating
/// the markers of the clip in the player is `+MarkerList`; the reports built
/// from them are `+Reports`.
extension CaptureController {
    /// The color the NEXT marker will be born with — the swatch in the marker
    /// controls. Colors used to be reachable only after a marker existed, so the
    /// convention had to be re-applied marker by marker.
    ///
    /// Reads through the palette rather than trusting the stored string: a
    /// hand-edited or downgraded settings blob must not put a color the palette
    /// has no swatch for onto every marker of the day.
    var newMarkerColor: String {
        get {
            let stored = settings.defaultMarkerColor
            return TakeMarker.colors.contains(stored ?? "")
                ? (stored ?? TakeMarker.colors[0]) : TakeMarker.colors[0]
        }
        set {
            // the default stays nil, so an untouched install writes no field
            settings.defaultMarkerColor =
                newValue == TakeMarker.colors[0] ? nil : newValue
        }
    }

    /// Advance the new-marker color by one — the swatch is a click-to-cycle
    /// control, the same as the per-marker swatch in the list (a menu on a 10pt
    /// label is unopenable).
    func cycleNewMarkerColor() {
        let palette = TakeMarker.colors
        let index = palette.firstIndex(of: newMarkerColor) ?? 0
        newMarkerColor = palette[(index + 1) % palette.count]
    }

    /// Flag the current moment: recording TC while recording, player position
    /// in playback. Lands in the takeshot-markers.csv sidecar (and EDL export).
    func addMarker() {
        if viewerMode == .playback, let url = playbackURL {
            // the same reading marker navigation and removal use — the engine
            // the position comes from is decided in one place
            let seconds = playbackPositionSeconds
            let tcText = playbackTimecodeText
            guard let index = takes.firstIndex(where: { $0.url == url }) else {
                lastError = L("marker_only_takes")
                return
            }
            // one marker per FRAME — close markers are legitimate for editing
            let frameStep = 1.0 / max(1, playbackFPS)
            guard !takes[index].markers.contains(
                where: { abs($0.seconds - seconds) < frameStep * 0.6 })
            else { return }
            takes[index].markers.append(
                TakeMarker(seconds: seconds, timecodeText: tcText,
                           color: newMarkerColor))
            takes[index].markers.sort { $0.seconds < $1.seconds }
            exportTakeLog()
            noticeAboutMarker(L("marker_added", tcText), color: newMarkerColor)
        } else if isRecording {
            let seconds = recordingStartDate.map { Date().timeIntervalSince($0) } ?? 0
            let fps = Double(max(1, live.currentTimecode?.fps ?? 25))
            guard !recordingMarkers.contains(
                where: { abs($0.seconds - seconds) < 0.6 / fps }) else { return }
            let tcText = live.currentTimecode?.description ?? ""
            recordingMarkers.append(
                TakeMarker(seconds: seconds, timecodeText: tcText,
                           color: newMarkerColor))
            noticeAboutMarker(L("marker_added", tcText), color: newMarkerColor)
        }
    }

    /// ⇧M: drop the marker under the playhead (±2 frames); while recording —
    /// the most recent one.
    func removeNearestMarker() {
        if viewerMode == .playback {
            let now = playbackPositionSeconds
            let tolerance = 2.0 / max(1, playbackFPS)
            guard let index = playbackMarkers.enumerated()
                .min(by: { abs($0.element.seconds - now)
                    < abs($1.element.seconds - now) })?.offset,
                abs(playbackMarkers[index].seconds - now) <= tolerance
            else { return }
            let marker = playbackMarkers[index]
            removePlaybackMarker(at: index)
            noticeAboutMarker(L("marker_removed", marker.timecodeText),
                              color: marker.color)
        } else if isRecording, let last = recordingMarkers.last {
            recordingMarkers.removeLast()
            noticeAboutMarker(L("marker_removed", last.timecodeText),
                              color: last.color)
        }
    }

    /// A toast that names ONE marker, shown in that marker's own color.
    ///
    /// The tint is assigned AFTER the text on purpose: `lastNotice`'s observer
    /// clears it, which is what stops a red marker's color from leaking onto the
    /// next, unrelated notice. Everything else keeps the neutral green.
    func noticeAboutMarker(_ text: String, color: String) {
        lastNotice = text
        lastNoticeTint = markerColor(color)
    }
}
