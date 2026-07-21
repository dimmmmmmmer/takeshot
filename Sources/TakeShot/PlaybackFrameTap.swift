import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

/// Единый рендер плейбека: кадры тянутся из AVPlayer через AVPlayerItemVideoOutput
/// (после videoComposition, т.е. уже с LUT) и рисуются AVSampleBufferDisplayLayer —
/// тем же типом слоя, что и лайв. Никакого AVPlayerLayer — лайв и плейбек проходят
/// одинаковый путь отображения, шторка/бленд сравнивают честно.
///
/// Слоёв три (главное окно, фулскрин, внешний монитор): CALayer живёт только
/// в одном вью, поэтому каждому окну — свой.
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

    /// Подключиться к новому клипу (старый output снимается).
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

    // MARK: - на queue

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
        timer.schedule(deadline: .now(), repeating: .milliseconds(16)) // ~60 Гц опрос
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

        tagRec709IfUntagged(pixelBuffer)

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

    private func tagRec709IfUntagged(_ pixelBuffer: CVPixelBuffer) {
        guard CVBufferGetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                                    nil) == nil else { return }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
}
