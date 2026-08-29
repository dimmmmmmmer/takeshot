import AppKit
import CaptureCore
import CoreMedia
import CoreVideo
import Foundation

/// A demo signal source for debugging the GUI and auto-takes without a board:
/// synthetic 1080p25 frames (SMPTE-like bars, a moving strip, TC burn-in)
/// and Rec Run timecode — running only while the "camera" records.
///
/// **There is no `--demo` gate.** This is in `shippingBackends()`
/// unconditionally and `isAvailable` is `true`, so it appears in EVERY build's
/// device list. Two documents claimed a flag for months and no such code has
/// ever existed.
///
/// That is load-bearing for a published release, which is built with no vendor
/// SDKs: `CDeckLink` is then a stub that can see no board, and this is the only
/// entry in the list. The cost is worth knowing before anyone goes looking for
/// it — `backendAvailable` is therefore always true, so `sdk_not_connected` is
/// unreachable in a shipping build, and an operator who plugs a real
/// UltraStudio into a downloaded build is told "no devices found" rather than
/// that this binary was never compiled to see one. `DeckLinkDiagnosis` knows
/// the difference and the diagnostics bundle reports it.
final class MockCaptureBackend: CaptureBackend {
    static let deviceID = "mock-source"

    weak var delegate: CaptureBackendDelegate?
    var isAvailable: Bool { true }
    /// Matches the 16-channel SDI-style embed the demo signal generates.
    var embeddedAudioChannels: Int { Self.audioChannels }
    static let audioChannels = 16

    /// Demo source — "camera in standby": TC frozen (Rec Run), signal live.
    /// Recording is manual via the REC button only; auto-detection fires on a real
    /// camera once TC starts running.
    private let isCameraRecording = false

    private let queue = DispatchQueue(label: "takeshot.mock-source")
    private var timer: DispatchSourceTimer?
    private var pixelBufferPool: CVPixelBufferPool?
    private var frameCounter = 0
    private var timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25)
    private var audioFormatCache: CMAudioFormatDescription?
    private var audioPhaseL: Double = 0
    private var audioPhaseR: Double = 0

    private static let format = CaptureFormat(width: 1920, height: 1080, frameRate: 25,
                                              timecodeFPS: 25, name: "Demo 1080p25")

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

    // MARK: - frame generation (on queue)

    private func emitFrame() {
        frameCounter += 1
        guard let pixelBuffer = renderFrame() else { return }
        let pts = CMTime(value: CMTimeValue(frameCounter * 40), timescale: 1000)
        delegate?.backend(self, didReceive: CapturedFrame(
            pixelBuffer: pixelBuffer, pts: pts, timecode: timecode))
        emitAudio(ptsSeconds: Double(frameCounter) * 0.04)
    }

    /// 16 channels (like Blackmagic SDI embed): 1-2 are sines with "breathing"
    /// volume, the rest are the same sines at decreasing level, so the meters
    /// show a live picture across all tracks.
    private func emitAudio(ptsSeconds: Double) {
        let channels = 16
        let sampleFrames = 1920 // 40 ms at 48 kHz
        var samples = [Int16](repeating: 0, count: sampleFrames * channels)
        let stepL = 2.0 * Double.pi * 440.0 / 48_000.0
        let stepR = 2.0 * Double.pi * 330.0 / 48_000.0
        for frame in 0..<sampleFrames {
            // The breathing envelope is evaluated per sample. Evaluated once
            // per buffer it stair-steps at every 40 ms boundary — a 25 Hz
            // click track riding on the tone, audible as steady crackle.
            let t = ptsSeconds + Double(frame) / 48_000.0
            let ampL = 0.28 + 0.22 * sin(t * 0.9)
            let ampR = 0.22 + 0.18 * sin(t * 0.6 + 1.3)
            audioPhaseL += stepL
            audioPhaseR += stepR
            let left = sin(audioPhaseL) * ampL
            let right = sin(audioPhaseR) * ampR
            for channel in 0..<channels {
                let source = channel % 2 == 0 ? left : right
                let falloff = pow(0.72, Double(channel / 2))
                samples[frame * channels + channel] = Int16(source * falloff * 32_000)
            }
        }
        let sampleBuffer = samples.withUnsafeBytes { raw -> CMSampleBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return PCMAudio.makeSampleBuffer(bytes: base, sampleFrames: sampleFrames,
                                             channelCount: channels, ptsSeconds: ptsSeconds,
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
        // color bars
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

        // moving strip — shows the signal is "live"
        let stripeX = CGFloat(frameCounter % 125) / 125.0 * CGFloat(width)
        context.setFillColor(CGColor(gray: 1.0, alpha: 0.9))
        context.fill(CGRect(x: stripeX, y: 0, width: 6, height: CGFloat(height)))

        // badge with TC and the "camera" status
        context.setFillColor(CGColor(gray: 0, alpha: 0.75))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: 160))

        let text = "\(timecode)  \(isCameraRecording ? "● REC" : "STBY")"
        drawBadgeText(text, in: context, at: CGPoint(x: 40, y: 40),
                      color: isCameraRecording
                          ? CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1)
                          : CGColor(gray: 1, alpha: 1))
    }

    /// The font is built once, up front, and the line is drawn with Core Text
    /// straight into the context.
    ///
    /// This used to be `NSString.draw(at:withAttributes:)` through an
    /// `NSGraphicsContext`, called from the source's own dispatch queue. AppKit
    /// text drawing is not thread-safe, and it killed the process: reaching
    /// Core Text's font machinery first from a background thread returned a nil
    /// font, and `CTLineCreateWithAttributedString` then raised
    /// "attempt to insert nil object from objects[0]". It is rare enough to
    /// look like bad luck, and this source is in every shipped build's device
    /// list (there is no `--demo` gate — see the type's note), with multicam
    /// running two of these sources at once.
    ///
    /// `nonisolated(unsafe)`: a `CTFont` is an immutable Core Foundation object
    /// that predates `Sendable`, built once and thereafter only read — by
    /// `CTLineCreateWithAttributedString`, on the source's own queue. The
    /// static is the fix rather than the risk: what killed the process was the
    /// font machinery being reached FIRST from a background thread, and
    /// `swift_once` around this line is what stops that.
    nonisolated(unsafe) private static let badgeFont: CTFont =
        CTFontCreateWithName("Menlo-Bold" as CFString, 72, nil)

    private func drawBadgeText(_ text: String, in context: CGContext,
                               at origin: CGPoint, color: CGColor) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: Self.badgeFont,
            .foregroundColor: color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = origin
        CTLineDraw(line, context)
    }
}
