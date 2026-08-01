import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

/// The ~60 Hz poll that pulls frames out of the player.
///
/// AVPlayer does not push: a video output has to be asked whether it has a new
/// frame for a given host time. Split out of `PlaybackFrameTap` because the
/// cadence is a subject of its own — a playing clip, a paused one and a still
/// all deliver on different schedules, and getting that wrong shows up either as
/// a judder or as a LUT change that does not land until playback resumes.
///
/// All of it runs on `queue`.
extension PlaybackFrameTap {
    func startTimerIfNeeded() {
        timer?.cancel()
        timer = nil
        guard running, output != nil || stillBuffer != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(),
                       repeating: .milliseconds(Self.tickIntervalMilliseconds))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        if comparePlayer != nil {
            syncCompareClip()
            idleDelivered = false // the B half advances even when A is paused
        }
        guard let output else {
            tickStill()
            return
        }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        tickCount += 1
        if !output.hasNewPixelBuffer(forItemTime: itemTime) {
            tickPaused(output, at: itemTime)
            return
        }
        idleDelivered = false // playing again: idle state re-arms
        guard let pixelBuffer = output.copyPixelBuffer(
            forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
        deliver(pixelBuffer,
                analyzed: scopesEnabled && tickCount % Self.scopeTickStride == 0)
    }

    /// Still: recomposite at the paused cadence so the live half of a compare
    /// keeps moving (and LUT changes land immediately).
    private func tickStill() {
        guard let still = stillBuffer else { return }
        tickCount += 1
        tickIdle { still }
    }

    /// Paused player: the same cadence as a still — the picture is not moving
    /// either way.
    private func tickPaused(_ output: AVPlayerItemVideoOutput, at itemTime: CMTime) {
        tickIdle {
            output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
        }
    }

    /// One delivery of a picture that is not advancing — a paused player or a
    /// still — then nothing until an input changes, or ~15 Hz for as long as a
    /// compare's other half keeps moving.
    ///
    /// The two callers ran the identical cadence with their own copies of it.
    /// `frame` is a closure rather than a buffer because the paused player has
    /// to COPY its frame out of the video output, and doing that on every 60 Hz
    /// tick for a picture that is not going to be delivered is a decode for
    /// nothing.
    private func tickIdle(_ frame: () -> CVPixelBuffer?) {
        guard !isCompareOff else {
            // static output: one delivery until an input changes
            guard !idleDelivered, let buffer = frame() else { return }
            idleDelivered = true
            deliver(buffer, analyzed: scopesEnabled)
            return
        }
        // the live half of the compare keeps moving
        guard tickCount % 4 == 0, let buffer = frame() else { return }
        deliver(buffer, analyzed: scopesEnabled && tickCount % 16 == 0)
    }
}
