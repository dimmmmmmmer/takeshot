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
///
/// The LUT/compare composite and its B-side clip live in
/// `PlaybackFrameTap+Compose.swift`; members it reaches are module-internal
/// rather than private for that reason.
final class PlaybackFrameTap: @unchecked Sendable {
    let sinks = PreviewSinkRegistry()
    /// Every delivered frame (tap queue) — hardware playout mirror. Set from the
    /// main actor while the tap queue reads it, so it goes through a lock (see
    /// the same pattern in CapturePipeline and RawPlayerModel).
    let displayFrameLock = NSLock()
    var displayFrameHandler: (@Sendable (CVPixelBuffer) -> Void)?

    func setOnDisplayFrame(_ handler: (@Sendable (CVPixelBuffer) -> Void)?) {
        displayFrameLock.lock()
        displayFrameHandler = handler
        displayFrameLock.unlock()
    }

    func addSink(_ layer: MetalPreviewLayer) {
        sinks.add(layer)
        // show the current frame right away — a paused player won't push one
        queue.async {
            if let buffer = self.lastBuffer {
                self.deliver(buffer, analyzed: false)
            }
        }
    }

    func removeSink(_ layer: MetalPreviewLayer) {
        sinks.remove(layer)
    }

    func setViewAssist(_ assist: ViewAssist) {
        sinks.setAssist(assist)
    }

    func setLetterbox(_ color: CIColor) {
        sinks.setLetterbox(color)
    }

    let queue = DispatchQueue(label: "takeshot.playback-tap", qos: .userInitiated)
    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private var timer: DispatchSourceTimer?
    private var running = false
    var scopesEnabled = false
    private var tickCount = 0

    /// Scope data from playback frames (~8 Hz while enabled), on the main queue.
    var onScopeData: ((ScopeData) -> Void)?

    var lastBuffer: CVPixelBuffer?
    /// Static source (a still in the player): composited/analyzed like video.
    private var stillBuffer: CVPixelBuffer?
    /// Idle output already delivered — with compare off, a paused/still frame
    /// is re-rendered only when the LUT/compare/scopes inputs change.
    var idleDelivered = false

    // MARK: - compare & LUT (composited in PlaybackFrameTap+Compose, in one
    // Metal layer: SwiftUI masks/opacity over video layers drop the colorspace
    // and shift colors)

    enum Compare {
        case off
        case blend(opacity: Double)
        case wipe(axis: CompareCompositor.Axis, position: Double)
    }

    var compare: Compare = .off
    /// Pulls the latest live preview frame (assigned via setLiveBufferProvider).
    var liveBufferProvider: (() -> CVPixelBuffer?)?

    /// Queue-confined setter — the provider is read on the tap queue.
    func setLiveBufferProvider(_ provider: @escaping () -> CVPixelBuffer?) {
        queue.async { self.liveBufferProvider = provider }
    }
    var lutFilter: CIFilter?
    var lutIntensity: Double = 1

    // B-side clip (take vs take): its own slaved player; when set, the
    // compare back half comes from it instead of the live signal
    var comparePlayer: AVPlayer?
    var compareOutput: AVPlayerItemVideoOutput?
    var lastCompareBuffer: CVPixelBuffer?
    weak var syncPlayer: AVPlayer?

    let ciContext = CIContext(options: [.cacheIntermediates: false])
    let composePool = PixelBufferPool()

    func setScopesEnabled(_ on: Bool) {
        queue.async {
            self.idleDelivered = false
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
            self.idleDelivered = false
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
        deliver(pixelBuffer, analyzed: scopesEnabled && tickCount % 8 == 0)
    }

    /// Still: recomposite at the paused cadence so the live half of a compare
    /// keeps moving (and LUT changes land immediately).
    private func tickStill() {
        guard let still = stillBuffer else { return }
        tickCount += 1
        if case .off = compare {
            // static output: one delivery until an input changes
            if !idleDelivered {
                idleDelivered = true
                deliver(still, analyzed: scopesEnabled)
            }
        } else if tickCount % 4 == 0 {
            // the live half of the compare keeps moving
            deliver(still, analyzed: scopesEnabled && tickCount % 16 == 0)
        }
    }

    /// Paused player: static output — deliver once, then only keep the live
    /// half of an active compare moving (~15 Hz).
    private func tickPaused(_ output: AVPlayerItemVideoOutput, at itemTime: CMTime) {
        if case .off = compare {
            if !idleDelivered,
               let pixelBuffer = output.copyPixelBuffer(
                   forItemTime: itemTime, itemTimeForDisplay: nil) {
                idleDelivered = true
                deliver(pixelBuffer, analyzed: scopesEnabled)
            }
        } else if tickCount % 4 == 0,
                  let pixelBuffer = output.copyPixelBuffer(
                      forItemTime: itemTime, itemTimeForDisplay: nil) {
            deliver(pixelBuffer,
                    analyzed: scopesEnabled && tickCount % 16 == 0)
        }
    }
}
