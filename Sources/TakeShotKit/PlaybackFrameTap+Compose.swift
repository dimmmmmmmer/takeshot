import CaptureCore
import CoreImage
import CoreVideo
import Foundation
import os.log

/// One frame out: the preview LUT, the compare composite over it, and the
/// render into a pooled buffer.
///
/// Everything here runs on the tap queue, like the polling half it was split
/// from. The B-side clip that feeds the composite's back half is
/// `+CompareClip`; scope analysis of the result is `+Scopes`.
extension PlaybackFrameTap {
    /// Playback LUT (replaces AVVideoComposition: its render pipeline shifted
    /// contrast even on clips it did not visibly change).
    ///
    /// What crosses is the WAY to build the filter, never the filter: a
    /// `CIFilter` is a mutable CoreImage object and the render that uses it
    /// runs on the tap queue, so it is made there and exists nowhere else.
    /// `CapturePipeline.setLUT` reaches the same place from the other end, by
    /// taking the cube and calling `makeFilter` on its own queue. `nil` clears.
    func setLUT(_ makeFilter: (@Sendable () -> CIFilter?)?, intensity: Double) {
        queue.async {
            let filter = makeFilter?()
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
            // Before the aids, deliberately: the scopes measure the clip, not
            // the false colour laid over it. Same rule the live path follows —
            // the deliverable branch never sees an assist.
            analyzeScopes(of: output)
        }
        let shown = assistStage.rendered(output) ?? output
        sinks.present(shown)
        // A/B side by side: the A pane is its own surface, so the compare source
        // goes out uncomposited instead of into the wipe — but it is a picture
        // the operator is metering too, so it carries the aids as well.
        if !sidePanes.isEmpty, let side = lastCompareBuffer {
            compareSinks.present(assistStage.rendered(side) ?? side)
        }
        displayFrameLock.lock()
        let handler = displayFrameHandler
        displayFrameLock.unlock()
        handler?(shown)
    }

    /// LUT + compare composite in raw code values (color management off — the
    /// values pass through exactly like the live path's).
    private func composed(from playbackBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let raw = CIImage(cvPixelBuffer: playbackBuffer,
                          options: [.colorSpace: NSNull()])
        // Difference is a measurement, not a picture: both halves are read at
        // the pre-LUT stage (the raw playback frame, the pre-LUT live buffer)
        // and the |A−B| output bypasses the viewing LUT entirely — a look bent
        // over the numbers would bend exactly what the operator is checking.
        // With no back half it falls through and shows the plain playback
        // frame, the same fallback the other modes have.
        if case .difference = compare,
           let back = liveImage(matching: raw.extent, preLUT: true) {
            let result = CompareCompositor.compose(front: raw, back: back,
                                                   mode: compare)
            return rendered(result, extent: raw.extent)
        }
        var playback = raw
        if let lutFilter {
            lutFilter.setValue(playback, forKey: kCIInputImageKey)
            if let filtered = lutFilter.outputImage {
                playback = CapturePipeline.mix(source: playback, filtered: filtered,
                                               intensity: lutIntensity)
            }
        }
        var result = playback
        switch compare {
        case .off, .difference:
            if lutFilter == nil { return nil } // untouched frame — no render needed
        case .blend, .wipe:
            // One arm for both: the wipe and the blend differ only inside the
            // compositor, and writing them out separately here meant the "pull
            // the back half, bail if there isn't one" dance was written twice.
            guard let liveImage = liveImage(matching: playback.extent) else { break }
            result = CompareCompositor.compose(front: playback, back: liveImage,
                                               mode: compare)
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
}
