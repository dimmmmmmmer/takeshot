import CaptureCore
import CoreGraphics
import Foundation
import SwiftUI

/// The aids exactly as the preview surfaces are showing them — the published
/// controller state plus whatever a slider or a zoom gesture has changed since.
///
/// Its own observable object for the reason `LiveSignal` is one: the overlays
/// that draw framelines and safe areas have to follow a pan frame by frame, and
/// publishing that on the controller re-lays out every view in the window per
/// tick. Here it re-renders the overlay and the popover, and nothing else.
@MainActor
final class AssistLiveState: ObservableObject {
    @Published private(set) var assist = ViewAssist()
    /// A value is on screen that the controller has not published yet.
    private(set) var hasDraft = false

    /// A slider tick or a gesture event: on screen now, published later.
    func preview(_ value: ViewAssist) {
        hasDraft = true
        assist = value
    }

    /// The controller published a value — the draft is folded in or superseded.
    func settle(_ value: ViewAssist) {
        hasDraft = false
        if assist != value { assist = value }
    }
}

/// The operator aids that are dragged rather than clicked: the zebra and
/// peaking sliders, and the punch-in level and pan the zoom gestures drive.
///
/// They all share one problem. `assist` is @Published, so a write per drag tick
/// re-lays out every view observing the controller — the whole window — which is
/// the lag the LUT intensity slider had (see `lutIntensity` in +LUT) and the
/// volume slider before it (`setVolume` in +Audio). The cure is the same:
/// the value reaches every preview surface immediately (a redraw, not a filter
/// rebuild) and is folded into the published state once the gesture settles.
extension CaptureController {
    /// Debounce window. Long enough that a drag or a pinch publishes once, short
    /// enough that the popover's own controls catch up before the operator can
    /// look away from them.
    static let assistDebounce: Duration = .milliseconds(250)

    /// The aids as they are ON SCREEN right now: the pending draft while a
    /// gesture or a slider is mid-flight, else the published state. Anything
    /// that changes a value relative to itself (a pinch, a pan) has to read it
    /// from here or it steps off a stale number.
    var liveAssist: ViewAssist {
        assistLive.hasDraft ? assistLive.assist : assist
    }

    /// Apply an aid change to every surface now, publish it later.
    func applyAssistPreview(_ change: (inout ViewAssist) -> Void) {
        let current = liveAssist
        var draft = current
        change(&draft)
        // an unchanged value must not restart the debounce and must not cost a
        // GPU pass: a pinch held at the magnification limit is all of these
        guard draft != current else { return }
        assistLive.preview(draft)
        pipeline.setViewAssist(draft)
        playbackTap.setViewAssist(draft)
        rawPlayer?.setViewAssist(draft)
        assistPersistTask?.cancel()
        assistPersistTask = Task { [weak self] in
            try? await Task.sleep(for: Self.assistDebounce)
            guard !Task.isCancelled, let self else { return }
            self.commitAssistDraft()
        }
    }

    /// Fold the draft into the published state — one re-render per gesture.
    func commitAssistDraft() {
        guard assistLive.hasDraft else { return }
        assist = assistLive.assist // didSet settles the draft and cancels the task
    }

    /// Change an aid that is CLICKED (a toggle, a picker): published at once,
    /// but any dragged value still on screen is folded in first — otherwise the
    /// click would throw away the slider the operator has just let go of.
    func setAssist(_ change: (inout ViewAssist) -> Void) {
        commitAssistDraft()
        var value = assist
        change(&value)
        assist = value
    }

    // MARK: - the dragged aids

    /// Zebra trigger level (0.70…1.0 of full scale).
    var zebraThreshold: Double {
        get { liveAssist.zebraThreshold }
        set {
            applyAssistPreview { $0.zebraThreshold = min(1, max(0.7, newValue)) }
        }
    }

    /// Focus-peaking edge gain.
    var peakingIntensity: Double {
        get { liveAssist.peakingIntensity }
        set {
            applyAssistPreview { $0.peakingIntensity = min(30, max(2, newValue)) }
        }
    }

    // MARK: - zoom and pan

    /// Punch-in magnification, fine-grained (the picker used to offer 2x and 4x
    /// and nothing between). Continuous on purpose: a pinch accumulates tiny
    /// relative deltas, and rounding the stored value would swallow each of them
    /// whole. The readout rounds for display instead.
    var punchInLevel: Double {
        get { liveAssist.punchIn }
        set {
            applyAssistPreview { $0.setPunchIn(newValue) }
        }
    }

    /// A trackpad pinch: `factor` is relative (1 = no change).
    func magnifyPunchIn(by factor: Double) {
        applyAssistPreview { $0.magnify(by: factor) }
    }

    /// Pan the punched-in image by a distance in POINTS on a `viewport`-sized
    /// surface, in view coordinates (y down). Positive `delta` drags the picture
    /// right/down, the way a hand on the image would.
    ///
    /// The translation is converted through the placement the renderer uses, so
    /// the picture keeps up with the pointer exactly instead of through the
    /// invented constant the drag gesture used to divide by.
    func panPunchIn(by delta: CGSize, viewport: CGSize) {
        let current = liveAssist
        guard current.punchIn > 1,
              let placed = current.placement(sourceSize: displaySourceSize(),
                                             in: viewport),
              placed.rect.width > 0, placed.rect.height > 0 else { return }
        applyAssistPreview {
            $0.pan(by: CGSize(width: -delta.width / placed.rect.width,
                              height: -delta.height / placed.rect.height))
        }
    }

    /// A source-shaped size for the placement math: the aspect is all the
    /// overlays and the pan need, and `displayAspect` already carries the
    /// desqueeze the renderer applies before it fits the picture.
    func displaySourceSize() -> CGSize {
        CGSize(width: max(0.01, displayAspect), height: 1)
    }

    /// Whether the pointer over the preview should read as a grab handle.
    var isPunchedIn: Bool { liveAssist.punchIn > 1 }

    // MARK: - the legend

    var legendSize: AssistLegendSize {
        get { AssistLegendSize(rawValue: settings.legendSize ?? "") ?? .medium }
        set { settings.legendSize = newValue == .medium ? nil : newValue.rawValue }
    }

    var legendCorner: AssistLegendCorner {
        get {
            AssistLegendCorner(rawValue: settings.legendCorner ?? "")
                ?? .bottomTrailing
        }
        set {
            settings.legendCorner = newValue == .bottomTrailing
                ? nil : newValue.rawValue
        }
    }
}
