import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The USB audio path where it meets the pre-roll and the board's stream clock.
///
/// `ExternalAudioPipelineTests` covers the mechanism with `preRollFrames = 0`
/// and a well-behaved clock. These are the two inputs it does not have: a take
/// that opens with picture AND sound already buffered, and a frame whose stream
/// time jumps. Both reach the same silence-padding loop, and it measures from
/// the take's first video frame rather than from the sound that is already in
/// the file.
@Suite struct ExternalAudioPreRollTests {
    /// External packets as an interface delivers them: host-clock stamps,
    /// contiguous at 48 kHz.
    final class HostFeed {
        private var cache: CMAudioFormatDescription?
        private var base: CMTime?
        private var frames: Int64 = 0
        let channels: Int

        init(channels: Int) { self.channels = channels }

        func next() -> CMSampleBuffer? {
            if base == nil { base = CMClockGetTime(CMClockGetHostTimeClock()) }
            guard let base else { return nil }
            let pts = CMTimeAdd(base, CMTime(value: frames, timescale: 48_000))
            frames += 1920
            let samples = [Int16](repeating: 4000, count: 1920 * channels)
            return samples.withUnsafeBytes { raw -> CMSampleBuffer? in
                guard let bytes = raw.baseAddress else { return nil }
                return PCMAudio.makeSampleBuffer(
                    bytes: bytes, sampleFrames: 1920, channelCount: channels,
                    ptsSeconds: pts.seconds, formatCache: &cache)
            }
        }
    }

    /// Pushes frames at the live pace, with the feed's packets alongside.
    final class Feeder {
        private let pipeline: CapturePipeline
        private let feed: HostFeed
        private let frame = TestMedia.pixelBuffer()
        private var millis = 0

        init(pipeline: CapturePipeline, feed: HostFeed) {
            self.pipeline = pipeline
            self.feed = feed
        }

        func push(frames: Int, withAudio: Bool) async throws {
            for _ in 0..<frames {
                millis += 40
                pipeline.handleFrame(
                    pixelBuffer: frame,
                    pts: CMTime(value: CMTimeValue(millis), timescale: 1000),
                    timecode: nil)
                if withAudio, let packet = feed.next() {
                    pipeline.handleAudio(packet, from: .external)
                }
                try await Task.sleep(for: .milliseconds(40))
            }
        }

        /// One frame, at an arbitrary stream time, with no audio behind it.
        func pushFrame(atMillis stamp: Int) {
            millis = stamp
            pipeline.handleFrame(
                pixelBuffer: frame,
                pts: CMTime(value: CMTimeValue(stamp), timescale: 1000),
                timecode: nil)
        }
    }

    private static func pipeline(root: URL, preRoll: Int) -> CapturePipeline {
        CapturePipeline(config: .init(
            settings: TakeIntegrityBoundsTests.settings(root: root,
                                                        preRoll: preRoll),
            takeNumber: 1))
    }

    /// A take opens, its pre-roll audio is written under its pre-roll picture,
    /// and the starvation watchdog then measures the gap from the take's FIRST
    /// video frame instead of from the sound just written. Any pre-roll longer
    /// than the half-second threshold therefore reads as a device that has gone
    /// quiet: the take is padded with silence over sound it already has, and
    /// every real packet arriving inside the padded span is refused as an
    /// overlap.
    ///
    /// The feed never stops here, which is what makes the padding a fabrication.
    @Test func aTakeWithPreRollIsNotPaddedOverItsOwnUSBAudio() async throws {
        let root = TestMedia.scratchDirectory("PreRollExternalAudio")
        defer { try? FileManager.default.removeItem(at: root) }

        // 20 frames of pre-roll: 0.8 s, past the 0.5 s starvation threshold
        let pipeline = Self.pipeline(root: root, preRoll: 20)
        let errors = EventCollector<PipelineAlarm>()
        let recStates = EventCollector<Bool>()
        let finished = TakeCollector()
        pipeline.onError = { errors.append($0) }
        pipeline.onRecStateChanged = { recStates.append($0) }
        pipeline.onTakeFinished = { finished.append($0) }
        pipeline.handleFormat(TakeIntegrityBoundsTests.format)
        pipeline.setActiveAudioSource(.external, expectedChannels: 2)

        let feeder = Feeder(pipeline: pipeline, feed: HostFeed(channels: 2))
        try await feeder.push(frames: 30, withAudio: true) // fill the ring
        pipeline.toggleManualRecord()
        #expect(await TestWait.becomesTrue { pipeline.health.isRecording },
                "the take never opened")
        try await feeder.push(frames: 20, withAudio: true)
        pipeline.toggleManualRecord()

        await TestWait.untilWritten { recStates.last == false }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { !finished.isEmpty }
        let take: Take = try #require(finished.first,
                                      "the take was never published")

        let padded: Int = pipeline.health.gapFilledAudioPacketsInTake
        #expect(!errors.contains(.externalAudioPadded),
                "a take whose USB source never stopped was reported as lost")
        #expect(padded == 0,
                "\(padded) packets of silence invented for a take with sound")
        #expect(take.comment.isEmpty,
                "the log row blames the sound cart: \(take.comment)")
        // …and the ring held the whole window, so the shortfall count the
        // memory ceiling now reports must stay quiet. The other direction of
        // that fix: a notice on every take is a notice nobody reads.
        let incomplete: [PipelineAlarm] = errors.all.filter {
            if case .preRollIncomplete = $0 { return true }
            return false
        }
        #expect(incomplete.isEmpty,
                "a full pre-roll ring reported \(incomplete.count) shortfalls")

        // The other direction, and the one that matters more: the take still has
        // its REAL sound. Silencing the fabricated padding by seeding the field
        // that also arms the overlap guard in `admitExternalPacket` refused every
        // live packet instead — a whole audio track for a silent head, which the
        // three assertions above are all perfectly happy with.
        await TestWait.fileExists(at: take.url)
        let audio = try await TestAudio.span(of: take.url)
        let asset = AVURLAsset(url: take.url)
        let picture: Double = (try await asset.load(.duration)).seconds
        #expect(audio.seconds > picture - 0.3,
                "\(audio.seconds) s of audio for \(picture) s of picture")
        // …and none of it merely refused, which is the third way this take can
        // come out with a silent head: the pre-roll's packets arrive in one burst
        // and used to be offered to the audio input without waiting for it.
        let dropped: Int = pipeline.health.droppedAudioPacketsInTake
        #expect(dropped == 0,
                "\(dropped) of the take's audio packets were refused")
    }

    /// The padding loop advances a cursor in 40 ms steps until it reaches the
    /// frame's PTS, and the frame's PTS is whatever the board says. A single
    /// jump forward turns one frame into as many silence packets as fit in the
    /// gap, each allocated, trimmed and appended on the capture queue — ten
    /// minutes of gap is fifteen thousand of them.
    @Test func aJumpInStreamTimeDoesNotPadATakeUnbounded() async throws {
        let root = TestMedia.scratchDirectory("ExternalAudioPTSJump")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = Self.pipeline(root: root, preRoll: 0)
        let recStates = EventCollector<Bool>()
        pipeline.onRecStateChanged = { recStates.append($0) }
        pipeline.handleFormat(TakeIntegrityBoundsTests.format)
        pipeline.setActiveAudioSource(.external, expectedChannels: 2)

        let feeder = Feeder(pipeline: pipeline, feed: HostFeed(channels: 2))
        feeder.pushFrame(atMillis: 40) // anchors the host→stream offset
        pipeline.toggleManualRecord()
        #expect(await TestWait.becomesTrue { pipeline.health.isRecording },
                "the take never opened")
        feeder.pushFrame(atMillis: 80)
        feeder.pushFrame(atMillis: 600_120) // ten minutes on, says the board
        pipeline.queue.sync {}

        // Exactly one bounded burst: the cap stops the loop and the cursor is
        // moved to the frame, so the next frames do not carry the rest of it.
        // Pinned as equality rather than a ceiling — `<=` would also pass if the
        // padding stopped happening at all, which is the other way this fix can
        // regress.
        let padded: Int = pipeline.health.gapFilledAudioPacketsInTake
        #expect(padded == CapturePipeline.maximumPadPacketsPerFrame,
                "one frame padded \(padded) packets of silence")

        pipeline.toggleManualRecord()
        await TestWait.untilWritten { recStates.last == false }
        await pipeline.finishPendingWrites()
    }
}
