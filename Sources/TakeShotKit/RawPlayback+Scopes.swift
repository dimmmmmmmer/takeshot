import CaptureCore
import CoreVideo
import Foundation

/// The RAW engine's scope path.
///
/// It is the odd one out: the capture pipeline and the playback tap both have a
/// producer queue to hand a frame off from, while a RAW clip is decoded by a
/// task per frame and spends most of its life paused on one. So the cadence is
/// counted in decoded frames, and a paused clip is re-analyzed on demand.
extension RawPlayerModel {
    /// Scope passes per second the decode loop aims for. Lower than the live and
    /// AVPlayer paths' 15: those hand the frame to a queue of its own, while here
    /// the analysis rides on the decode task itself and every pass is a frame the
    /// decoder does not get to work on.
    static let scopeUpdatesPerSecond = 8.0

    /// Decoded frames between scope passes at a given clip frame rate — a rate
    /// target rather than a fixed count, so a 24 fps clip and a 60 fps one
    /// update the scopes equally often.
    static func scopeFrameStride(atFrameRate frameRate: Double) -> Int {
        max(1, Int((frameRate / scopeUpdatesPerSecond).rounded()))
    }

    /// Decoded frames between scope passes for this clip.
    var scopeFrameStride: Int {
        Self.scopeFrameStride(atFrameRate: frameRate)
    }

    /// Re-analyze the frame that is already on screen. A paused clip decodes
    /// nothing new, so a scope surface that just opened — or a punch-in that
    /// just moved — would otherwise keep showing the previous crop until
    /// playback resumed.
    ///
    /// Latest-wins, like every other scope path: a pan drag asks for this 60
    /// times a second and each pass is a whole frame of analysis. The request
    /// that arrives while a pass is running is REMEMBERED, not dropped — it is
    /// the last one, the crop the operator settled on, and on a paused clip
    /// nothing else would ever come along to correct it.
    func refreshScopes() {
        guard scopesEnabled, let buffer = lastBuffer else { return }
        guard !scopeRefreshing else {
            scopeRefreshPending = true
            return
        }
        scopeRefreshing = true
        let region = scopeRegion
        let boxed = UncheckedSendable(buffer)
        Task.detached(priority: .userInitiated) { [weak self] in
            let data = ScopeAnalyzer.analyze(boxed.value, region: region)
            guard let model = self else { return }
            await MainActor.run {
                model.scopeRefreshing = false
                if let data { model.onScopeData?(data) }
                if model.scopeRefreshPending {
                    model.scopeRefreshPending = false
                    model.refreshScopes()
                }
            }
        }
    }
}
