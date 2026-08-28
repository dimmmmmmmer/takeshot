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
            let stored = settings.review.defaultMarkerColor
            return TakeMarker.colors.contains(stored ?? "")
                ? (stored ?? TakeMarker.colors[0]) : TakeMarker.colors[0]
        }
        set {
            // the default stays nil, so an untouched install writes no field
            settings.review.defaultMarkerColor =
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
    ///
    /// In review this works on ANY clip the record folder holds, not only on our
    /// own takes. The marker controls sit in the transport, the transport runs
    /// for whatever is loaded, and a clip copied off a card is exactly the kind
    /// of thing somebody wants to flag a moment in — the operator pressing the
    /// flag on one and getting an error toast was the report. What a foreign
    /// clip has instead of a `Take` is a row in `otherMarkers` under its file
    /// name; the sidecar has always been keyed that way (see
    /// `CaptureController+MarkerList`).
    ///
    /// **The review arm asks `isReviewingSingleClip`, not the viewer mode.**
    /// `canDropMarker` — what the Markers menu is enabled by — has said since
    /// the long-tail wave that "the sync-play grid is not [a timeline a flag
    /// belongs on]", and that fix reached the MENU ITEM and never the method.
    /// The two surfaces that call this without going through the menu are the
    /// hotkey (`HotkeyManager+Actions`) and the phone
    /// (`perform(remote:)` — `.marker`), and both still landed a marker in the
    /// take the single player is PARKED on while a grid is up: a flag written
    /// into a file the operator cannot see, at a position that is not the one
    /// on screen, and `playbackAcceptsMarkers` cannot catch it because
    /// `startSyncPlay` leaves `playbackURL` exactly where it was.
    ///
    /// Over a grid with the camera rolling it falls through to the recording
    /// arm, which is the other half of `canDropMarker` and is a real timeline.
    /// Over a grid with nothing rolling it does nothing and says nothing —
    /// matching the greyed menu item, the same way the record hotkey is silent
    /// with no capture running.
    func addMarker() {
        if isReviewingSingleClip, let url = playbackURL {
            // the same reading marker navigation and removal use — the engine
            // the position comes from is decided in one place
            let seconds = playbackPositionSeconds
            guard playbackAcceptsMarkers else {
                lastError = L("marker_needs_clip")
                return
            }
            let tcText = markerTimecodeText(at: seconds, of: url)
            // one marker per FRAME — close markers are legitimate for editing
            guard appendPlaybackMarker(
                TakeMarker(seconds: seconds, timecodeText: tcText,
                           color: newMarkerColor),
                frameStep: 1.0 / max(1, playbackFPS))
            else { return }
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

    /// The timecode text a marker placed at `seconds` is born with.
    ///
    /// A take gets what the player's own readout says — its start timecode is
    /// known, is written into the sidecar, and is what the editor matches
    /// against. A clip that is NOT a take gets an offset from its own zero,
    /// derived exactly as the sidecar will derive it.
    ///
    /// The player badge may well be showing that clip's absolute camera
    /// timecode; taking it would put a value in the list that the file cannot
    /// hold — a non-take has no anchor stored anywhere, so its rows are offsets
    /// (see `TakeLogExporter.markerTimecode(of:startingAt:)`). Written as the
    /// camera's absolute time it would read back hours past the end of the clip,
    /// and taken as-is only in memory it would silently become an offset the
    /// first time the app was relaunched.
    private func markerTimecodeText(at seconds: Double, of url: URL) -> String {
        guard !takes.contains(where: { $0.url == url }) else {
            return playbackTimecodeText
        }
        return TakeLogExporter.markerTimecode(of: TakeMarker(seconds: seconds),
                                              startingAt: nil)
    }

    /// ⇧M: drop the marker under the playhead (±2 frames); while recording —
    /// the most recent one.
    ///
    /// Same guard as `addMarker`, and this is the half that DELETES. Over a
    /// sync-play grid the old `viewerMode == .playback` read the parked
    /// player's position and the parked take's marker list, so the press
    /// removed a marker from a file that is not on screen — and the ±2 frame
    /// reach makes it reachable rather than theoretical: an operator who marks
    /// a moment, then selects that take and three others to compare, has left
    /// the playhead exactly on the marker they just placed.
    func removeNearestMarker() {
        if isReviewingSingleClip {
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
