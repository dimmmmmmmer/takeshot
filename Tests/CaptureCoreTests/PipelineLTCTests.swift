import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

/// Timecode arriving as SOUND: a camera that embeds SMPTE 12M LTC on an audio
/// channel instead of RP188 in the video stream. With `timecodeSource: ltc`
/// the pipeline decodes the selected channel, and that decode — not the wire —
/// feeds the detector, the UI and the take's timecode track. Driven end to
/// end here, because the unit halves (LTCDecoder, RecDetector) both being
/// right says nothing about the channel selection and the hand-off between
/// audio and frame paths.
struct PipelineLTCTests {
    /// Drives one pipeline at the live pace: per 40 ms step, an LTC frame as
    /// 2-channel audio (timecode on channel 1, silence on channel 0 — the
    /// shape of a camera feed with TC on track 2), then the picture frame
    /// with NO timecode on the wire at all. Sound is the only source there is.
    private final class LTCSignalDriver {
        let pipeline: CapturePipeline
        private let pixelBuffer = TestMedia.pixelBuffer()
        private var polarity = false
        private var cache: CMAudioFormatDescription?
        private var frame = 0

        init(pipeline: CapturePipeline) {
            self.pipeline = pipeline
        }

        func push(_ timecode: Timecode) async throws {
            frame += 1
            if let audio = ltcAudio(timecode) {
                pipeline.handleAudio(audio)
            }
            pipeline.handleFrame(
                pixelBuffer: pixelBuffer,
                pts: CMTime(value: CMTimeValue(frame * 40), timescale: 1000),
                timecode: nil, vancTrigger: nil)
            try await Task.sleep(for: .milliseconds(40))
        }

        private func ltcAudio(_ timecode: Timecode) -> CMSampleBuffer? {
            let mono = LTCTestSignal.encode(timecode, fps: 25,
                                            polarity: &polarity)
            let channels = 2
            var interleaved = [Int16](repeating: 0,
                                      count: mono.count * channels)
            for (index, sample) in mono.enumerated() {
                interleaved[index * channels + 1] = sample
            }
            return interleaved.withUnsafeBytes { raw in
                PCMAudio.makeSampleBuffer(bytes: raw.baseAddress!,
                                          sampleFrames: mono.count,
                                          channelCount: channels,
                                          ptsSeconds: Double(frame) * 0.04,
                                          formatCache: &cache)
            }
        }
    }

    @Test func ltcOnAnAudioChannelDrivesTheWholeTake() async throws {
        let root = TestMedia.scratchDirectory("PipelineLTC")
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = CaptureSettings()
        settings.codec = .proResProxy
        settings.destinationPath = root.path
        settings.startDebounceFrames = 3
        settings.stopDebounceFrames = 5
        settings.detectionMode = .timecodeRun
        settings.preRollSeconds = 0
        settings.timecodeSource = "ltc"
        settings.ltcChannel = 1

        let pipeline = CapturePipeline(config: .init(
            settings: settings, scene: "9", takeNumber: 1))
        let finishedTakes = TakeCollector()
        let recStates = EventCollector<Bool>()
        pipeline.onTakeFinished = { finishedTakes.append($0) }
        pipeline.onRecStateChanged = { recStates.append($0) }
        pipeline.handleFormat(CaptureFormat(
            width: 320, height: 180, frameRate: 25, timecodeFPS: 25,
            name: "test"))

        let standby = Timecode(hours: 15, minutes: 30, seconds: 0, frames: 0,
                               fps: 25)
        let driver = LTCSignalDriver(pipeline: pipeline)

        // camera in standby repeats one LTC frame; then Rec Run for 2 s; then
        // standby again
        for _ in 0..<10 { try await driver.push(standby) }
        var rolling = standby
        for _ in 0..<50 {
            rolling = rolling.advanced(by: 1)
            try await driver.push(rolling)
        }
        for _ in 0..<10 { try await driver.push(rolling) }

        // stop seen → await the finalize itself → poll for the publication
        // (see CapturePipelineTests for why the waits are ordered this way)
        await TestWait.untilWritten { recStates.last == false }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { !finishedTakes.isEmpty }

        let take = try #require(finishedTakes.first)
        #expect(recStates.contains(true), "the take never started from LTC")

        // the take's start TC is the decoded LTC, not the absent wire TC —
        // within a couple of frames for the decoder's one-frame latency and
        // the detector's backfill
        let start = try #require(take.startTimecode)
        #expect(abs(start.frameNumber - standby.frameNumber) <= 2,
                "take started at \(start), the LTC said \(standby)")

        // and the file's timecode track carries the same LTC start
        await TestWait.fileExists(at: take.url)
        let written = await TimecodeReader.startTimecode(
            of: AVURLAsset(url: take.url))
        let fileStart = try #require(written)
        #expect(abs(fileStart.frameNumber - standby.frameNumber) <= 2,
                "the file's TC track says \(fileStart)")
    }
}
