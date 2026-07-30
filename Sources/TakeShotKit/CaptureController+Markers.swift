import AVFoundation
import AppKit
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import os.log

/// Take markers and the reports built from them (selects EDL, shift report).
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more.
extension CaptureController {
    /// Markers of the clip in the player (transport ticks).
    var playbackMarkers: [TakeMarker] {
        guard let url = playbackURL else { return [] }
        return takes.first { $0.url == url }?.markers ?? []
    }

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

    /// Current playback position in seconds (marker navigation).
    var playbackPositionSeconds: Double {
        if let raw = rawPlayer {
            return Double(raw.currentFrame) / max(1, raw.frameRate)
        }
        return max(0, player.currentTime().seconds)
    }

    /// Flag the current moment: recording TC while recording, player position
    /// in playback. Lands in the takeshot-markers.csv sidecar (and EDL export).
    func addMarker() {
        if viewerMode == .playback, let url = playbackURL {
            let seconds: Double
            if let raw = rawPlayer {
                seconds = Double(raw.currentFrame) / max(1, raw.frameRate)
            } else {
                seconds = max(0, player.currentTime().seconds)
            }
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

    /// A toast that names ONE marker, shown in that marker's own color.
    ///
    /// The tint is assigned AFTER the text on purpose: `lastNotice`'s observer
    /// clears it, which is what stops a red marker's color from leaking onto the
    /// next, unrelated notice. Everything else keeps the neutral green.
    func noticeAboutMarker(_ text: String, color: String) {
        lastNotice = text
        lastNoticeTint = markerColor(color)
    }
    /// Mutate a marker of the current playback clip (list editor).
    func updatePlaybackMarker(at index: Int,
                              _ change: (inout TakeMarker) -> Void) {
        guard let url = playbackURL,
              let takeIndex = takes.firstIndex(where: { $0.url == url }),
              takes[takeIndex].markers.indices.contains(index) else { return }
        change(&takes[takeIndex].markers[index])
        exportTakeLog()
    }
    func removePlaybackMarker(at index: Int) {
        guard let url = playbackURL,
              let takeIndex = takes.firstIndex(where: { $0.url == url }),
              takes[takeIndex].markers.indices.contains(index) else { return }
        takes[takeIndex].markers.remove(at: index)
        exportTakeLog()
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
    func clearPlaybackMarkers() {
        guard let url = playbackURL,
              let takeIndex = takes.firstIndex(where: { $0.url == url })
        else { return }
        takes[takeIndex].markers.removeAll()
        exportTakeLog()
    }
    /// Jump to the next/previous marker of the current clip.
    func jumpToMarker(forward: Bool) {
        let markers = playbackMarkers
        guard !markers.isEmpty else { return }
        let now = playbackPositionSeconds
        let index = forward
            ? markers.firstIndex { $0.seconds > now + 0.05 }
            : markers.lastIndex { $0.seconds < now - 0.05 }
        guard let index else { return }
        let marker = markers[index]
        seekPlayback(to: marker.seconds)
        let name = marker.note.isEmpty ? L("marker_n", index + 1) : marker.note
        noticeAboutMarker("⚑ \(name) — \(marker.timecodeText)",
                          color: marker.color)
    }
    /// Jump the player (AVPlayer or RAW) to a position in seconds.
    func seekPlayback(to seconds: Double) {
        if let raw = rawPlayer {
            raw.seek(to: Int((seconds * raw.frameRate).rounded()))
        } else {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
    /// Selects EDL: good takes back to back, markers as Resolve locators.
    func exportSelectsEDL() {
        let good = takes.filter { $0.rating == .good }
        guard let edl = EDLExporter.selectsEDL(
            takes: good, title: "\(settings.projectName) selects",
            fps: Int(max(1, playbackFPS).rounded()))
        else {
            lastError = L("edl_no_good_takes")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = NamingEngine.sanitize(
            "\(settings.projectName)_selects") + ".edl"
        panel.directoryURL = destinationRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try edl.write(to: url, atomically: true, encoding: .utf8)
            lastNotice = L("edl_saved", url.lastPathComponent)
        } catch {
            lastError = "EDL: \(error.localizedDescription)"
        }
    }
    /// Shift report: A4 PDF with thumbnails or a full CSV table.
    func exportShiftReport(pdf: Bool) {
        guard !takes.isEmpty else {
            lastError = L("report_no_takes")
            return
        }
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyMMdd"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        panel.nameFieldStringValue = NamingEngine.sanitize(
            "\(settings.projectName)_report_\(stamp.string(from: Date()))")
            + (pdf ? ".pdf" : ".csv")
        panel.directoryURL = destinationRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if pdf {
                guard let data = ShiftReport.pdfData(
                    takes: takes, thumbnails: thumbnails,
                    project: settings.projectName,
                    camera: settings.cameraLabel) else {
                    lastError = "PDF render failed"
                    return
                }
                try data.write(to: url)
            } else {
                try TakeLogExporter.reportCSV(takes: takes)
                    .write(to: url, atomically: true, encoding: .utf8)
            }
            lastNotice = L("report_saved", url.lastPathComponent)
        } catch {
            lastError = "Report: \(error.localizedDescription)"
        }
    }
}
