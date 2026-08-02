import CaptureCore
import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import TakeShotKit

/// The playback tap is the single render path every viewer surface draws from,
/// so what it hands out has to be exactly right in two directions at once:
/// an untouched frame must come out as the very same buffer (the "no render
/// needed" shortcut — losing it puts a CoreImage round trip on every one of the
/// 60 idle ticks a second), and a frame with a LUT or a compare on it must come
/// out composited, not passed through.
struct ModelPlaybackTapTests {
    // MARK: - fixtures

    private func buffer(_ level: UInt8, width: Int = 64, height: Int = 64)
        -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        guard let out else { fatalError("could not allocate a test frame") }
        CVPixelBufferLockBaseAddress(out, [])
        if let base = CVPixelBufferGetBaseAddress(out) {
            let rowBytes = CVPixelBufferGetBytesPerRow(out)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = bytes + y * rowBytes
                for x in 0..<width {
                    row[x * 4] = level          // B
                    row[x * 4 + 1] = level      // G
                    row[x * 4 + 2] = level      // R
                    // opaque: CoreImage reads 32BGRA as premultiplied, so a
                    // partial alpha would silently rescale every value read back
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(out, [])
        return out
    }

    private struct Pixel {
        var blue = 0
        var green = 0
        var red = 0

        var description: String { "\(red)/\(green)/\(blue)" }
    }

    /// The top-left pixel of a BGRA buffer.
    private func pixel(_ buffer: CVPixelBuffer) -> Pixel {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Pixel() }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        return Pixel(blue: Int(bytes[0]), green: Int(bytes[1]), red: Int(bytes[2]))
    }

    /// Collects what the tap delivers; the handler fires on the tap queue.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [CVPixelBuffer] = []

        var all: [CVPixelBuffer] {
            lock.lock()
            defer { lock.unlock() }
            return buffers
        }

        var last: CVPixelBuffer? { all.last }

        func record(_ buffer: CVPixelBuffer) {
            lock.lock()
            buffers.append(buffer)
            lock.unlock()
        }
    }

    private func tapWithCollector() -> (PlaybackFrameTap, Collector) {
        let tap = PlaybackFrameTap()
        let collector = Collector()
        tap.setOnDisplayFrame { collector.record($0) }
        return (tap, collector)
    }

    /// Everything the tap does is queue-async; drain it before asserting.
    private func drain(_ tap: PlaybackFrameTap) {
        tap.queue.sync {}
    }

    // MARK: - the pass-through shortcut

    /// A still or a paused clip with no LUT and no compare is delivered as the
    /// identical buffer — no pool allocation, no CoreImage task.
    @Test func anUntouchedFrameIsDeliveredWithoutBeingRerendered() {
        let (tap, collector) = tapWithCollector()
        let source = buffer(64)
        tap.attachStill(source)
        drain(tap)

        #expect(collector.all.count == 1)
        #expect(collector.last === source,
                "the frame was re-rendered even though nothing touched it")
    }

    @Test func theCurrentBufferIsTheFrameLastTakenIn() {
        let tap = PlaybackFrameTap()
        #expect(tap.currentBuffer() == nil)
        let source = buffer(90)
        tap.attachStill(source)
        drain(tap)
        #expect(tap.currentBuffer() === source)
    }

    // MARK: - the preview LUT

    /// With a LUT on, the delivered frame is a rendered copy carrying the LUT —
    /// not the source. This is the difference between the operator seeing the
    /// show LUT and seeing log.
    @Test func aLUTIsBakedIntoWhatTheViewerGets() throws {
        let (tap, collector) = tapWithCollector()
        let invert = CIFilter(name: "CIColorInvert")
        tap.setLUT(invert, intensity: 1)
        let source = buffer(40)
        tap.attachStill(source)
        drain(tap)

        let delivered = try #require(collector.last)
        #expect(delivered !== source)
        let sample = pixel(delivered)
        #expect(sample.red > 180 && sample.green > 180 && sample.blue > 180,
                "40 inverted should be near 215, got \(sample.description)")
        // …and the source buffer itself was not modified in place
        #expect(pixel(source).red == 40)
    }

    /// Intensity is a mix against the original, so 0 has to give the original
    /// back — the slider's left stop is how an operator checks the clean signal.
    @Test func lutIntensityZeroLeavesTheImageAlone() throws {
        let (tap, collector) = tapWithCollector()
        tap.setLUT(CIFilter(name: "CIColorInvert"), intensity: 0)
        tap.attachStill(buffer(40))
        drain(tap)

        let delivered = try #require(collector.last)
        let sample = pixel(delivered)
        #expect(abs(sample.red - 40) <= 2 && abs(sample.green - 40) <= 2
                && abs(sample.blue - 40) <= 2,
                "intensity 0 changed the image: \(sample.description)")
    }

    /// Dragging the intensity slider re-renders the frame that is already on
    /// screen; a paused player pushes nothing new, so nothing would update.
    @Test func changingIntensityRedeliversThePausedFrame() throws {
        let (tap, collector) = tapWithCollector()
        tap.setLUT(CIFilter(name: "CIColorInvert"), intensity: 0)
        tap.attachStill(buffer(40))
        drain(tap)
        let before = collector.all.count

        tap.setLUTIntensity(1)
        drain(tap)
        #expect(collector.all.count == before + 1)
        let sample = pixel(try #require(collector.last))
        #expect(sample.red > 180, "the new intensity did not reach the screen")
    }

    /// Removing the LUT has to go back to the pass-through shortcut, not leave
    /// an identity render in the path forever.
    @Test func clearingTheLUTRestoresThePassThrough() {
        let (tap, collector) = tapWithCollector()
        tap.setLUT(CIFilter(name: "CIColorInvert"), intensity: 1)
        let source = buffer(40)
        tap.attachStill(source)
        drain(tap)
        #expect(collector.last !== source)

        tap.setLUT(nil, intensity: 1)
        drain(tap)
        #expect(collector.last === source)
    }

    // MARK: - compare

    /// Compare composites the playback frame against the live signal. Both
    /// halves have to be present in the result — a wipe that shows only one side
    /// is the failure that makes the whole feature look broken.
    @Test func aWipeShowsBothSidesOfTheSeam() throws {
        let (tap, collector) = tapWithCollector()
        let playback = buffer(0x20)     // dark
        let live = buffer(0xE0)         // bright
        tap.setLiveBufferProvider { live }
        tap.setCompare(.wipe(axis: .vertical, position: 0.5))
        tap.attachStill(playback)
        drain(tap)

        let delivered = try #require(collector.last)
        #expect(delivered !== playback)
        #expect(CVPixelBufferGetWidth(delivered) == 64)

        CVPixelBufferLockBaseAddress(delivered, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(delivered, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(delivered))
        let rowBytes = CVPixelBufferGetBytesPerRow(delivered)
        let row = base.assumingMemoryBound(to: UInt8.self) + 32 * rowBytes
        let left = Int(row[4 * 4])          // x = 4
        let right = Int(row[4 * 59])        // x = 59
        #expect(left < 0x60, "left of the seam is not the playback frame: \(left)")
        #expect(right > 0xA0, "right of the seam is not the live frame: \(right)")
    }

    /// A blend with no live signal to blend against must fall back to the
    /// playback frame rather than deliver black.
    @Test func compareWithNoLiveSourceFallsBackToPlayback() throws {
        let (tap, collector) = tapWithCollector()
        let playback = buffer(0x50)
        tap.setCompare(.blend(opacity: 0.5))
        tap.attachStill(playback)
        drain(tap)

        let delivered = try #require(collector.last)
        let sample = pixel(delivered)
        #expect(abs(sample.red - 0x50) <= 2 && abs(sample.green - 0x50) <= 2
                && abs(sample.blue - 0x50) <= 2,
                "expected the untouched playback frame, got \(sample.description)")
    }

    /// Difference delivers the measured |A−B|, exactly: playback at 0x20
    /// against live at 0x2A is 10 codes on every channel, and the gain
    /// multiplies the measurement, not the picture.
    @Test func differenceDeliversTheMeasuredDeltaAtTheDialledGain() throws {
        let (tap, collector) = tapWithCollector()
        let live = buffer(0x2A)
        tap.setLiveBufferProvider { live }

        tap.setCompare(.difference(gain: 1))
        tap.attachStill(buffer(0x20))
        drain(tap)
        let one = pixel(try #require(collector.last))
        #expect(one.red == 10 && one.green == 10 && one.blue == 10,
                "×1 measured \(one.description), expected 10")

        tap.setCompare(.difference(gain: 4))
        drain(tap)
        let four = pixel(try #require(collector.last))
        #expect(four.red == 40 && four.green == 40 && four.blue == 40,
                "×4 measured \(four.description), expected 40")
    }

    /// The playback LUT never reaches the measurement: with an invert loaded,
    /// difference still reads the RAW playback frame against the live one.
    /// Wipe and blend rightly show the LUT — difference is the one mode whose
    /// output is numbers, and the look must not bend them.
    @Test func differenceIgnoresTheActiveLUT() throws {
        let (tap, collector) = tapWithCollector()
        tap.setLUT(CIFilter(name: "CIColorInvert"), intensity: 1)
        let live = buffer(0x2A)
        tap.setLiveBufferProvider { live }
        tap.setCompare(.difference(gain: 1))
        tap.attachStill(buffer(0x20))
        drain(tap)

        let sample = pixel(try #require(collector.last))
        // measured post-LUT this would be |invert(0x20) − 0x2A| = 181
        #expect(sample.red == 10 && sample.green == 10 && sample.blue == 10,
                "the LUT bent the measurement: \(sample.description)")
    }

    /// The difference reads the live signal at the PRE-LUT stage while the
    /// wipe keeps reading the display stage — one back half each, and they
    /// must not get crossed.
    @Test func differenceReadsThePreLUTLiveHalf() throws {
        let (tap, collector) = tapWithCollector()
        let display = buffer(0xE0) // what the viewer shows (LUT baked)
        let clean = buffer(0x2A)   // the same frame before the LUT
        tap.setLiveBufferProvider { display }
        tap.setLivePreLUTBufferProvider { clean }

        tap.setCompare(.difference(gain: 1))
        tap.attachStill(buffer(0x20))
        drain(tap)
        let measured = pixel(try #require(collector.last))
        #expect(measured.red == 10,
                "difference read the display half: \(measured.description)")

        // the wipe still shows the display half on its side of the seam
        tap.setCompare(.wipe(axis: .vertical, position: 0.5))
        drain(tap)
        let delivered = try #require(collector.last)
        CVPixelBufferLockBaseAddress(delivered, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(delivered, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(delivered))
        let rowBytes = CVPixelBufferGetBytesPerRow(delivered)
        let row = base.assumingMemoryBound(to: UInt8.self) + 32 * rowBytes
        #expect(Int(row[4 * 59]) == 0xE0,
                "the wipe lost its display half: \(Int(row[4 * 59]))")
    }

    /// Turning compare back off restores the shortcut.
    @Test func turningCompareOffRestoresThePassThrough() {
        let (tap, collector) = tapWithCollector()
        let playback = buffer(0x20)
        let live = buffer(0xE0)
        tap.setLiveBufferProvider { live }
        tap.setCompare(.blend(opacity: 0.5))
        tap.attachStill(playback)
        drain(tap)
        #expect(collector.last !== playback)

        tap.setCompare(.off)
        drain(tap)
        #expect(collector.last === playback)
    }

    // MARK: - lifecycle

    /// The display handler is read on the tap queue while it is set from the
    /// main actor; clearing it must actually stop deliveries (the hardware
    /// playout is torn down that way).
    @Test func clearingTheDisplayHandlerStopsDeliveries() {
        let (tap, collector) = tapWithCollector()
        tap.attachStill(buffer(64))
        drain(tap)
        let before = collector.all.count

        tap.setOnDisplayFrame(nil)
        tap.attachStill(buffer(128))
        drain(tap)
        #expect(collector.all.count == before)
    }

    /// A tap nobody has given a frame to is inert rather than crashing — the
    /// window is built before any clip is chosen.
    @Test func anIdleTapDeliversNothing() {
        let (tap, collector) = tapWithCollector()
        tap.setRunning(true)
        tap.setScopesEnabled(true)
        tap.setCompare(.off)
        tap.setLUTIntensity(0.5)
        tap.detach()
        drain(tap)
        #expect(collector.all.isEmpty)
        #expect(tap.currentBuffer() == nil)
    }
}
