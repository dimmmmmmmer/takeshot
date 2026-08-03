import CaptureCore
import CoreVideo
import Foundation

/// The RAW engine's transport: what the buttons under the player do.
///
/// Split out of `RawPlayback.swift` — the operator's controls and the
/// decode/present loop they start (`RawPlayback+PlayLoop`) are separate jobs,
/// and only the loop has to reason about generations and cancellation.
extension RawPlayerModel {
    /// Set/clear the in or out point at the playhead (same semantics as the
    /// AVPlayer transport: clicking near an existing point clears it).
    func toggleRangePoint(out: Bool) {
        let before = (inFrame, outFrame)
        let now = currentFrame
        if out {
            if let existing = outFrame, abs(existing - now) < 2 {
                outFrame = nil
            } else {
                outFrame = now
                if let inF = inFrame, inF >= now { inFrame = nil }
            }
        } else {
            if let existing = inFrame, abs(existing - now) < 2 {
                inFrame = nil
            } else {
                inFrame = now
                if let outF = outFrame, outF <= now { outFrame = nil }
            }
        }
        // This engine is thrown away and rebuilt for every clip, so its range is
        // normally filed with the controller only on the way out. That is too late
        // to survive a quit with the clip still open — hence a report on the spot.
        guard (inFrame, outFrame) != before else { return }
        onRangeChanged?()
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        startPlaying(at: startOfPlayback())
    }

    /// Begin the decode loop at an exact frame, whatever the range says — how a
    /// scrub that lands outside the range resumes where the operator dropped it
    /// instead of snapping back to the in point under their hand.
    func startPlaying(at frame: Int) {
        guard !isPlaying, frameCount > 0 else { return }
        // A new attempt clears the last failure: the operator pressing play is
        // asking again, and a stale message beside a running picture is worse
        // than none.
        playbackError = nil
        isPlaying = true
        playGeneration += 1
        let generation = playGeneration
        let startFrame = min(max(0, frame), max(0, frameCount - 1))
        currentFrame = startFrame
        playTask = makePlayTask(startFrame: startFrame, generation: generation)
    }

    /// Which frame playback begins on.
    ///
    /// The engine's half of owner item 38, and the same bug the AVPlayer
    /// transport had: the loop was enforced at the OUT point only (see
    /// `makePlayTask`), so a clip opened with an in point marked on it played
    /// the whole lead-in and started looping when it arrived. Playback belongs
    /// inside the range from the first frame — hit play before the in point, or
    /// at or past the out point, and it starts at the in point.
    func startOfPlayback() -> Int {
        let floorFrame = min(max(0, inFrame ?? 0), max(0, frameCount - 1))
        let position = max(currentFrame, 0)
        if position >= frameCount - 1 { return floorFrame }
        if let outFrame, position >= outFrame { return floorFrame }
        return max(position, floorFrame)
    }

    func pause() {
        playGeneration += 1 // orphan any loop parked in a blocking decode
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }

    /// Jump by wall-clock seconds. The transport's ±5 buttons are the same
    /// control in both bars and speak seconds; this engine counts frames, so the
    /// conversion belongs here rather than in the view.
    func skip(seconds: Double) {
        seek(to: currentFrame + Int(frameRate * seconds))
    }

    /// Show one frame (paused seek / poster). Decode runs off the main thread.
    func seek(to frame: Int) {
        let clamped = min(max(0, frame), max(0, frameCount - 1))
        let wasPlaying = isPlaying
        pause()
        currentFrame = clamped
        showFrame(clamped)
        if wasPlaying {
            startPlaying(at: clamped)
        }
    }

    func showFrame(_ index: Int) {
        let clip = clip
        let generation = playGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let buffer = clip.copyFrame(at: index) else { return }
            guard let self else { return }
            // the scope state is read BEFORE the pass, not after it: every
            // paused seek and every poster frame used to run a full analysis
            // and throw it away when the scopes turned out to be closed
            let state = await MainActor.run {
                (live: self.playGeneration == generation,
                 scopes: self.scopesEnabled, region: self.scopeRegion)
            }
            guard state.live else { return }
            self.present(buffer)
            let data = state.scopes // off-main, like the loop
                ? ScopeAnalyzer.analyze(buffer, region: state.region) : nil
            let boxed = UncheckedSendable(buffer)
            await MainActor.run {
                self.lastBuffer = boxed.value
                if let data {
                    self.onScopeData?(data)
                }
            }
        }
    }
}
