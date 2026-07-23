import AVFoundation
import CaptureCore
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

    func setScopesEnabled(_ on: Bool) {
        queue.async {
            self.scopesEnabled = on
            // paused player delivers no new frames — analyze the current one
            // right away instead of showing "waiting for signal"
            if on, let buffer = self.lastBuffer,
               let scopeData = ScopeAnalyzer.analyze(buffer) {
                DispatchQueue.main.async { self.onScopeData?(scopeData) }
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
            // reach the layers/scopes — including windows (external/fullscreen)
            // opened after the pause
            if tickCount % 15 == 0,
               let pixelBuffer = output.copyPixelBuffer(
                   forItemTime: itemTime, itemTimeForDisplay: nil) {
                deliver(pixelBuffer, analyzed: scopesEnabled && lastBuffer == nil)
            }
            return
        }
        guard let pixelBuffer = output.copyPixelBuffer(
            forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
        deliver(pixelBuffer, analyzed: scopesEnabled && tickCount % 8 == 0)
    }

    private func deliver(_ pixelBuffer: CVPixelBuffer, analyzed: Bool) {
        lastBuffer = pixelBuffer
        if analyzed, let scopeData = ScopeAnalyzer.analyze(pixelBuffer) {
            DispatchQueue.main.async { self.onScopeData?(scopeData) }
        }
        for layer in [mainLayer, fullscreenLayer, externalLayer] {
            layer.present(pixelBuffer)
        }
    }
}
