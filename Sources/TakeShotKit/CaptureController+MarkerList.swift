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
    var playbackMarkers: [TakeMarker] {
        guard let url = playbackURL else { return [] }
        return takes.first { $0.url == url }?.markers ?? []
    }

    /// Current playback position in seconds (marker navigation).
    var playbackPositionSeconds: Double {
        if let raw = rawPlayer {
            return Double(raw.currentFrame) / max(1, raw.frameRate)
        }
        return max(0, player.currentTime().seconds)
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
}
