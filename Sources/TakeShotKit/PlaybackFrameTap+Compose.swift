import AVFoundation
import os.log
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

/// The composite half of the playback tap: the preview LUT, the compare wipe/
/// blend and the B-side clip that feeds its back half.
///
/// Split out of PlaybackFrameTap — everything here runs on the tap queue, like
/// the polling half it was split from.
extension PlaybackFrameTap {
    /// Compare against another clip (nil — back to the live signal).
    /// `syncTo` is the main player; the B player follows its rate/position.
    func setCompareClip(url: URL?, syncTo player: AVPlayer?) {
        queue.async {
            self.idleDelivered = false
            self.comparePlayer?.pause()
            self.comparePlayer = nil
            self.compareOutput = nil
            self.lastCompareBuffer = nil
            self.syncPlayer = nil
            if let url {
                let item = AVPlayerItem(url: url)
                let attrs: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_32BGRA,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                ]
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
                item.add(output)
                let bPlayer = AVPlayer(playerItem: item)
                bPlayer.volume = 0
                self.comparePlayer = bPlayer
                self.compareOutput = output
                self.syncPlayer = player
            }
            if let buffer = self.lastBuffer {
                self.deliver(buffer, analyzed: false)
            }
        }
    }

    /// Keep the B player glued to the main transport (rate + position).
    func syncCompareClip() {
        guard let bPlayer = comparePlayer, let main = syncPlayer else { return }
        if bPlayer.rate != main.rate {
            bPlayer.rate = main.rate
        }
        let drift = main.currentTime().seconds - bPlayer.currentTime().seconds
        if abs(drift) > 0.08 {
            bPlayer.seek(to: main.currentTime(),
                         toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func setCompare(_ mode: Compare) {
        queue.async {
            self.idleDelivered = false
            self.compare = mode
            // re-render immediately so a paused player reflects the change
            if let buffer = self.lastBuffer {
                self.deliver(buffer, analyzed: self.scopesEnabled)
            }
        }
    }

    /// Playback LUT (replaces AVVideoComposition: its render pipeline shifted
    /// contrast even on clips it did not visibly change).
    func setLUT(_ filter: CIFilter?, intensity: Double) {
        queue.async {
            os_log("tap setLUT: filter=%d intensity=%.2f",
                   log: CapturePipeline.levelsLog, type: .default,
                   filter != nil ? 1 : 0, intensity)
            self.idleDelivered = false
            self.lutFilter = filter
            self.lutIntensity = intensity
            if let buffer = self.lastBuffer {
                self.deliver(buffer, analyzed: self.scopesEnabled)
            }
        }
    }

    /// Mix coefficient only — no filter rebuild (slider ticks).
    func setLUTIntensity(_ intensity: Double) {
        queue.async {
            self.idleDelivered = false
            self.lutIntensity = intensity
            if let buffer = self.lastBuffer {
                self.deliver(buffer, analyzed: false)
            }
        }
    }

    func deliver(_ pixelBuffer: CVPixelBuffer, analyzed: Bool) {
        lastBuffer = pixelBuffer
        // ONE pull of the B clip per delivered frame, before composing. The
        // composite's back half and the A/B pane read the same
        // `lastCompareBuffer`: pulling per consumer would show them different
        // moments of the same clip. Skipped when neither wants it — a
        // copyPixelBuffer on every 60 Hz tick for a surface nobody mounted is a
        // decode a frame for nothing.
        let sidePanes = compareSinks.all()
        if !sidePanes.isEmpty || !isCompareOff {
            pullCompareBuffer()
        }
        let output = composed(from: pixelBuffer) ?? pixelBuffer
        if analyzed {
            analyzeScopes(of: output)
        }
        sinks.present(output)
        // A/B side by side: the A pane is its own surface, so the compare source
        // goes out uncomposited instead of into the wipe.
        if !sidePanes.isEmpty, let side = lastCompareBuffer {
            compareSinks.present(side)
        }
        displayFrameLock.lock()
        let handler = displayFrameHandler
        displayFrameLock.unlock()
        handler?(output)
    }

    /// Whether nothing is being composited over the playback frame.
    var isCompareOff: Bool {
        if case .off = compare { return true }
        return false
    }

    /// Latest frame of the B clip into `lastCompareBuffer`, or leave the previous
    /// one in place when the slaved player has nothing new (it runs at the clip's
    /// rate, the tap polls at 60 Hz).
    ///
    /// Call on `queue`.
    private func pullCompareBuffer() {
        guard let compareOutput else { return }
        let time = compareOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard compareOutput.hasNewPixelBuffer(forItemTime: time),
              let buffer = compareOutput.copyPixelBuffer(
                  forItemTime: time, itemTimeForDisplay: nil)
        else { return }
        lastCompareBuffer = buffer
    }

    /// Hand the composed frame to the analyzer on its own queue.
    ///
    /// It used to run inline, on the render queue that polls the player at
    /// 60 Hz: one 1080p pass held that queue for over a hundred milliseconds on
    /// noisy content, so the picture juddered exactly while the operator was
    /// watching the scopes. Latest-wins, like the capture pipeline's: a frame
    /// offered while a pass is in flight is dropped, never queued.
    private func analyzeScopes(of buffer: CVPixelBuffer) {
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

    /// LUT + compare composite in raw code values (color management off — the
    /// values pass through exactly like the live path's).
    private func composed(from playbackBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        var playback = CIImage(cvPixelBuffer: playbackBuffer,
                               options: [.colorSpace: NSNull()])
        if let lutFilter {
            lutFilter.setValue(playback, forKey: kCIInputImageKey)
            if let filtered = lutFilter.outputImage {
                playback = CapturePipeline.mix(source: playback, filtered: filtered,
                                               intensity: lutIntensity)
            }
        }
        var result = playback
        switch compare {
        case .off:
            if lutFilter == nil { return nil } // untouched frame — no render needed
        case .blend(let opacity):
            guard let liveImage = liveImage(matching: playback.extent) else { break }
            result = CompareCompositor.compose(front: playback, back: liveImage,
                                               mode: .blend(opacity: opacity))
        case .wipe(let axis, let position):
            guard let liveImage = liveImage(matching: playback.extent) else { break }
            result = CompareCompositor.compose(
                front: playback, back: liveImage,
                mode: .wipe(axis: axis, position: position))
        }
        return rendered(result, extent: playback.extent)
    }

    /// Render the composite into a pooled buffer, color management off.
    private func rendered(_ image: CIImage, extent: CGRect) -> CVPixelBuffer? {
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        guard width > 0, height > 0,
              let out = composePool.buffer(width: width, height: height)
        else { return nil }
        let destination = CIRenderDestination(pixelBuffer: out)
        destination.colorSpace = nil
        guard let task = try? ciContext.startTask(toRender: image, to: destination)
        else { return nil }
        _ = try? task.waitUntilCompleted()
        return out
    }

    /// The compare back half: the B clip when one is set, else the live frame.
    ///
    /// Reads the buffer `deliver` already pulled rather than pulling its own —
    /// see the comment there for why there is exactly one pull per frame.
    private func liveImage(matching extent: CGRect) -> CIImage? {
        if compareOutput != nil {
            guard let buffer = lastCompareBuffer else { return nil }
            let image = CIImage(cvPixelBuffer: buffer,
                                options: [.colorSpace: NSNull()])
            guard image.extent.width > 0 else { return nil }
            return CompareCompositor.fitted(image, into: extent)
        }
        guard let live = liveBufferProvider?() else { return nil }
        let isBGRA = CVPixelBufferGetPixelFormatType(live) == kCVPixelFormatType_32BGRA
        // BGRA carries raw full-range codes; YUV needs CI's managed decode
        let image = isBGRA
            ? CIImage(cvPixelBuffer: live, options: [.colorSpace: NSNull()])
            : CIImage(cvPixelBuffer: live)
        guard image.extent.width > 0, image.extent.height > 0 else { return nil }
        return CompareCompositor.fitted(image, into: extent)
    }
}
