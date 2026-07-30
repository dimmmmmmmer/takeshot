import CaptureCore
import CoreVideo
import Foundation

/// Scope analysis of what the player is actually showing.
///
/// Split out of `+Compose`: the composite is one job and measuring it is
/// another, and this one is entirely about a queue discipline the composite
/// does not share — the analyzer must never run on the queue that polls the
/// player.
extension PlaybackFrameTap {
    /// Hand the composed frame to the analyzer on its own queue.
    ///
    /// It used to run inline, on the render queue that polls the player at
    /// 60 Hz: one 1080p pass held that queue for over a hundred milliseconds on
    /// noisy content, so the picture juddered exactly while the operator was
    /// watching the scopes. Latest-wins, like the capture pipeline's: a frame
    /// offered while a pass is in flight is dropped, never queued.
    func analyzeScopes(of buffer: CVPixelBuffer) {
        guard !scopeBusy else { return }
        scopeBusy = true
        let region = scopeRegion
        scopeQueue.async { [weak self] in
            let data = ScopeAnalyzer.analyze(buffer, region: region)
            guard let tap = self else { return }
            tap.queue.async {
                tap.scopeBusy = false
                // whatever asked for a re-read while this pass ran gets it now
                if tap.scopeReanalysisPending {
                    tap.scopeReanalysisPending = false
                    tap.reanalyzeCurrentFrame()
                }
            }
            guard let data else { return }
            DispatchQueue.main.async { tap.onScopeData?(data) }
        }
    }

    /// Re-read the frame that is already on screen: the punch-in crop moved, or
    /// a scope surface just opened, and a paused clip pushes nothing new.
    ///
    /// Unlike a frame from the tick this request is never simply dropped. A pan
    /// drag asks for it ~60 times a second and each pass takes several of those
    /// ticks, so the LAST request — the crop the operator settled on — is the
    /// one most likely to arrive while a pass is in flight. Dropping it left the
    /// scopes measuring the previous crop until playback resumed, which for a
    /// paused take under review is never. Latest-wins means the last request
    /// wins, not that it is lost.
    ///
    /// Call on `queue`.
    func reanalyzeCurrentFrame() {
        guard scopesEnabled, let buffer = lastBuffer else { return }
        guard !scopeBusy else {
            scopeReanalysisPending = true
            return
        }
        // via deliver, so the scopes see the same composed output as the screen
        deliver(buffer, analyzed: true)
    }
}
