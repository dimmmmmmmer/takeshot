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
        let output = composed(from: pixelBuffer) ?? pixelBuffer
        if analyzed, let scopeData = ScopeAnalyzer.analyze(output) {
            DispatchQueue.main.async { self.onScopeData?(scopeData) }
        }
        sinks.present(output)
        displayFrameLock.lock()
        let handler = displayFrameHandler
        displayFrameLock.unlock()
        handler?(output)
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
    private func liveImage(matching extent: CGRect) -> CIImage? {
        if let compareOutput {
            let time = compareOutput.itemTime(forHostTime: CACurrentMediaTime())
            if compareOutput.hasNewPixelBuffer(forItemTime: time),
               let buffer = compareOutput.copyPixelBuffer(
                   forItemTime: time, itemTimeForDisplay: nil) {
                lastCompareBuffer = buffer
            }
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
