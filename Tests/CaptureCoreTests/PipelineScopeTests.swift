import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The live scope path end to end: a synthetic gradient goes through the frame
/// path and the data that comes back out says which part of the frame was read.
///
/// `ScopeRegionTests` proves the analyzer honours a region; this proves the
/// pipeline hands it the one the viewer is showing, and that a closed scope
/// surface costs nothing.
struct PipelineScopeTests {
    /// A left-to-right ramp: the mean code value of a region says where it sat.
    private func gradient(width: Int = 320, height: Int = 180) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base + y * rowBytes
            for x in 0..<width {
                let value = UInt8(x * 255 / (width - 1))
                row[x * 4] = value
                row[x * 4 + 1] = value
                row[x * 4 + 2] = value
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    /// A pipeline that records nothing: this suite is about the scope path, and
    /// a take would put an encoder in the way of it.
    private func idlePipeline(root: URL) -> CapturePipeline {
        var settings = CaptureSettings()
        settings.capture.destinationPath = root.path
        settings.capture.detectionMode = .manual
        settings.capture.videoLevels = "full" // pass the ramp's code values through
        settings.capture.preRollFrames = 0
        return CapturePipeline(config: .init(settings: settings, takeNumber: 1))
    }

    /// Weighted mean of the luma histogram — the analyzed region's brightness.
    private func meanLuma(_ data: ScopeData) -> Double {
        let total = data.histY.reduce(0, +)
        guard total > 0 else { return 0 }
        let sum = data.histY.enumerated().reduce(0) { $0 + $1.offset * $1.element }
        return Double(sum) / Double(total)
    }

    /// Feed enough frames for the frame path to offer one to the analyzer, then
    /// wait for the pass itself.
    ///
    /// The wait is generous on purpose: the pass runs on a utility-QoS queue —
    /// deliberately, so it never competes with the capture path — and utility
    /// work is scheduled on the efficiency cores and yields to everything else.
    /// An unoptimized pass there, on a machine that is also building something,
    /// measured tens of seconds against under a second when the machine is idle.
    /// The wait polls for the outcome and costs nothing when it lands early.
    private func pushUntilAnalyzed(_ driver: SignalDriver,
                                   buffer: CVPixelBuffer,
                                   collected: EventCollector<ScopeData>,
                                   frames: Int = 12) async throws {
        var timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25)
        for _ in 0..<frames where collected.isEmpty {
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: buffer)
        }
        await TestWait.until({ !collected.isEmpty }, timeout: .seconds(120))
    }

    @Test func liveScopesReadTheWholeFrameByDefault() async throws {
        let root = TestMedia.scratchDirectory("PipelineScopeFull")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = idlePipeline(root: root)
        let collected = EventCollector<ScopeData>()
        pipeline.onScopeData = { collected.append($0) }
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180, frameRate: 25,
                                           timecodeFPS: 25, name: "test"))
        pipeline.setScopesEnabled(true)

        try await pushUntilAnalyzed(SignalDriver(pipeline: pipeline),
                                    buffer: try gradient(), collected: collected)
        let data = try #require(collected.first, "no scope data arrived")
        // a full ramp averages the middle of the range and occupies both ends
        #expect(abs(meanLuma(data) - 127) < 12, "mean \(meanLuma(data))")
        #expect(data.histY[0..<8].reduce(0, +) > 0, "the shadows went missing")
        #expect(data.histY[248...].reduce(0, +) > 0, "the highlights went missing")
    }

    /// Punched in on the right half of the ramp, the scopes must show the top
    /// half of the code range and nothing from the left.
    @Test func liveScopesFollowThePunchInRegion() async throws {
        let root = TestMedia.scratchDirectory("PipelineScopeRegion")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = idlePipeline(root: root)
        let collected = EventCollector<ScopeData>()
        pipeline.onScopeData = { collected.append($0) }
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180, frameRate: 25,
                                           timecodeFPS: 25, name: "test"))
        pipeline.setScopeRegion(ScopeRegion(x: 0.5, y: 0, width: 0.5, height: 1))
        pipeline.setScopesEnabled(true)

        try await pushUntilAnalyzed(SignalDriver(pipeline: pipeline),
                                    buffer: try gradient(), collected: collected)
        let data = try #require(collected.first, "no scope data arrived")
        // the right half of a 0-255 ramp averages ~191 and starts around 128
        #expect(meanLuma(data) > 160, "mean \(meanLuma(data))")
        #expect(data.histY[0..<100].reduce(0, +) == 0,
                "the left half of the frame is still being sampled")
    }

    /// **Opening the scopes costs the capture queue nothing.**
    ///
    /// It used to analyze the current frame inline, on the capture queue, so
    /// the window would open with data rather than "waiting for signal" — a
    /// content-dependent 22 ms pass on the one queue that owns per-frame work,
    /// in the one call guaranteed to happen while a signal is running.
    /// `setScopeRegion` next to it already states the rule and follows it.
    ///
    /// So: no data until a FRAME arrives, and then data on the first one —
    /// which is 40 ms at 25 fps and reads the wire frame with the signal's own
    /// levels, like every trace after it.
    @Test func openingTheScopesWaitsForAFrameRatherThanAnalyzingOnTheCaptureQueue()
        async throws {
        let root = TestMedia.scratchDirectory("PipelineScopeOpen")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = idlePipeline(root: root)
        let collected = EventCollector<ScopeData>()
        pipeline.onScopeData = { collected.append($0) }
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180, frameRate: 25,
                                            timecodeFPS: 25, name: "test"))
        let driver = SignalDriver(pipeline: pipeline)
        var timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25)
        let buffer = try gradient()
        // a frame the pipeline is holding, so "the current frame" exists to be
        // analyzed — which is what the old code reached for
        timecode = timecode.advanced(by: 1)
        try await driver.push(timecode, pixelBuffer: buffer)

        pipeline.setScopesEnabled(true)
        // Polled rather than slept: the callback lands on the MAIN queue, and
        // in this harness main is only serviced at an await — a flat sleep
        // proved this either way, which is how the first version of this test
        // passed against the behaviour it was written to reject.
        await TestWait.until({ !collected.isEmpty }, timeout: .seconds(2))
        #expect(collected.isEmpty, """
            the scopes analyzed a frame on the capture queue when the window \
            opened
            """)

        // and the very next frame IS analyzed — no waiting out the stride
        timecode = timecode.advanced(by: 1)
        try await driver.push(timecode, pixelBuffer: buffer)
        await TestWait.until({ !collected.isEmpty }, timeout: .seconds(20))
        #expect(!collected.isEmpty,
                "the first frame after opening was not analyzed")
    }

    /// No scope surface open, no analysis: the pipeline must not spend a frame's
    /// worth of CPU on data nobody is looking at.
    @Test func closedScopesAnalyzeNothing() async throws {
        let root = TestMedia.scratchDirectory("PipelineScopeOff")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = idlePipeline(root: root)
        let collected = EventCollector<ScopeData>()
        pipeline.onScopeData = { collected.append($0) }
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180, frameRate: 25,
                                           timecodeFPS: 25, name: "test"))

        let driver = SignalDriver(pipeline: pipeline)
        var timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25)
        let buffer = try gradient()
        for _ in 0..<20 {
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: buffer)
        }
        // the callback fires on the main queue — give it the chance to
        await TestWait.until({ !collected.isEmpty }, timeout: .milliseconds(500))
        #expect(collected.isEmpty, "\(collected.all.count) passes with no scopes open")
    }
}
