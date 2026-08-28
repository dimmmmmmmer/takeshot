import CaptureCore
import CoreMedia
import Foundation

/// The markers of the clip in the player: the list editor's mutations, and
/// jumping between them.
///
/// Split out of `+Markers`: dropping a flag while the camera rolls and going
/// back through the flags afterwards are different jobs, and everything here is
/// about a clip that is already loaded.
extension CaptureController {
    /// Markers of the clip in the player (transport ticks).
    ///
    /// Two stores behind one property: a take carries its markers itself, and
    /// anything else in the record folder is keyed by file name in
    /// `otherMarkers`. Every caller in the app — the ticks, the list editor,
    /// navigation, the hotkeys — reads through here, so which store a clip
    /// belongs to is decided once.
    var playbackMarkers: [TakeMarker] {
        guard let url = playbackURL else { return [] }
        if let take = takes.first(where: { $0.url == url }) { return take.markers }
        return otherMarkers[Self.markerKey(url)] ?? []
    }

    /// There is a marker to go to, or to clear. What the three navigation items
    /// in the Markers menu are enabled by — one rule, three surfaces.
    var hasPlaybackMarkers: Bool { !playbackMarkers.isEmpty }

    /// A marker can be DROPPED: either a clip is under review in the single
    /// player or the camera is rolling. Both are timelines a flag belongs on;
    /// the sync-play grid is not one (see `isReviewingSingleClip`).
    var canDropMarker: Bool { isReviewingSingleClip || isRecording }

    /// The sidecar's key for a clip: its file name, the same one the ranges
    /// sidecar uses (`TransportModel.key`).
    nonisolated static func markerKey(_ url: URL) -> String {
        url.lastPathComponent
    }

    /// Whether the clip in the player can carry markers at all.
    ///
    /// A take always can. Anything else has to be a clip the folder scan found
    /// in the record folder — the sidecar is keyed by bare file name and lives
    /// beside the footage, so a file from somewhere else would file its markers
    /// under a name that means something different in that folder — and it has
    /// to have a timeline: a still is one frame, and one marker on frame zero of
    /// a photo is not a mark, it is a rating with extra steps.
    var playbackAcceptsMarkers: Bool {
        guard let url = playbackURL else { return false }
        if takes.contains(where: { $0.url == url }) { return true }
        guard otherFiles.contains(url) else { return false }
        return !Self.imageExtensions.contains(url.pathExtension.lowercased())
            || Self.isCinemaDNGFolder(url)
    }

    /// Apply `change` to whichever store owns the clip in the player, and file
    /// the result. `false` from the closure means "nothing moved" — the sidecar
    /// is only rewritten when something did.
    ///
    /// A foreign clip whose markers were all cleared keeps an EMPTY entry rather
    /// than losing its key. The export drops empty entries, and the scan's
    /// restore only fills keys it has never seen — so the empty entry is what
    /// stops the next scan, a minute later, from bringing back the markers the
    /// operator has just deleted.
    private func editPlaybackMarkers(
        _ change: (inout [TakeMarker]) -> Bool) {
        guard let url = playbackURL else { return }
        if let index = takes.firstIndex(where: { $0.url == url }) {
            guard change(&takes[index].markers) else { return }
        } else {
            var markers = otherMarkers[Self.markerKey(url)] ?? []
            guard change(&markers) else { return }
            otherMarkers[Self.markerKey(url)] = markers
        }
        exportTakeLog()
    }

    /// Current playback position in seconds (marker navigation).
    ///
    /// All three engines, through `playbackEngine`. The grid arm changes no
    /// behaviour today — every caller is gated to the single clip — and it is
    /// here so the property is not a trap for the next one: asked over a grid
    /// it used to answer the PARKED player's position, which is a plausible
    /// number about a file that is not on screen. That is the shape of every
    /// defect this rule was extracted for, and leaving one more of them lying
    /// about because nothing currently steps on it is how the last one
    /// survived a wave that had already named it.
    var playbackPositionSeconds: Double {
        switch playbackEngine {
        case .grid:
            // the master timeline the grid's own transport shows
            return syncPlay?.position.currentTime ?? 0
        case .raw:
            guard let raw = rawPlayer else { return 0 }
            return Double(raw.currentFrame) / max(1, raw.frameRate)
        case .single:
            return max(0, player.currentTime().seconds)
        }
    }

    /// Mutate a marker of the current playback clip (list editor).
    func updatePlaybackMarker(at index: Int,
                              _ change: (inout TakeMarker) -> Void) {
        editPlaybackMarkers { markers in
            guard markers.indices.contains(index) else { return false }
            change(&markers[index])
            return true
        }
    }
    func removePlaybackMarker(at index: Int) {
        editPlaybackMarkers { markers in
            guard markers.indices.contains(index) else { return false }
            markers.remove(at: index)
            return true
        }
    }
    func clearPlaybackMarkers() {
        editPlaybackMarkers { markers in
            guard !markers.isEmpty else { return false }
            markers.removeAll()
            return true
        }
    }
    /// Add one marker to whichever store owns the clip in the player, keeping
    /// the list in position order. `false` means the frame already carries one.
    func appendPlaybackMarker(_ marker: TakeMarker, frameStep: Double) -> Bool {
        var placed = false
        editPlaybackMarkers { markers in
            guard !markers.contains(where: {
                abs($0.seconds - marker.seconds) < frameStep * 0.6
            }) else { return false }
            markers.append(marker)
            markers.sort { $0.seconds < $1.seconds }
            placed = true
            return true
        }
        return placed
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
}
