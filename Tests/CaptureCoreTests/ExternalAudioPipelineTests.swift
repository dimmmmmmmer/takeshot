import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

/// The pipeline's half of the USB audio path: one source feeds the audio
/// entry at a time (never mixed), host-clock packets land on the stream
/// timeline, and a take whose external source goes quiet is padded with
/// counted silence — by the starvation watchdog alone, with no disconnect
/// event to help it.
struct ExternalAudioPipelineTests {
    /// Drives the pipeline at the live 40 ms pace, external audio alongside
    /// the frames when asked (the embedded-audio SignalDriver's counterpart).
    private final class ExternalFeedDriver {
        private let pipeline: CapturePipeline
        private let feed: HostClockFeed
        private let frame = TestMedia.pixelBuffer()
        private var pts = 0

        init(pipeline: CapturePipeline, feed: HostClockFeed) {
            self.pipeline = pipeline
            self.feed = feed
        }

        func push(frames: Int, withAudio: Bool) async throws {
            for _ in 0..<frames {
                pts += 40
                pipeline.handleFrame(
                    pixelBuffer: frame,
                    pts: CMTime(value: CMTimeValue(pts), timescale: 1000),
                    timecode: nil)
                if withAudio, let packet = feed.next() {
                    pipeline.handleAudio(packet, from: .external)
                }
                try await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    /// External packets as a real interface delivers them: host-clock stamps,
    /// contiguous at 48 kHz.
    private final class HostClockFeed {
        private var cache: CMAudioFormatDescription?
        private var base: CMTime?
        private var frames: Int64 = 0
        let channels: Int
        let amplitude: Int16

        init(channels: Int, amplitude: Int16) {
            self.channels = channels
            self.amplitude = amplitude
        }

        func next() -> CMSampleBuffer? {
            if base == nil { base = CMClockGetTime(CMClockGetHostTimeClock()) }
            guard let base else { return nil }
            let pts = CMTimeAdd(base, CMTime(value: frames, timescale: 48_000))
            frames += 1920
            let samples = [Int16](repeating: amplitude, count: 1920 * channels)
            return samples.withUnsafeBytes { raw -> CMSampleBuffer? in
                guard let bytes = raw.baseAddress else { return nil }
                return PCMAudio.makeSampleBuffer(
                    bytes: bytes, sampleFrames: 1920, channelCount: channels,
                    ptsSeconds: pts.seconds, formatCache: &cache)
            }
        }
    }

    @Test func theInactiveSourcesPacketsAreRefusedWhole() async throws {
        var settings = CaptureSettings()
        settings.detectionMode = .manual
        let pipeline = CapturePipeline(config: .init(settings: settings,
                                                     takeNumber: 1))
        let levels = EventCollector<[Float]>()
        // a source switch publishes an empty array to clear stale meter
        // columns — only real packet levels count here
        pipeline.onAudioLevels = { if !$0.isEmpty { levels.append($0) } }
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180,
                                            frameRate: 25, timecodeFPS: 25,
                                            name: "test"))
        pipeline.setActiveAudioSource(.external, expectedChannels: 2)

        // a video frame pins the host→stream anchor for the external clock
        let frame = TestMedia.pixelBuffer()
        pipeline.handleFrame(pixelBuffer: frame,
                             pts: CMTime(value: 40, timescale: 1000),
                             timecode: nil)

        // the embedded feed keeps arriving (16 channels) — refused whole
        var embeddedCache: CMAudioFormatDescription?
        for second in 0..<3 {
            if let embedded = TestMedia.audioBuffer(
                seconds: Double(second) * 0.04, cache: &embeddedCache) {
                pipeline.handleAudio(embedded)
            }
        }
        await TestWait.until({ !levels.isEmpty }, timeout: .seconds(1))
        #expect(levels.isEmpty,
                "embedded packets reached the meters past an active USB source")

        // the external source's packets are what the path carries
        let feed = HostClockFeed(channels: 2, amplitude: 8000)
        for _ in 0..<3 {
            if let packet = feed.next() {
                pipeline.handleAudio(packet, from: .external)
            }
        }
        await TestWait.until { levels.last?.count == 2 }
        #expect(levels.last?.count == 2,
                "the external source's channels never reached the meters")

        // …and the gate swings the other way after a switch back
        pipeline.setActiveAudioSource(.embedded)
        let published = levels.all.count
        for _ in 0..<3 {
            if let packet = feed.next() {
                pipeline.handleAudio(packet, from: .external)
            }
        }
        await TestWait.until({ levels.all.count > published },
                             timeout: .seconds(1))
        #expect(levels.all.count == published,
                "external packets reached the meters after the switch back")
    }

    /// No disconnect event at all — the packets just stop (a wedged device).
    /// The starvation watchdog opens the padding path: the take survives, the
    /// audio track is continuous, the alarm and the tally are raised.
    @Test func aStarvedExternalSourceIsPaddedWithCountedSilence() async throws {
        let root = TestMedia.scratchDirectory("ExternalAudioStarved")
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = CaptureSettings()
        settings.codec = .proResProxy
        settings.destinationPath = root.path
        settings.detectionMode = .manual
        settings.preRollFrames = 0
        let pipeline = CapturePipeline(config: .init(settings: settings,
                                                     takeNumber: 1))
        let finished = TakeCollector()
        let errors = EventCollector<String>()
        let recStates = EventCollector<Bool>()
        pipeline.onTakeFinished = { finished.append($0) }
        pipeline.onError = { errors.append($0) }
        pipeline.onRecStateChanged = { recStates.append($0) }
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180,
                                            frameRate: 25, timecodeFPS: 25,
                                            name: "test"))
        pipeline.setActiveAudioSource(.external, expectedChannels: 2)

        let driver = ExternalFeedDriver(
            pipeline: pipeline,
            feed: HostClockFeed(channels: 2, amplitude: 8000))
        try await driver.push(frames: 5, withAudio: true) // signal settles
        pipeline.toggleManualRecord()
        try await driver.push(frames: 15, withAudio: true)  // 0.6 s of real audio
        try await driver.push(frames: 40, withAudio: false) // the device goes quiet
        pipeline.toggleManualRecord()

        await TestWait.untilWritten { recStates.last == false }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { !finished.isEmpty }
        let take = try #require(finished.first)
        await TestWait.fileExists(at: take.url)

        // the alarm names the loss; the tally is stated like dropped audio
        await TestWait.until {
            errors.all.contains { $0.contains("USB AUDIO LOST") }
        }
        #expect(errors.all.contains { $0.contains("USB AUDIO LOST") },
                "no sticky alarm for the silent stretch")
        await TestWait.until {
            errors.all.contains { $0.contains("gap-filled") }
        }
        #expect(errors.all.contains { $0.contains("gap-filled") },
                "the padded packets were never counted out loud")
        // the log row is marked
        #expect(take.comment.contains("silence"))

        // and the file's audio runs to the end of the picture
        let audio = try await TestAudio.span(of: take.url)
        let asset = AVURLAsset(url: take.url)
        let videoSeconds = try await asset.load(.duration).seconds
        #expect(audio.seconds > videoSeconds - 0.35,
                "unpadded: \(audio.seconds) s of audio, \(videoSeconds) s of picture")
    }
}
