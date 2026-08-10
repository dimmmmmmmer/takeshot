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
             .toggleScopesOverlay, .toggleLUTPreview, .toggleViewerMode:
            performViewer(action, controller: controller)
        case .toggleMonitorMute, .toggleMonitorDim, .toggleAudioChannelBank:
            performMonitoring(action, controller: controller)
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
        default:
            break // handled by perform(_:controller:)
        }
    }

    /// Actions on what the operator hears and on what gets recorded of it.
    private func performMonitoring(_ action: HotkeyAction,
                                   controller: CaptureController) {
        switch action {
        case .toggleMonitorMute:
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
