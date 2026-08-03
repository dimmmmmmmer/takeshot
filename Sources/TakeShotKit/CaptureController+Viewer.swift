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
    func updateTapRunning() {
        // stills tick through the tap too (compare keeps the live half moving)
        let loaded = playbackURL != nil && rawPlayer == nil
        playbackTap.setRunning(viewerMode == .playback && loaded)
    }

    /// Any scope surface visible (drives the analyzers and the badge tint).
    var showScopes: Bool { showScopesOverlay || scopesWindowOpen }

    /// Route scope analysis to whichever source is actually on screen.
    func updateScopesRunning() {
        pipeline.setScopesEnabled(showScopes && viewerMode == .record)
        playbackTap.setScopesEnabled(showScopes && viewerMode == .playback)
        rawPlayer?.scopesEnabled = showScopes && viewerMode == .playback
        updateScopeRegion()
        rawPlayer?.refreshScopes()
        // scopeData is kept on close — reopening shows the last picture
        // immediately instead of flashing "waiting for signal"
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
