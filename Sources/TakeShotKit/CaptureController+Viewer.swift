import AppKit
import CaptureCore
import CoreVideo
import Foundation
import SwiftUI

/// The viewer surface itself: which source it shows, what keeps ticking for
/// it, and the aspect the framelines have to hug.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more.
extension CaptureController {
    enum ViewerMode: String, CaseIterable {
        case record
        case playback
    }

    var currentTimecode: Timecode? { live.currentTimecode }

    /// Flip between the live signal and the clip in the player — what the
    /// segmented switch over the player does, as a key.
    ///
    /// Unguarded, like that switch: going to playback with nothing loaded is a
    /// legal state the viewer already draws (an empty player with the takes
    /// panel to pick from), and refusing the key there would leave the operator
    /// pressing it at a picture that never changes.
    func toggleViewerMode() {
        viewerMode = viewerMode == .record ? .playback : .record
    }

    /// The viewer switched source. Everything that is fed per-frame has to be
    /// re-pointed at once — including the playout mirror, which is what the
    /// director is watching.
    func applyViewerModeChange() {
        if viewerMode == .record {
            player.pause()
            rawPlayer?.pause() // a looping BRAW decode must not fight capture
            endSyncPlay() // record mode shows the camera, not a comparison
        }
        updateAudioMonitorRouting()
        updateTapRunning()
        updateScopesRunning()
        wireDisplayMirrors()
    }

    /// Polling playback frames is only needed when the view is actually visible.
    ///
    /// A grid is the case where "in playback with a clip loaded" and "the single
    /// player's picture is on screen" come apart: `PreviewView` mounts
    /// `SyncPlayView` and leaves the shared `ViewerSurface` out of the tree
    /// entirely, so the tap was decoding, LUT-ing and compositing a parked take
    /// at 60 Hz into no sink at all. It is asked through `isReviewingSingleClip`
    /// so the reading cannot drift from the one the mount takes.
    func updateTapRunning() {
        // stills tick through the tap too (compare keeps the live half moving)
        playbackTap.setRunning(isReviewingSingleClip && rawPlayer == nil)
    }

    /// Any scope surface visible (drives the analyzers and the badge tint).
    var showScopes: Bool { showScopesOverlay || scopesWindowOpen }

    /// Scopes on, or off — the write side of `showScopes`.
    ///
    /// **Why this is a method and not three call sites toggling the overlay
    /// flag.** The badge over the player, the ⌃W key and the View menu's
    /// checkmark all LIT from `showScopes` (two surfaces) or from
    /// `showScopesOverlay` (the third) while all three WROTE the overlay flag —
    /// and the overlay is deliberately not drawn while the scopes window is open
    /// (`PlayerBadgesModifier.scopesOverlay`). So with the scopes on the cart's
    /// second monitor the badge read ON, pressing it changed nothing an operator
    /// could see, and it silently latched `showScopesOverlay = true`: the panel
    /// then jumped over the picture the moment that window was later closed,
    /// with nothing having asked for it.
    ///
    /// One decision, so the reading and the press cannot disagree: off means
    /// every scope surface off, including the window the operator opened —
    /// closing it is the literal meaning of the switch they just pressed.
    func toggleScopes() {
        guard showScopes else {
            showScopesOverlay = true
            return
        }
        showScopesOverlay = false
        if scopesWindowOpen {
            AppWindows.window(.scopes)?.performClose(nil)
        }
    }

    /// Route scope analysis to whichever source is actually on screen.
    ///
    /// **A grid is analyzed by nothing, and the last trace is dropped with it.**
    /// The two playback analyzers asked `viewerMode == .playback`, which is true
    /// over a grid — so with a waveform open the scopes went on measuring the
    /// PARKED take, at its paused frame, while four other takes were on screen.
    /// A readout that states another clip's timecode is a wrong number; a scope
    /// that states another clip's exposure is a wrong MEASUREMENT, and it is the
    /// one an operator judges a take by. Keeping the last trace is right when a
    /// panel closes over a picture that is still there and wrong here, where the
    /// picture it describes has gone — so `scopes.data` is cleared and the panel
    /// says it is waiting, which is the same answer `playbackTimecodeText` gives
    /// a grid.
    func updateScopesRunning() {
        let single = isReviewingSingleClip
        pipeline.setScopesEnabled(showScopes && viewerMode == .record)
        playbackTap.setScopesEnabled(showScopes && single)
        rawPlayer?.scopesEnabled = showScopes && single
        updateScopeRegion()
        rawPlayer?.refreshScopes()
        // scopeData is kept on close — reopening shows the last picture
        // immediately instead of flashing "waiting for signal"
        if syncPlay != nil { scopes.data = nil }
    }

    /// What the scopes analyze: the crop the viewer is showing.
    ///
    /// Punched in, the operator is judging the exposure of the magnified part
    /// of the frame — a full-frame waveform then answers a question nobody
    /// asked. Not punched in, this is the whole frame and costs nothing.
    var scopeRegion: ScopeRegion {
        ScopeRegion(assist: assist)
    }

    /// Push the punch-in crop to every analyzer. Called whenever the assists
    /// change (punch-in, pan) and when a scope surface opens.
    func updateScopeRegion() {
        let region = scopeRegion
        pipeline.setScopeRegion(region)
        playbackTap.setScopeRegion(region)
        // the RAW engine has no producer to piggyback on while paused, so a
        // moved crop is re-analyzed here — but only when it really moved
        if let raw = rawPlayer, raw.scopeRegion != region {
            raw.scopeRegion = region
            raw.refreshScopes()
        }
    }

    /// Aspect of the picture currently in the viewer, desqueeze included —
    /// the framelines box must hug the visible image.
    var displayAspect: CGFloat {
        let base: CGFloat
        if viewerMode == .playback, let aspect = playbackAspect {
            base = aspect
        } else if let format = signalFormat, format.height > 0 {
            base = CGFloat(format.width) / CGFloat(format.height)
        } else {
            base = 16.0 / 9.0
        }
        return base * CGFloat(assist.desqueeze)
    }
}
