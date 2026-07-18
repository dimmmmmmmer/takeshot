import AppKit
import CaptureCore
import CoreMedia
import CoreVideo
import Foundation

/// Демо-источник сигнала для отладки GUI и авто-дублей без платы:
/// синтетические 1080p25-кадры (SMPTE-подобные бары, бегущая полоса, TC burn-in)
/// и таймкод в режиме Rec Run — идёт только когда «камера» пишет.
final class MockCaptureBackend: CaptureBackend {
    static let deviceID = "mock-source"

    weak var delegate: CaptureBackendDelegate?
    var isAvailable: Bool { true }

    /// «REC на камере»: пока true — TC бежит, false — стоит.
    private(set) var isCameraRecording = false

    private let queue = DispatchQueue(label: "takeshot.mock-source")
    private var timer: DispatchSourceTimer?
    private var pixelBufferPool: CVPixelBufferPool?
    private var frameCounter = 0
    private var timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25)
    private var audioFormatCache: CMAudioFormatDescription?
    private var audioPhaseL: Double = 0
    private var audioPhaseR: Double = 0

    private static let format = CaptureFormat(width: 1920, height: 1080, frameRate: 25,
                                              timecodeFPS: 25, name: "Демо 1080p25")

    func devices() -> [CaptureDeviceInfo] {
        [CaptureDeviceInfo(id: Self.deviceID, name: L("mock_device_name"))]
    }

    func startCapture(deviceID: String) throws {
        stopCapture()
        delegate?.backend(self, didDetectFormat: Self.format)
        delegate?.backend(self, signalPresent: true)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(40)) // 25 fps
        timer.setEventHandler { [weak self] in
            self?.emitFrame()
        }
        timer.resume()
        self.timer = timer
    }

    func stopCapture() {
        timer?.cancel()
        timer = nil
    }

    func setCameraRecording(_ recording: Bool) {
        queue.async { self.isCameraRecording = recording }
    }

    // MARK: - генерация кадров (на queue)

    private func emitFrame() {
        if isCameraRecording {
            timecode = timecode.advanced(by: 1)
        }
        frameCounter += 1
        guard let pixelBuffer = renderFrame() else { return }
        let pts = CMTime(value: CMTimeValue(frameCounter * 40), timescale: 1000)
        delegate?.backend(self, didReceiveFrame: pixelBuffer, pts: pts,
                          timecode: timecode, vancTrigger: nil, ancillaryPackets: [])
        emitAudio(ptsSeconds: Double(frameCounter) * 0.04)
    }

    /// Стерео-синус с «дыханием» громкости — чтобы метры уровня жили в демо.
    private func emitAudio(ptsSeconds: Double) {
        let sampleFrames = 1920 // 40 мс при 48 кГц
        var samples = [Int16](repeating: 0, count: sampleFrames * 2)
        let t = Double(frameCounter) * 0.04
        let ampL = 0.28 + 0.22 * sin(t * 0.9)
        let ampR = 0.22 + 0.18 * sin(t * 0.6 + 1.3)
        let stepL = 2.0 * Double.pi * 440.0 / 48_000.0
        let stepR = 2.0 * Double.pi * 330.0 / 48_000.0
        for frame in 0..<sampleFrames {
            audioPhaseL += stepL
            audioPhaseR += stepR
            samples[frame * 2] = Int16(sin(audioPhaseL) * ampL * 32_000)
            samples[frame * 2 + 1] = Int16(sin(audioPhaseR) * ampR * 32_000)
        }
        let sampleBuffer = samples.withUnsafeBytes { raw -> CMSampleBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return PCMAudio.makeSampleBuffer(bytes: base, sampleFrames: sampleFrames,
                                             channelCount: 2, ptsSeconds: ptsSeconds,
                                             formatCache: &audioFormatCache)
        }
        if let sampleBuffer {
            delegate?.backend(self, didReceiveAudio: sampleBuffer)
        }
    }

    private func renderFrame() -> CVPixelBuffer? {
        let width = 1920, height = 1080
        if pixelBufferPool == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary,
                                    &pixelBufferPool)
        }
        guard let pool = pixelBufferPool else { return nil }
        var pixelBufferOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBufferOut)
        guard let pixelBuffer = pixelBufferOut else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        drawTestPattern(in: context, width: width, height: height)
        return pixelBuffer
    }

    private func drawTestPattern(in context: CGContext, width: Int, height: Int) {
        // цветные бары
        let barColors: [CGColor] = [
            CGColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1),
            CGColor(red: 0.75, green: 0.75, blue: 0.00, alpha: 1),
            CGColor(red: 0.00, green: 0.75, blue: 0.75, alpha: 1),
            CGColor(red: 0.00, green: 0.75, blue: 0.00, alpha: 1),
            CGColor(red: 0.75, green: 0.00, blue: 0.75, alpha: 1),
            CGColor(red: 0.75, green: 0.00, blue: 0.00, alpha: 1),
            CGColor(red: 0.00, green: 0.00, blue: 0.75, alpha: 1),
        ]
        let barWidth = CGFloat(width) / CGFloat(barColors.count)
        for (i, color) in barColors.enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(x: CGFloat(i) * barWidth, y: 0,
                                width: barWidth + 1, height: CGFloat(height)))
        }

        // бегущая полоса — видно, что сигнал «живой»
        let stripeX = CGFloat(frameCounter % 125) / 125.0 * CGFloat(width)
        context.setFillColor(CGColor(gray: 1.0, alpha: 0.9))
        context.fill(CGRect(x: stripeX, y: 0, width: 6, height: CGFloat(height)))

        // плашка с TC и статусом «камеры»
        context.setFillColor(CGColor(gray: 0, alpha: 0.75))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: 160))

        let text = "\(timecode)  \(isCameraRecording ? "● REC" : "STBY")" as NSString
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        text.draw(at: NSPoint(x: 40, y: 40), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 72, weight: .bold),
            .foregroundColor: isCameraRecording ? NSColor.red : NSColor.white,
        ])
        NSGraphicsContext.restoreGraphicsState()
    }
}
