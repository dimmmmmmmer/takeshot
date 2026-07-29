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
        // scopeData is kept on close — reopening shows the last picture
        // immediately instead of flashing "waiting for signal"
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
