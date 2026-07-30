import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import Testing

@testable import CaptureCore

/// Collects presented frames off the display queue, optionally holding each
/// delivery up — which is what makes the coalescing observable.
final class PreviewCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [CVPixelBuffer] = []
    private let stall: TimeInterval

    init(stall: TimeInterval = 0) {
        self.stall = stall
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffers.count
    }

    var last: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffers.last
    }

    func record(_ buffer: CVPixelBuffer) {
        lock.lock()
        buffers.append(buffer)
        lock.unlock()
        if stall > 0 { Thread.sleep(forTimeInterval: stall) }
    }
}

/// Shared probes for the two preview suites: a pipeline that can never open a
/// take, and solid frames the display path can be identified by.
enum PreviewProbe {
    static func makePipeline(isRGB444: Bool = false) -> CapturePipeline {
        var settings = CaptureSettings()
        // manual: nothing in these suites may open a take, so the destination
        // folder is never created and never written to
        settings.detectionMode = .manual
        let pipeline = CapturePipeline(config: .init(settings: settings,
                                                     takeNumber: 1))
        pipeline.handleFormat(CaptureFormat(width: 64, height: 32, frameRate: 25,
                                            timecodeFPS: 25, name: "test",
                                            isRGB444: isRGB444))
        return pipeline
    }

    static func push(_ pipeline: CapturePipeline, _ buffer: CVPixelBuffer,
                     frame index: Int) {
        pipeline.handleFrame(pixelBuffer: buffer,
                            pts: CMTime(value: CMTimeValue(index * 40),
                                        timescale: 1000),
                            timecode: nil, vancTrigger: nil)
    }

    /// A solid, OPAQUE BGRA frame — the level is how a test tells one frame from
    /// another after it has been through the display path. Opaque matters:
    /// CoreImage reads 32BGRA as premultiplied and a partial alpha rescales
    /// every value read back.
    static func frame(_ level: UInt8) -> CVPixelBuffer {
        let buffer = TestMedia.pixelBuffer(width: 64, height: 32)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<32 {
                let row = bytes + y * rowBytes
                for x in 0..<64 {
                    row[x * 4] = level
                    row[x * 4 + 1] = level
                    row[x * 4 + 2] = level
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// One BGRA channel (0 = blue, 1 = green, 2 = red) of the pixel at
    /// `fraction` across the middle row.
    static func level(of buffer: CVPixelBuffer,
                      atFractionX fraction: Double = 0,
                      channel: Int = 0) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let x = min(width - 1, max(0, Int(Double(width) * fraction)))
        let row = base.assumingMemoryBound(to: UInt8.self) + (height / 2) * rowBytes
        return Int(row[x * 4 + channel])
    }
}

/// The pipeline's display path: which surfaces a frame reaches, and what
/// happens when a surface cannot keep up.
///
/// Two rules here are load bearing on set. Presentation is latest-wins and off
/// the capture queue, because `nextDrawable()` parks for up to a second on an
/// occluded window and a stall on the capture queue is dropped frames in
/// someone's take. And the frame published for the compare provider is the CLEAN
/// processed one, never the composite — pinning a reference while a wipe is on
/// screen would otherwise pin the wipe.
@Suite struct PreviewDisplayPathTests {
    // MARK: - routing

    /// Frames reach whatever is registered, and the clean frame is published for
    /// the compare provider at the same time.
    @Test func aFrameReachesTheDisplayHandlerAndTheCompareProvider() async throws {
        let pipeline = PreviewProbe.makePipeline()
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0) }
        defer { pipeline.setOnDisplayFrame(nil) }

        PreviewProbe.push(pipeline, PreviewProbe.frame(0x40), frame: 1)
        await TestWait.until { collector.count > 0 }

        let presented = try #require(collector.last, "nothing was presented")
        #expect(PreviewProbe.level(of: presented) == 0x40)
        let pinned = try #require(pipeline.currentPreviewBuffer(),
                                  "the compare provider has no frame to offer")
        #expect(PreviewProbe.level(of: pinned) == 0x40)
    }

    /// Clearing the handler has to actually stop deliveries — the hardware
    /// mirror is torn down that way and the feeder behind it is released.
    @Test func clearingTheDisplayHandlerStopsDeliveries() async {
        let pipeline = PreviewProbe.makePipeline()
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0) }

        PreviewProbe.push(pipeline, PreviewProbe.frame(0x40), frame: 1)
        await TestWait.until { collector.count > 0 }
        pipeline.setOnDisplayFrame(nil)
        let settled = collector.count

        for index in 2...6 {
            PreviewProbe.push(pipeline, PreviewProbe.frame(0x80), frame: index)
        }
        await TestWait.until({ collector.count > settled }, timeout: .seconds(1))
        #expect(collector.count == settled,
                "frames kept reaching a torn-down output")
    }

    /// Presentation is latest-wins: a surface that cannot keep up is handed the
    /// NEWEST frame and the ones behind it are dropped. The alternative is a
    /// queue that grows until the capture path stalls behind it.
    @Test func aSlowSurfaceGetsTheNewestFrameAndNotABacklog() async throws {
        let pipeline = PreviewProbe.makePipeline()
        // 20 ms a delivery: a surface parked the way an occluded window is
        let collector = PreviewCollector(stall: 0.02)
        pipeline.setOnDisplayFrame { collector.record($0) }
        defer { pipeline.setOnDisplayFrame(nil) }

        let pushed = 40
        var buffers: [CVPixelBuffer] = [] // hold them: the levels identify them
        for index in 0..<pushed {
            let buffer = PreviewProbe.frame(UInt8(0x10 + index * 4))
            buffers.append(buffer)
            PreviewProbe.push(pipeline, buffer, frame: index + 1)
        }
        let newest = 0x10 + (pushed - 1) * 4
        await TestWait.until({
            collector.last.map { PreviewProbe.level(of: $0) } == newest
        }, timeout: .seconds(10))

        let presented = try #require(collector.last)
        #expect(PreviewProbe.level(of: presented) == newest,
                "the newest frame never reached the surface")
        // every frame delivered means a slow surface now backs the queue up
        #expect(collector.count < pushed,
                "all \(pushed) frames were delivered — the coalescing is gone")
        #expect(buffers.count == pushed)
    }

    // MARK: - the pinned reference

    /// The pinned reference is composited into what the SCREEN gets, while the
    /// compare provider keeps offering the clean frame.
    @Test func thePinnedReferenceGoesToTheScreenAndNotToTheProvider() async throws {
        let pipeline = PreviewProbe.makePipeline()
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0) }
        defer { pipeline.setOnDisplayFrame(nil) }

        pipeline.setPreviewReference(buffer: PreviewProbe.frame(0xE0))
        pipeline.setPreviewCompare(.wipe(axis: .vertical, position: 0.5))

        PreviewProbe.push(pipeline, PreviewProbe.frame(0x20), frame: 1)
        await TestWait.until { collector.count > 0 }

        let composite = try #require(collector.last)
        #expect(CVPixelBufferGetWidth(composite) == 64)
        let left = PreviewProbe.level(of: composite, atFractionX: 0.1)
        let right = PreviewProbe.level(of: composite, atFractionX: 0.9)
        #expect(left > 0xA0, "left of the seam is not the reference: \(left)")
        #expect(right < 0x60, "right of the seam is not the live frame: \(right)")

        // …and the provider still hands out the clean frame
        let clean = try #require(pipeline.currentPreviewBuffer())
        #expect(PreviewProbe.level(of: clean) == 0x20)
    }

    /// With the compare off, a pinned reference must not be composited into
    /// anything: the reference is armed long before the operator wipes to it.
    @Test func aPinnedReferenceWithTheCompareOffChangesNothing() async throws {
        let pipeline = PreviewProbe.makePipeline()
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0) }
        defer { pipeline.setOnDisplayFrame(nil) }

        pipeline.setPreviewReference(buffer: PreviewProbe.frame(0xE0))
        let source = PreviewProbe.frame(0x20)
        PreviewProbe.push(pipeline, source, frame: 1)
        await TestWait.until { collector.count > 0 }

        let presented = try #require(collector.last)
        #expect(presented === source,
                "the frame was composited with the compare switched off")
    }

    /// Pinning from the live signal takes a DEEP copy: the frame it is handed
    /// comes out of a pool that is reused within a few frames, so keeping the
    /// buffer itself would leave the reference showing whatever is live.
    @Test func pinningFromTheLiveSignalCopiesTheFrame() async throws {
        let pipeline = PreviewProbe.makePipeline()
        let source = PreviewProbe.frame(0x30)
        PreviewProbe.push(pipeline, source, frame: 1)
        await TestWait.until { pipeline.currentPreviewBuffer() != nil }

        pipeline.pinReferenceFromCurrentFrame()
        var pinned: CVPixelBuffer?
        pipeline.queue.sync { pinned = pipeline.previewReference }

        let reference = try #require(pinned, "nothing was pinned")
        #expect(reference !== source, "the pin kept the pooled buffer itself")
        #expect(PreviewProbe.level(of: reference) == 0x30)

        // dropping the reference disarms the compare
        pipeline.setPreviewReference(buffer: nil)
        var cleared: CVPixelBuffer?
        pipeline.queue.sync { cleared = pipeline.previewReference }
        #expect(cleared == nil)
    }

    // MARK: - sinks

    /// Registration and the per-surface state that joins with it. Every mount
    /// registers its OWN layer — a shared one was stolen between views and the
    /// survivor drew with the thief's geometry.
    @Test func sinksJoinAndLeaveWithTheCurrentPresentationState() {
        let pipeline = PreviewProbe.makePipeline()
        let layer = MetalPreviewLayer()
        pipeline.setPreviewLetterbox(CIColor(red: 0.5, green: 0, blue: 0.25))
        var assist = ViewAssist()
        assist.desqueeze = 1.33
        pipeline.setViewAssist(assist)

        pipeline.addDisplaySink(layer)
        #expect(pipeline.displaySinks.all().count == 1)
        #expect(abs(layer.letterboxColor.red - 0.5) < 0.001)
        #expect(layer.assist.desqueeze == 1.33)

        pipeline.removeDisplaySink(layer)
        #expect(pipeline.displaySinks.all().isEmpty)
    }
}
