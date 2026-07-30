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
    /// What every transport item in the menu is enabled by.
    var isReviewingClip: Bool {
        viewerMode == .playback && playbackURL != nil
    }

    func togglePlayPause() {
        if let raw = rawPlayer {
            raw.togglePlay()
        } else {
            transport.togglePlay()
        }
    }

    /// Jump by `seconds`; negative goes back.
    func skipPlayback(bySeconds seconds: Double) {
        if let raw = rawPlayer {
            raw.seek(to: raw.currentFrame
                + Int((seconds * raw.frameRate).rounded()))
        } else {
            transport.skip(seconds)
        }
    }

    /// One frame either way — how a focus or an eyeline is checked.
    func stepPlayback(forward: Bool) {
        let step = forward ? 1 : -1
        if let raw = rawPlayer {
            raw.seek(to: raw.currentFrame + step)
        } else {
            transport.skip(Double(step) / max(1, playbackFPS))
        }
    }

    /// Set or clear the loop in/out point at the playhead.
    func toggleLoopPoint(out: Bool) {
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
