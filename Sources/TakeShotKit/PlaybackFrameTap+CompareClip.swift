import AVFoundation
import CaptureCore
import CoreImage
import CoreVideo
import Foundation
import QuartzCore

/// The compare source: the take-vs-take B clip on its own slaved player, and
/// the back half it hands the composite.
///
/// Split out of `+Compose`: producing the other picture and blending it into
/// this one are separate jobs, and only this half has a second AVPlayer to keep
/// glued to the first.
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
            self.compareURL = url
            self.compareCarriesWireCodes = false
            self.compareTransfer = .sdr
            if let url {
                self.detectCompareLevels(of: url)
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
    func pullCompareBuffer() {
        guard let compareOutput else { return }
        let time = compareOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard compareOutput.hasNewPixelBuffer(forItemTime: time),
              let buffer = compareOutput.copyPixelBuffer(
                  forItemTime: time, itemTimeForDisplay: nil)
        else { return }
        lastCompareBuffer = displayReady(buffer,
                                         wireCodes: compareCarriesWireCodes,
                                         transfer: compareTransfer)
    }

    /// The compare back half: the B clip when one is set, else the live frame.
    ///
    /// Reads the buffer `deliver` already pulled rather than pulling its own —
    /// see the comment there for why there is exactly one pull per frame.
    ///
    /// `preLUT` asks for the live frame BEFORE the preview LUT — the
    /// difference compare measures code values and must not see the look. The
    /// B clip is decoded straight off disk and never carries it, so the flag
    /// only matters on the live branch.
    func liveImage(matching extent: CGRect, preLUT: Bool = false) -> CIImage? {
        if compareOutput != nil {
            guard let buffer = lastCompareBuffer else { return nil }
            let image = CIImage(cvPixelBuffer: buffer,
                                options: [.colorSpace: NSNull()])
            guard image.extent.width > 0 else { return nil }
            return CompareCompositor.fitted(image, into: extent)
        }
        let provider = preLUT
            ? (livePreLUTBufferProvider ?? liveBufferProvider)
            : liveBufferProvider
        guard let live = provider?() else { return nil }
        let isBGRA = CVPixelBufferGetPixelFormatType(live) == kCVPixelFormatType_32BGRA
        // BGRA carries raw full-range codes; YUV needs CI's managed decode
        let image = isBGRA
            ? CIImage(cvPixelBuffer: live, options: [.colorSpace: NSNull()])
            : CIImage(cvPixelBuffer: live)
        guard image.extent.width > 0, image.extent.height > 0 else { return nil }
        return CompareCompositor.fitted(image, into: extent)
    }
}
