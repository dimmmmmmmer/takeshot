import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// **A frame the wire converter cannot produce used to vanish without a trace.**
///
/// `levelledFrame` returns nil when a converter refuses — its buffer pools are
/// exhausted, or the board reports a stride it does not honour — and the frame
/// path's `guard ... else { return }` swallowed it. That drop happens BEFORE
/// the take path, so none of the recording counters move; arrival is stamped at
/// ingress ("before the window test on purpose"), so the frame watchdog goes on
/// believing frames are coming. REC stays red, the take stays open, and nothing
/// at all reaches the file.
@Suite struct PipelineConversionLossTests {
    /// A v210 frame whose row is too short for its width is exactly what a
    /// board reporting a stride it does not honour looks like. The converter
    /// refuses it rather than reading past the end — and that refusal is now
    /// counted.
    @Test func aFrameTheConverterRefusesIsCounted() throws {
        let pipeline = CapturePipeline(
            config: .init(settings: CaptureSettings(), takeNumber: 1))
        #expect(pipeline.health.conversionFailures == 0)

        // 12 pixels of v210 are two 16-byte blocks; this buffer declares the
        // width and gives one block's worth of row. That is what a board
        // reporting a stride it does not honour looks like, and reading the
        // second block would run off the end of the allocation.
        let short = try Self.shortRowV210(width: 12, height: 2, rowBytes: 16)
        let format = CaptureFormat(width: 12, height: 2, frameRate: 25,
                                   timecodeFPS: 25, name: "short-row")
        let frame = pipeline.levelledFrame(from: short, format: format)

        #expect(frame == nil, "the converter took a frame it cannot read safely")
        #expect(pipeline.health.conversionFailures == 1, """
            a frame was lost between the board and the file and nothing \
            counted it
            """)
    }

    /// A v210 buffer whose declared row is shorter than its width needs. Built
    /// over an allocation of its own, because `CVPixelBufferCreate` picks a
    /// stride that is always long enough — which is the point: this is the
    /// board lying, not Core Video.
    private static func shortRowV210(width: Int, height: Int,
                                     rowBytes: Int) throws -> CVPixelBuffer {
        let bytes = UnsafeMutableRawPointer.allocate(
            byteCount: rowBytes * height, alignment: 64)
        bytes.initializeMemory(as: UInt8.self, repeating: 0,
                               count: rowBytes * height)
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            nil, width, height, TenBitYUVConverter.v210, bytes, rowBytes,
            { _, pointer in pointer?.deallocate() }, bytes, nil, &buffer)
        #expect(status == kCVReturnSuccess)
        return try #require(buffer)
    }

    /// One lost frame is a pool that has not recycled yet; a stream of them is
    /// the take. The alarm follows the same threshold as the dropped-frame one
    /// beside it, and it lands in the STICKY register — footage is missing.
    @Test func sustainedLossAlarmsAndIsAnIntegrityFault() async throws {
        let pipeline = CapturePipeline(
            config: .init(settings: CaptureSettings(), takeNumber: 1))
        let raised = AlarmBox()
        pipeline.onError = { raised.record($0) }

        for _ in 0..<CapturePipeline.droppedFrameAlarmThreshold {
            pipeline.noteConversionFailure()
        }
        try await Task.sleep(for: .milliseconds(200))

        let alarms = raised.all
        #expect(alarms.count == 1, "expected one alarm, got \(alarms)")
        let alarm = try #require(alarms.first)
        #expect(alarm == .frameLostConversionFailed(
            count: CapturePipeline.droppedFrameAlarmThreshold))
        #expect(alarm.severity == .integrity, """
            frames that never reached the file were reported as a \
            five-second notice
            """)
        #expect(pipeline.health.conversionFailures
            == CapturePipeline.droppedFrameAlarmThreshold)
    }

    /// And it does not alarm on the first one — a pool that has not recycled
    /// yet trains the operator to ignore the banner.
    @Test func oneLostFrameDoesNotRaiseTheBanner() async throws {
        let pipeline = CapturePipeline(
            config: .init(settings: CaptureSettings(), takeNumber: 1))
        let raised = AlarmBox()
        pipeline.onError = { raised.record($0) }

        pipeline.noteConversionFailure()
        try await Task.sleep(for: .milliseconds(200))

        #expect(raised.all.isEmpty, "one lost frame lit the alarm banner")
        #expect(pipeline.health.conversionFailures == 1,
                "…but it still has to be counted")
    }
}

/// Alarms as they arrive, from whichever thread reports them.
final class AlarmBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PipelineAlarm] = []
    func record(_ alarm: PipelineAlarm) { lock.withLock { stored.append(alarm) } }
    var all: [PipelineAlarm] { lock.withLock { stored } }
}
