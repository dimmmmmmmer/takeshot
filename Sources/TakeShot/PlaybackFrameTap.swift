import AVFoundation
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

/// Unified playback render: frames are pulled from AVPlayer via AVPlayerItemVideoOutput
/// (after videoComposition, i.e. already with the LUT) and drawn by MetalPreviewLayer —
/// the same graphics-path renderer as live. No AVPlayerLayer — live and playback go
/// through the same display path, so wipe/blend compare fairly and colors match.
///
/// There are three layers (main window, fullscreen, external monitor): a CALayer lives
/// in only one view, so each window gets its own.
final class PlaybackFrameTap: @unchecked Sendable {
    let mainLayer = MetalPreviewLayer()
    let fullscreenLayer = MetalPreviewLayer()
    let externalLayer = MetalPreviewLayer()

    private let queue = DispatchQueue(label: "takeshot.playback-tap", qos: .userInitiated)
    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private var timer: DispatchSourceTimer?
    private var running = false
    private var scopesEnabled = false
    private var tickCount = 0

    /// Scope data from playback frames (~8 Hz while enabled), on the main queue.
    var onScopeData: ((ScopeData) -> Void)?

    private var lastBuffer: CVPixelBuffer?

    // MARK: - compare & LUT (composited HERE, in one Metal layer: SwiftUI
    // masks/opacity over video layers drop the colorspace and shift colors)

    enum Compare {
        case off
        case blend(opacity: Double)
        case wipe(orientation: CaptureController.WipeOrientation, position: Double)
    }

    private var compare: Compare = .off
    /// Pulls the latest live preview frame (assigned via setLiveBufferProvider).
    private var liveBufferProvider: (() -> CVPixelBuffer?)?

    /// Queue-confined setter — the provider is read on the tap queue.
    func setLiveBufferProvider(_ provider: @escaping () -> CVPixelBuffer?) {
        queue.async { self.liveBufferProvider = provider }
    }
    private var lutFilter: CIFilter?
    private var lutIntensity: Double = 1
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let composePool = PixelBufferPool()

    func setCompare(_ mode: Compare) {
        queue.async {
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
            self.lutFilter = filter
            self.lutIntensity = intensity
            if let buffer = self.lastBuffer {
                self.deliver(buffer, analyzed: self.scopesEnabled)
            }
        }
    }

    func setScopesEnabled(_ on: Bool) {
        queue.async {
            self.scopesEnabled = on
            // paused player delivers no new frames — analyze right away (via
            // deliver, so scopes see the same composed output as the screen)
            if on, let buffer = self.lastBuffer {
                self.deliver(buffer, analyzed: true)
            }
        }
    }

    /// Attach to a new clip (the old output is removed).
    func attach(to item: AVPlayerItem) {
        queue.async {
            self.detachLocked()
            // BGRA full range: MetalPreviewLayer passes code values through
            // unmanaged, and full-range RGB is the exact same representation
            // the live path draws — playback and rec render identically
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
            item.add(output)
            self.output = output
            self.item = item
            self.lastBuffer = nil
            self.startTimerIfNeeded()
        }
    }

    func setRunning(_ running: Bool) {
        queue.async {
            self.running = running
            self.startTimerIfNeeded()
        }
    }

    func detach() {
        queue.async { self.detachLocked() }
    }

    // MARK: - on queue

    private func detachLocked() {
        timer?.cancel()
        timer = nil
        if let output, let item {
            item.remove(output)
        }
        output = nil
        item = nil
    }

    private func startTimerIfNeeded() {
        timer?.cancel()
        timer = nil
        guard running, output != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16)) // ~60 Hz polling
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard let output else { return }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        tickCount += 1
        if !output.hasNewPixelBuffer(forItemTime: itemTime) {
            // paused player: no "new" frames, but the current one must still
            // reach the layers/scopes — and with compare active the LIVE half
            // must keep moving, so recomposite at ~15 Hz instead of ~4
            let interval: Int
            if case .off = compare { interval = 15 } else { interval = 4 }
            if tickCount % interval == 0,
               let pixelBuffer = output.copyPixelBuffer(
                   forItemTime: itemTime, itemTimeForDisplay: nil) {
                deliver(pixelBuffer,
                        analyzed: scopesEnabled && tickCount % 16 == 0)
            }
            return
        }
        guard let pixelBuffer = output.copyPixelBuffer(
            forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
        deliver(pixelBuffer, analyzed: scopesEnabled && tickCount % 8 == 0)
    }

    private func deliver(_ pixelBuffer: CVPixelBuffer, analyzed: Bool) {
        lastBuffer = pixelBuffer
        let output = composed(from: pixelBuffer) ?? pixelBuffer
        if analyzed, let scopeData = ScopeAnalyzer.analyze(output) {
            DispatchQueue.main.async { self.onScopeData?(scopeData) }
        }
        for layer in [mainLayer, fullscreenLayer, externalLayer] {
            layer.present(output)
        }
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
            // cross-dissolve, not an alpha matrix: fading only the alpha of a
            // premultiplied image leaves RGB at full strength and over-brightens
            result = CapturePipeline.mix(source: liveImage, filtered: playback,
                                         intensity: opacity)
        case .wipe(let orientation, let position):
            guard let liveImage = liveImage(matching: playback.extent) else { break }
            let extent = playback.extent
            var rect = CGRect.zero
            switch orientation {
            case .vertical:
                rect = CGRect(x: extent.minX, y: extent.minY,
                              width: extent.width * position, height: extent.height)
            case .horizontal:
                // SwiftUI's wipe drags from the top; CI origin is bottom-left
                rect = CGRect(x: extent.minX,
                              y: extent.minY + extent.height * (1 - position),
                              width: extent.width, height: extent.height * position)
            case .diagonal:
                break // gradient mask below, no crop rect
            }
            if orientation == .diagonal {
                // SwiftUI wipe region (top-left origin): x + y ≤ t. In CI's
                // bottom-left coordinates that is d(x,y) = x − y ≤ t − height.
                // A 1-px gradient across that line makes an exact hard mask.
                let t = position * Double(extent.width + extent.height)
                let threshold = t - Double(extent.height)
                func pointAt(_ d: Double) -> CIVector {
                    CIVector(x: d / 2, y: -d / 2) // the point where x − y = d
                }
                if let mask = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": pointAt(threshold - 0.5),
                    "inputPoint1": pointAt(threshold + 0.5),
                    "inputColor0": CIColor.white,
                    "inputColor1": CIColor.black,
                ])?.outputImage?.cropped(to: extent) {
                    result = playback.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: liveImage,
                        kCIInputMaskImageKey: mask,
                    ])
                }
            } else {
                result = playback.cropped(to: rect).composited(over: liveImage)
            }
        }
        let width = Int(playback.extent.width.rounded())
        let height = Int(playback.extent.height.rounded())
        guard width > 0, height > 0,
              let out = composePool.buffer(width: width, height: height)
        else { return nil }
        let destination = CIRenderDestination(pixelBuffer: out)
        destination.colorSpace = nil
        guard let task = try? ciContext.startTask(toRender: result, to: destination)
        else { return nil }
        _ = try? task.waitUntilCompleted()
        return out
    }

    /// Latest live frame aspect-fitted (letterboxed) into the playback extent —
    /// an anamorphic stretch would make the geometric comparison meaningless.
    private func liveImage(matching extent: CGRect) -> CIImage? {
        guard let live = liveBufferProvider?() else { return nil }
        let isBGRA = CVPixelBufferGetPixelFormatType(live) == kCVPixelFormatType_32BGRA
        // BGRA carries raw full-range codes; YUV needs CI's managed decode
        var image = isBGRA
            ? CIImage(cvPixelBuffer: live, options: [.colorSpace: NSNull()])
            : CIImage(cvPixelBuffer: live)
        let le = image.extent
        guard le.width > 0, le.height > 0 else { return nil }
        if le.size != extent.size {
            let scale = min(extent.width / le.width, extent.height / le.height)
            let tx = (extent.width - le.width * scale) / 2
            let ty = (extent.height - le.height * scale) / 2
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: tx, y: ty)))
                .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0))
                    .cropped(to: extent))
        }
        return image
    }
}
