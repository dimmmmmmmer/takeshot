import CaptureCore
import CoreVideo
import Foundation
import QuartzCore

/// The RAW engine's decode/present loop.
///
/// Split out of `RawPlayback.swift` because everything here reasons about one
/// thing the rest of the type does not: a loop that was cancelled while parked
/// in a blocking decode wakes up later, and every write it could still make is
/// gated on `playGeneration` being the one it started with.
extension RawPlayerModel {
    /// The decode/present loop. It carries `generation`: a loop that was
    /// cancelled while parked in a blocking decode wakes up later, and every
    /// write it could make is gated on the generation still being current.
    func makePlayTask(startFrame: Int,
                      generation: Int) -> Task<Void, Never> {
        let clip = clip
        let fps = frameRate
        let total = frameCount
        return Task.detached(priority: .userInitiated) { [weak self] in
            let startHost = CACurrentMediaTime()
            var scopeCounter = 0
            var index = startFrame
            while !Task.isCancelled {
                guard let buffer = clip.copyFrame(at: index) else {
                    // A failed decode is not the end of the clip, and pausing
                    // silently makes the two look identical. Frames the recorder
                    // dropped, a corrupt block, a volume that went away — the
                    // decoder knows which, and the operator gets told.
                    await self?.reportDecodeFailure(clip.lastDecodeError,
                                                    at: index,
                                                    generation: generation)
                    break
                }
                guard let self else { return }
                scopeCounter += 1
                guard await self.presentPlayed(buffer, at: index,
                                               generation: generation,
                                               scopeCounter: scopeCounter)
                else { return }
                let next = await Self.nextIndex(after: index,
                                                startFrame: startFrame,
                                                startHost: startHost, fps: fps)
                let outLimit = await MainActor.run { [weak self] in
                    self?.outFrame
                }
                if let outLimit, next > outLimit {
                    let looping = await MainActor.run { [weak self] in
                        self?.isLooping ?? false
                    }
                    if looping {
                        return await self.restartLoop(fromInPoint: true,
                                                      generation: generation)
                    }
                    break
                }
                if next >= total {
                    let looping = await MainActor.run { [weak self] in
                        self?.isLooping ?? false
                    }
                    if !looping { break }
                    // loop restarts the time base at frame 0
                    return await self.restartLoop(fromInPoint: false,
                                                  generation: generation)
                }
                index = next
            }
            await self?.finishLoop(generation: generation)
        }
    }

    /// Present one decoded frame and publish the transport state. Returns
    /// false when the loop is stale — pause/seek happened mid-decode, and
    /// neither the picture nor the transport state may be touched.
    nonisolated private func presentPlayed(_ buffer: CVPixelBuffer, at index: Int,
                                           generation: Int,
                                           scopeCounter: Int) async -> Bool {
        let state = await MainActor.run {
            (live: self.playGeneration == generation && self.isPlaying,
             scopes: self.scopesEnabled, region: self.scopeRegion,
             stride: self.scopeFrameStride)
        }
        guard state.live else { return false }
        self.present(buffer)
        // analysis stays OFF the MainActor: noisy frames are expensive
        let scopeData = state.scopes && scopeCounter % state.stride == 0
            ? ScopeAnalyzer.analyze(buffer, region: state.region) : nil
        let boxed = UncheckedSendable(buffer)
        await MainActor.run {
            self.lastBuffer = boxed.value
            self.currentFrame = index
            if let scopeData {
                self.onScopeData?(scopeData)
            }
        }
        return true
    }

    /// Real-time mapping: skip frames if decode is slower than fps, and wait
    /// out the slot if it is faster.
    nonisolated private static func nextIndex(
        after index: Int, startFrame: Int,
        startHost: CFTimeInterval, fps: Double) async -> Int {
        let elapsed = CACurrentMediaTime() - startHost
        var next = startFrame + Int(elapsed * fps) + 1
        if next <= index { // decode faster than fps: wait for the slot
            next = index + 1
            let slotTime = startHost + Double(next - startFrame) / fps
            let wait = slotTime - CACurrentMediaTime()
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            }
        }
        return next
    }

    /// Loop point reached: hand the session to a NEW generation. A loop that
    /// is no longer the current one must not restart playback behind its back.
    private func restartLoop(fromInPoint: Bool, generation: Int) {
        guard isPlaying, playGeneration == generation else { return }
        isPlaying = false
        currentFrame = fromInPoint ? (inFrame ?? 0) : 0
        play()
    }

    /// The loop ran out (clip end, failed decode, cancellation): only the
    /// generation that is still current may clear the playing flag.
    private func finishLoop(generation: Int) {
        guard playGeneration == generation else { return }
        isPlaying = false
    }

    /// A decode failed mid-clip. Only the current generation may report it —
    /// a loop orphaned by a seek can fail on a frame nobody is waiting for.
    /// The last frame the clip reached matters more than the reason for an
    /// operator deciding whether the card is bad, so both are said.
    private func reportDecodeFailure(_ reason: String?, at index: Int,
                                     generation: Int) {
        guard playGeneration == generation, index < frameCount - 1 else { return }
        let text = reason ?? L("raw_decode_stopped")
        playbackError = text
        onPlaybackError?(text)
    }
}
