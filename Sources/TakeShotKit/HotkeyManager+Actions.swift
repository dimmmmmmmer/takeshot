import AppKit
import Foundation

/// What a bound key actually does.
///
/// Split out of `HotkeyManager`: storing and intercepting a combo is one job,
/// and the fan-out below is another. Every arm calls the controller method the
/// on-screen button calls — there is no second implementation of anything here,
/// which is what keeps a key and its button from drifting apart.
extension HotkeyManager {
    /// Actions on the recording and the take list.
    func perform(_ action: HotkeyAction, controller: CaptureController) {
        switch action {
        case .toggleRecord:
            if controller.isCapturing { controller.toggleManualRecord() }
        case .circleLastTake:
            controller.toggleLastRating(.good)
        case .badTakeLast:
            controller.toggleLastRating(.bad)
        case .grabFrame:
            controller.grabFrame()
        case .instantReplay:
            controller.instantReplay()
        case .fullscreen, .addMarker, .removeMarker, .punchIn,
             .toggleScopesOverlay, .toggleLUTPreview, .toggleViewerMode,
             .toggleCleanFeed:
            performViewer(action, controller: controller)
        case .resetAssists, .toggleAssistsHidden:
            performAssists(action, controller: controller)
        case .toggleMonitorMute, .toggleMonitorDim, .toggleAudioChannelBank:
            performMonitoring(action, controller: controller)
        case .shuttleReverse, .shuttleStop, .shuttleForward,
             .stepBackOneFrame, .stepForwardOneFrame,
             .stepBackFiveFrames, .stepForwardFiveFrames,
             .goToClipStart, .goToClipEnd:
            performTransport(action, controller: controller)
        }
    }

    /// **The transport keys** — J-K-L, the arrows, and the two edges.
    ///
    /// Every arm calls the same controller method the bar's own buttons call,
    /// which is this file's rule and is what keeps a key and a button from
    /// drifting apart. The controller is where each engine's answer lives:
    /// only the single player can shuttle, and the other two say so by
    /// stepping instead of pretending.
    private func performTransport(_ action: HotkeyAction,
                                  controller: CaptureController) {
        switch action {
        case .shuttleReverse: controller.shuttlePlayback(forward: false)
        case .shuttleStop: controller.stopShuttle()
        case .shuttleForward: controller.shuttlePlayback(forward: true)
        case .stepBackOneFrame: controller.stepPlayback(byFrames: -1)
        case .stepForwardOneFrame: controller.stepPlayback(byFrames: 1)
        case .stepBackFiveFrames:
            controller.stepPlayback(byFrames: -CaptureController.frameJump)
        case .stepForwardFiveFrames:
            controller.stepPlayback(byFrames: CaptureController.frameJump)
        case .goToClipStart: controller.goToPlaybackEdge(end: false)
        case .goToClipEnd: controller.goToPlaybackEdge(end: true)
        default: break
        }
    }

    /// **The two keys the assist popover owns**: everything back to how it
    /// ships, and the aids off the picture without being forgotten.
    ///
    /// Their own arm rather than two more cases in the viewer's fan-out, which
    /// is at the complexity ceiling — and they are a pair with one subject
    /// between them, which is what an arm is for.
    private func performAssists(_ action: HotkeyAction,
                                controller: CaptureController) {
        switch action {
        case .resetAssists: controller.resetAssists()
        case .toggleAssistsHidden: controller.toggleAssistsHidden()
        default: break
        }
    }

    /// Actions on the viewer itself (fullscreen, markers, punch-in, the scopes
    /// overlay, the preview LUT and the rec/playback switch).
    private func performViewer(_ action: HotkeyAction,
                               controller: CaptureController) {
        switch action {
        case .fullscreen:
            // one implementation, shared with the View menu's item
            controller.toggleViewerFullscreen()
        case .addMarker:
            controller.addMarker()
        case .removeMarker:
            controller.removeNearestMarker()
        case .punchIn:
            controller.togglePunchIn()
        case .toggleScopesOverlay:
            // the flag the View menu's toggle writes; its didSet closes the
            // other player overlay and re-routes the analyzers
            controller.toggleScopes()
        case .toggleLUTPreview:
            // the condition the LUT menu's item is disabled by: with no LUT
            // selected there is nothing to apply, and a state that shows as
            // "LUT on" with no LUT reads as the LUT being broken
            if controller.canApplyLUT {
                controller.lutPreviewOn.toggle()
            }
        case .toggleViewerMode:
            controller.toggleViewerMode()
        case .toggleCleanFeed:
            controller.toggleCleanFeed()
        default:
            break // handled by perform(_:controller:)
        }
    }

    /// Actions on what the operator hears and on what gets recorded of it.
    private func performMonitoring(_ action: HotkeyAction,
                                   controller: CaptureController) {
        switch action {
        case .toggleMonitorMute:
            // Deliberately UNGATED, and the only one here that is — the footer's
            // speaker greys with no capture and no clip, this does not. The
            // argument is written out at the menu bar's item, which makes the
            // same choice for the same reason: "kill the sound NOW" is what a
            // key and a status item are for when the window is closed. Stated
            // here too because a bare call between two guarded neighbours reads
            // as an oversight, and has now been reported as one.
            controller.toggleMonitorMute()
        case .toggleMonitorDim:
            // the condition the footer's DIM button is disabled by — a dim that
            // is holding nothing down would lie about the level
            if controller.canDimMonitoring { controller.toggleMonitorDim() }
        case .toggleAudioChannelBank:
            // the recording latch lives in the controller method, so the key and
            // the panel's channel columns refuse mid-take for the same reason
            controller.toggleAudioChannelBank()
        default:
            break // handled by perform(_:controller:)
        }
    }
}
