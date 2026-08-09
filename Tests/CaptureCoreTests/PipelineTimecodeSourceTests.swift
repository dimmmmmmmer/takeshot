import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import CaptureCore

/// Where a frame's timecode comes from, and what the take's TC track does when
/// the camera's own clock misbehaves.
///
/// Sync is the take's only tie back to the camera original, and both of these
/// are silent when they go wrong: a take named and tagged at 0 fps, or a TC
/// track that drifts from the camera by however long Rec Run stood still before
/// it started moving. Neither shows up until the edit.
@Suite struct PipelineTimecodeSourceTests {
    private static let format = CaptureFormat(
        width: 320, height: 180, frameRate: 25, timecodeFPS: 25, name: "test 25")

    private func pipeline(root: URL,
                          detection: RecDetectionMode = .manual) -> CapturePipeline {
        var settings = CaptureSettings()
        settings.capture.codec = .proResProxy
        settings.capture.destinationPath = root.path
        settings.naming.namingTemplate = "{tc}"
        settings.naming.projectName = "TC"
        settings.capture.detectionMode = detection
        settings.capture.preRollSeconds = 0
        return CapturePipeline(config: .init(settings: settings,
                                             slate: .empty, takeNumber: 1))
    }

    /// The bridge does not always know the timecode's rate — an RP188 read that
    /// comes back with fps 0. Left alone it reaches the naming engine and the TC
    /// track as a rate no clip can have.
    @Test func aTimecodeWithNoRateIsGivenTheSignalsOwn() async throws {
        let root = TestMedia.scratchDirectory("TCRate")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(root: root)
        let reported = EventCollector<Timecode?>()
        pipeline.onTimecode = { reported.append($0) }
        pipeline.handleFormat(Self.format)

        var rateless = Timecode(hours: 9, minutes: 30, seconds: 0, frames: 12,
                                fps: 25)
        rateless.fps = 0
        pipeline.handleFrame(pixelBuffer: TestMedia.pixelBuffer(),
                             pts: CMTime(value: 40, timescale: 1000),
                             timecode: rateless)

        #expect(await TestWait.becomesTrue(timeout: .seconds(5)) {
            reported.last??.fps == Self.format.timecodeFPS
        }, "a rateless timecode reached the app as \(reported.last??.fps ?? -1) fps")
        let seen = try #require(reported.last ?? nil)
        #expect(seen.hours == 9 && seen.minutes == 30 && seen.frames == 12,
                "filling the rate in changed the reading")
    }

    /// Rec Run started AFTER the take did: the camera's TC stands still while
    /// the file's track keeps counting, so the overlap would drift by however
    /// long it was frozen. The track is re-anchored the moment the TC moves,
    /// and the file comes out with two tc32 samples instead of one.
    @Test func aCameraThatStartsRecRunLateReanchorsTheTakesTrack() async throws {
        let root = TestMedia.scratchDirectory("TCResync")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(root: root)
        let takes = TakeCollector()
        let recStates = EventCollector<Bool>()
        pipeline.onTakeFinished = { takes.append($0) }
        pipeline.onRecStateChanged = { recStates.append($0) }
        pipeline.handleFormat(Self.format)

        let buffer = TestMedia.pixelBuffer()
        let frozen = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0, fps: 25)
        let driver = SignalDriver(pipeline: pipeline)
        // the take opens on the camera's standing timecode: a take opened
        // before frame one has no start TC and no timecode track to re-anchor
        try await driver.pushStalled(frozen, count: 2, pixelBuffer: buffer)
        pipeline.toggleManualRecord()
        #expect(await TestWait.becomesTrue { pipeline.health.isRecording })

        // the camera is in standby: its TC does not move for six more frames
        try await driver.pushStalled(frozen, count: 6, pixelBuffer: buffer)
        // …and then Rec Run starts
        _ = try await driver.pushRunning(from: frozen, count: 12,
                                         pixelBuffer: buffer)
        pipeline.toggleManualRecord()

        await TestWait.untilWritten { recStates.last == false }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { !takes.isEmpty }
        let take = try #require(takes.first)
        await TestWait.fileExists(at: take.url)

        let samples = try await Self.timecodeSamples(of: take.url)
        // one anchor means the re-anchor never fired; more than two means it
        // fired on jitter as well
        #expect(samples.count == 2, "the TC track has \(samples.count) sample(s)")
        #expect(samples.first == UInt32(frozen.frameNumber))
        #expect(samples.last == UInt32(frozen.advanced(by: 1).frameNumber),
                "the second anchor is not the camera's first running frame")
    }

    /// A camera whose TC never stands still writes ONE anchor. The re-anchor
    /// costs a second sample in every file it fires on, so a jitter of one or
    /// two frames must not trigger it.
    @Test func aCameraAlreadyRunningKeepsASingleAnchor() async throws {
        let root = TestMedia.scratchDirectory("TCSingle")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(root: root)
        let takes = TakeCollector()
        let recStates = EventCollector<Bool>()
        pipeline.onTakeFinished = { takes.append($0) }
        pipeline.onRecStateChanged = { recStates.append($0) }
        pipeline.handleFormat(Self.format)

        let buffer = TestMedia.pixelBuffer()
        let start = Timecode(hours: 2, minutes: 0, seconds: 0, frames: 0, fps: 25)
        let driver = SignalDriver(pipeline: pipeline)
        try await driver.pushStalled(start, count: 2, pixelBuffer: buffer)
        pipeline.toggleManualRecord()
        #expect(await TestWait.becomesTrue { pipeline.health.isRecording })
        // two repeated readings — a stuttering RP188 read, not a standing clock
        try await driver.pushStalled(start, count: 2, pixelBuffer: buffer)
        _ = try await driver.pushRunning(from: start, count: 14,
                                         pixelBuffer: buffer)
        pipeline.toggleManualRecord()

        await TestWait.untilWritten { recStates.last == false }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { !takes.isEmpty }
        let take = try #require(takes.first)
        await TestWait.fileExists(at: take.url)

        #expect(try await Self.timecodeSamples(of: take.url).count == 1,
                "a two-frame stall re-anchored the track")
    }

    /// The frame numbers in a .mov's timecode track, in order. Read from the
    /// file rather than off the writer: what the edit conforms against is the
    /// track, not the pipeline's intention to write one.
    private static func timecodeSamples(of url: URL) async throws -> [UInt32] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.tracks(ofType: .timecode).first
        else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        var frames: [UInt32] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var raw: UInt32 = 0
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4,
                                       destination: &raw)
            frames.append(UInt32(bigEndian: raw))
        }
        return frames
    }
}

/// What the operator is shown when a take cannot be written at all.
///
/// Each of these ends up in the alarm banner verbatim, and three of the four
/// name a cause the operator can act on — a full card, a busy encoder, a
/// destination that went away. A case that came back with an empty or
/// misleading line would leave them with a failed take and nothing to go on.
@Suite struct TakeWriterErrorTextTests {
    @Test func everyWriterFailureSaysWhatWentWrong() {
        struct Underlying: LocalizedError {
            var errorDescription: String? { "the volume was not there" }
        }

        let cannotCreate = TakeWriter.WriterError.cannotCreateWriter(Underlying())
        #expect(cannotCreate.errorDescription
            == "Cannot create writer: the volume was not there")

        // the writer's own error when it has one…
        let withReason = TakeWriter.WriterError.notWritable(.failed, Underlying())
        #expect(withReason.errorDescription
            == "Writer failed: the volume was not there")
        // …and its status when it does not, rather than an empty sentence
        let withoutReason = TakeWriter.WriterError.notWritable(.failed, nil)
        #expect(withoutReason.errorDescription
            == "Writer failed: status \(AVAssetWriter.Status.failed.rawValue)")

        #expect(TakeWriter.WriterError.timecodeTrackFailed.errorDescription
            == "Failed to create timecode track")
        #expect(TakeWriter.WriterError.emptyTake.errorDescription
            == "Take contained no video frames")
    }

    /// They reach the operator through `localizedDescription`, which is what
    /// every catch site actually prints — a `LocalizedError` whose description
    /// is not wired up comes out as "The operation couldn't be completed".
    @Test func theTextSurvivesTheRouteTheAlarmTakesToTheBanner() {
        let error: Error = TakeWriter.WriterError.emptyTake
        #expect(error.localizedDescription == "Take contained no video frames")
    }
}
