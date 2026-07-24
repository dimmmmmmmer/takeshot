import AVFoundation
import os.log
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
/// Every mount (main window, compare branches, fullscreen, external monitor)
/// registers its OWN layer: a CALayer lives in only one NSView, and a shared
/// instance got stolen between views on branch switches — the survivor then
/// drew with the thief's stale geometry.
final class PlaybackFrameTap: @unchecked Sendable {
    private let sinksLock = NSLock()
    private let sinks = NSHashTable<MetalPreviewLayer>.weakObjects()
    private var sinkLetterbox = CIColor(red: 0, green: 0, blue: 0)

    func addSink(_ layer: MetalPreviewLayer) {
        sinksLock.lock()
        layer.letterboxColor = sinkLetterbox
        sinks.add(layer)
        sinksLock.unlock()
        // show the current frame right away — a paused player won't push one
        queue.async {
            if let buffer = self.lastBuffer {
                self.deliver(buffer, analyzed: false)
            }
        }
    }

    func removeSink(_ layer: MetalPreviewLayer) {
        sinksLock.lock()
        sinks.remove(layer)
        sinksLock.unlock()
    }

    func setLetterbox(_ color: CIColor) {
        sinksLock.lock()
        sinkLetterbox = color
        let all = sinks.allObjects
        sinksLock.unlock()
        for layer in all {
            layer.letterboxColor = color
            layer.redraw()
        }
    }

    private func allSinks() -> [MetalPreviewLayer] {
        sinksLock.lock()
        defer { sinksLock.unlock() }
        return sinks.allObjects
    }

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
    /// Static source (a still in the player): composited/analyzed like video.
    private var stillBuffer: CVPixelBuffer?

    // MARK: - compare & LUT (composited HERE, in one Metal layer: SwiftUI
    // masks/opacity over video layers drop the colorspace and shift colors)

    enum Compare {
        case off
        case blend(opacity: Double)
        case wipe(axis: CompareCompositor.Axis, position: Double)
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
            os_log("tap setLUT: filter=%d intensity=%.2f",
                   log: CapturePipeline.levelsLog, type: .default,
                   filter != nil ? 1 : 0, intensity)
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
            self.lutIntensity = intensity
            if let buffer = self.lastBuffer {
                self.deliver(buffer, analyzed: false)
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

    /// The current playback frame (pin-as-reference). Queue-synchronous.
    func currentBuffer() -> CVPixelBuffer? {
        var result: CVPixelBuffer?
        queue.sync { result = self.lastBuffer }
        return result
    }

    /// Show a still through the same render/LUT/compare path as video.
    func attachStill(_ buffer: CVPixelBuffer) {
        queue.async {
            self.detachLocked()
            self.stillBuffer = buffer
            self.lastBuffer = buffer
            self.deliver(buffer, analyzed: self.scopesEnabled)
            self.startTimerIfNeeded()
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
        stillBuffer = nil
    }

    private func startTimerIfNeeded() {
        timer?.cancel()
        timer = nil
        guard running, output != nil || stillBuffer != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16)) // ~60 Hz polling
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard let output else {
            // still: recomposite at the paused cadence so the live half of a
            // compare keeps moving (and LUT changes land immediately)
            if let still = stillBuffer {
                let interval: Int
                if case .off = compare { interval = 15 } else { interval = 4 }
                tickCount += 1
                if tickCount % interval == 0 {
                    deliver(still, analyzed: scopesEnabled && tickCount % 16 == 0)
                }
            }
            return
        }
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
        for layer in allSinks() {
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
            result = CompareCompositor.compose(front: playback, back: liveImage,
                                               mode: .blend(opacity: opacity))
        case .wipe(let axis, let position):
            guard let liveImage = liveImage(matching: playback.extent) else { break }
            result = CompareCompositor.compose(
                front: playback, back: liveImage,
                mode: .wipe(axis: axis, position: position))
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

    /// Latest live frame aspect-fitted (letterboxed) into the playback extent.
    private func liveImage(matching extent: CGRect) -> CIImage? {
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
