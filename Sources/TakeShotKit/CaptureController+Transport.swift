import AVFoundation
import CaptureCore
import Foundation

/// Transport actions that do not care which engine is playing.
///
/// A clip in the player is driven by one of two engines — AVPlayer through
/// `TransportModel`, or our own RAW engine (`RawPlayerModel`) for BRAW and
/// CinemaDNG — and each has a transport bar of its own that talks to it
/// directly. The menu bar cannot: it is one set of items for whatever happens to
/// be loaded. These route to the SAME methods the bars' buttons call; the
/// routing is the only thing that is new.
extension CaptureController {
    /// A clip is loaded and the app is showing it, rather than the live signal.
    /// What every transport item in the menu is enabled by. A sync-play grid
    /// counts: its master transport answers the same keys.
    var isReviewingClip: Bool {
        viewerMode == .playback && (playbackURL != nil || syncPlay != nil)
    }

    /// A clip is loaded in the SINGLE player — the grid does not count.
    ///
    /// What the items that act on one clip's own timeline are enabled by: the
    /// loop range and the markers. Both belong to a file, the grid has two to
    /// four of them and no loop at all, and both were reaching the single
    /// player parked underneath it: `toggleLoopPoint` refused outright
    /// (`guard syncPlay == nil`), `loopPlayback` and every marker item went
    /// through to whatever clip was last open — a marker written at the paused
    /// player's position, into a file the operator cannot see. Enabled and
    /// wrong is worse than grey, so the menus ask this instead.
    var isReviewingSingleClip: Bool {
        viewerMode == .playback && playbackURL != nil && syncPlay == nil
    }

    /// Which transport bar, if any, is drawn under the picture.
    enum TransportBarKind: Equatable {
        /// No bar: the live signal, a still, a sync-play grid, or a RAW clip
        /// the engine could not open.
        case none
        /// The AVPlayer transport — a video clip in the single player.
        case video
        /// The RAW engine's own bar: BRAW, R3D or a CinemaDNG folder.
        case raw
    }

    /// What is under the picture right now.
    ///
    /// One rule, because two surfaces need the answer and they used to ask
    /// different questions. `PreviewView` asked a careful one — video only, not
    /// a still, not RAW, not a grid — while the toast that has to clear the bar
    /// asked "is a clip loaded in playback", which is not the same question and
    /// is wrong for exactly the cases the careful one excludes: a still and a
    /// sync-play grid have no bar, and the toast floated 42 points above
    /// nothing over both. `PlayerToast` names the other half of that drift.
    ///
    /// A RAW clip the engine could NOT open gets no bar at all, which is the
    /// same reading `PreviewView.surfaceSource` already takes of it — what is
    /// on screen there is a "could not open" notice, and a transport under it
    /// would be driving whatever clip was open before.
    var transportBarKind: TransportBarKind {
        guard viewerMode == .playback, syncPlay == nil, let url = playbackURL
        else { return .none }
        if rawPlayer?.url == url { return .raw }
        let ext = url.pathExtension.lowercased()
        guard !Self.rawExtensions.contains(ext),
              !Self.imageExtensions.contains(ext) else { return .none }
        return .video
    }

    func togglePlayPause() {
        if let sync = syncPlay {
            sync.togglePlay()
        } else if let raw = rawPlayer {
            raw.togglePlay()
        } else {
            transport.togglePlay()
        }
    }

    /// Jump by `seconds`; negative goes back.
    func skipPlayback(bySeconds seconds: Double) {
        if let sync = syncPlay {
            sync.skip(bySeconds: seconds)
        } else if let raw = rawPlayer {
            raw.seek(to: raw.currentFrame
                + Int((seconds * raw.frameRate).rounded()))
        } else {
            transport.skip(seconds)
        }
    }

    /// One frame either way — how a focus or an eyeline is checked.
    func stepPlayback(forward: Bool) {
        let step = forward ? 1 : -1
        if let sync = syncPlay {
            sync.step(forward: forward)
        } else if let raw = rawPlayer {
            raw.seek(to: raw.currentFrame + step)
        } else {
            transport.skip(Double(step) / max(1, playbackFPS))
        }
    }

    /// Set or clear the loop in/out point at the playhead. Sync-play has no
    /// loop range — the guard keeps the key from marking the hidden single
    /// player's clip underneath the grid.
    func toggleLoopPoint(out: Bool) {
        guard syncPlay == nil else { return }
        if let raw = rawPlayer {
            raw.toggleRangePoint(out: out)
        } else {
            transport.toggleRangePoint(out: out)
        }
    }

    var loopPlayback: Bool {
        get { rawPlayer?.isLooping ?? transport.isLooping }
        set {
            if let raw = rawPlayer {
                raw.isLooping = newValue
            } else {
                transport.isLooping = newValue
            }
        }
    }

    /// Fullscreen the thing the operator is actually looking at: the clip in
    /// review, otherwise the live signal. Both are borderless windows of our
    /// own, not the green button (see `+Windows`).
    func toggleViewerFullscreen() {
        if isReviewingClip {
            togglePlaybackFullscreen()
        } else {
            toggleLiveFullscreen()
        }
    }
}
