import AVFoundation
import CaptureCore
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

/// Unified playback render: frames are pulled from AVPlayer via AVPlayerItemVideoOutput
/// (after videoComposition, i.e. already with the LUT) and drawn by AVSampleBufferDisplayLayer
/// — the same layer type as live. No AVPlayerLayer — live and playback go through the
/// same display path, so wipe/blend compare fairly.
///
/// There are three layers (main window, fullscreen, external monitor): a CALayer lives
/// in only one view, so each window gets its own.
final class PlaybackFrameTap: @unchecked Sendable {
    let mainLayer = AVSampleBufferDisplayLayer()
    let fullscreenLayer = AVSampleBufferDisplayLayer()
    let externalLayer = AVSampleBufferDisplayLayer()

    private let queue = DispatchQueue(label: "takeshot.playback-tap", qos: .userInitiated)
    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private var timer: DispatchSourceTimer?
    private var formatDescription: CMVideoFormatDescription?
    private var running = false
    private var scopesEnabled = false
    private var tickCount = 0

    /// Scope data from playback frames (~8 Hz while enabled), on the main queue.
    var onScopeData: ((ScopeData) -> Void)?

    func setScopesEnabled(_ on: Bool) {
        queue.async { self.scopesEnabled = on }
    }

    /// Attach to a new clip (the old output is removed).
    func attach(to item: AVPlayerItem) {
        queue.async {
            self.detachLocked()
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
            item.add(output)
            self.output = output
            self.item = item
            self.formatDescription = nil
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
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = output.copyPixelBuffer(
                forItemTime: itemTime, itemTimeForDisplay: nil) else { return }

        normalizeColorTags(pixelBuffer)

        // scopes: playback polls at ~60 Hz; analyze every 8th delivered frame
        tickCount += 1
        if scopesEnabled, tickCount % 8 == 0,
           let scopeData = ScopeAnalyzer.analyze(pixelBuffer) {
            DispatchQueue.main.async { self.onScopeData?(scopeData) }
        }

        if formatDescription.map({
            !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer)
        }) ?? true {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescriptionOut: &description)
            formatDescription = description
        }
        guard let formatDescription else { return }

        for layer in [mainLayer, fullscreenLayer, externalLayer] {
            var timing = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                decodeTimeStamp: .invalid)
            var sampleBuffer: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescription: formatDescription, sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { continue }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: true) as? [CFMutableDictionary],
               let first = attachments.first {
                CFDictionarySetValue(
                    first,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if layer.status == .failed {
                layer.flush()
            }
            layer.enqueue(sampleBuffer)
        }
    }

    /// The decoder tags frames with a display-referred colorspace (CoreMedia709),
    /// while live is described by scene-referred ITU_R_709 tags — ColorSync maps
    /// them to the display differently, hence the live/playback contrast mismatch.
    /// Bring playback frames to exactly the same description as live.
    private func normalizeColorTags(_ pixelBuffer: CVPixelBuffer) {
        CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferCGColorSpaceKey)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
}
