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
        // The drain runs inside `beginTake`, on this queue, and `isRecording`
        // is mirrored BEFORE it — so a barrier here is the drain having
        // finished, rather than a guess about how long it takes. Nothing else
        // has been offered to the writer yet: the feeder is not pushing.
        let refusedInDrain: Int = pipeline.queue.sync {
            pipeline.writer?.droppedAudioPackets ?? -1
        }
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
        // …and none of the DRAIN's packets merely refused, which is the third
        // way this take can come out with a silent head: the pre-roll's packets
        // arrive in one burst and used to be offered to the audio input without
        // waiting for it (measured then: 15 of ~20 lost).
        //
        // Read off the writer at the end of the drain rather than off the take
        // at the end of the take, and that is the whole difference between a
        // test about this code and a test about this machine.
        // `droppedAudioPacketsInTake` is a WHOLE-TAKE counter, and the 0.8 s of
        // live capture after the drain feeds it too — where the app deliberately
        // does NOT wait for the input, because a live packet held back is a
        // packet late rather than a packet saved. A refusal there is designed
        // back-pressure, counted and reported as a notice, exactly like the
        // video drop that already makes "virtually every take drop one frame"
        // at take start. Asserting zero of THAT asserts that the machine kept
        // up, and it went red once on a box running another full battery.
        //
        // What is left is bounded by the app's OWN budget instead, which is the
        // point: the drain waits up to 1.5 s for the input, and measured on this
        // tree it spends 22 ms of that (10 ms of picture, 12 ms of sound) on a
        // quiet machine and 48 ms at load average 14 — a thirtyfold margin that
        // barely moves with CPU load, because the wait is on the writer's input
        // and not on the processor. A machine slow enough to fail this really
        // did lose the head of the take, which is the thing being tested.
        //
        // Nor is it trivially zero: with the wait taken out of `drainPreRollAudio`
        // it reads 17, and the file's sound drops from 1.64 s to 0.92 s.
        #expect(refusedInDrain == 0,
                "the drain refused \(refusedInDrain) of the pre-roll's packets")
    }

    /// The embedded source that DECLARED channels and delivers none, driven
    /// through the pipeline rather than through the writer alone.
    ///
    /// The writer keeping the file readable is only half of it: silence in a
    /// take's audio track is footage the operator does not have, and a take that
    /// comes back silent with nothing said about it is found in the edit — which
    /// is the failure `takeLostNoAudioTrack` already exists to prevent for the
    /// case where there is no track at all. So the alarm is checked here, and
    /// checked to fire ONCE: a starved track pads on every frame for the rest of
    /// the take, and a sticky banner re-raised at frame rate is a banner nobody
    /// reads. The log row is checked too, because that is the copy post gets.
    @Test func anEmbeddedTakeThatIsDeclaredAndNeverFedSaysSo() async throws {
        let root = TestMedia.scratchDirectory("EmbeddedAudioStarved")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = Self.pipeline(root: root, preRoll: 0)
        let errors = EventCollector<PipelineAlarm>()
        let recStates = EventCollector<Bool>()
        let finished = TakeCollector()
        pipeline.onError = { errors.append($0) }
        pipeline.onRecStateChanged = { recStates.append($0) }
        pipeline.onTakeFinished = { finished.append($0) }
        pipeline.handleFormat(TakeIntegrityBoundsTests.format)
        // what the board says it carries, before a packet exists — the head
        // start `setExpectedAudioChannels` is for, and the declaration this
        // whole case is about
        pipeline.setExpectedAudioChannels(2)

        let feeder = Feeder(pipeline: pipeline, feed: HostFeed(channels: 2))
        pipeline.toggleManualRecord()
        #expect(await TestWait.becomesTrue { pipeline.health.isRecording },
                "the take never opened")
        // 60 frames is 2.4 s: past the one-second lead twice over, so a
        // backstop that fired once would be indistinguishable from one that
        // never stopped.
        try await feeder.push(frames: 60, withAudio: false)
        pipeline.toggleManualRecord()

        await TestWait.untilWritten { recStates.last == false }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { !finished.isEmpty }
        let take: Take = try #require(finished.first,
                                      "the take was never published")

        let starved: [PipelineAlarm] = errors.all.filter { $0 == .takeAudioStarved }
        #expect(starved.count == 1,
                "the starved track raised \(starved.count) alarms")
        let padded: Int = pipeline.health.paddedAudioPacketsInTake
        #expect(padded > 0, "a declared-but-unfed track was left empty")
        #expect(take.comment.contains("audio track starved"),
                "the log row does not mention it: \(take.comment)")
        // …and it is NOT reported as the USB cart having dropped out, which is
        // the other padding mechanism and a different phone call.
        #expect(!errors.contains(.externalAudioPadded),
                "an embedded take blamed the USB source")
        #expect(pipeline.health.gapFilledAudioPacketsInTake == 0,
                "the writer's backstop was counted as the pipeline's padding")
    }

    /// …and the take that IS fed says nothing at all. The other direction of the
    /// fix above, and the one that decides whether the alarm is worth anything:
    /// a banner on every take is a banner nobody reads, and silence written over
    /// a working microphone is footage lost rather than saved.
    @Test func anEmbeddedTakeWithSoundUnderItIsNeitherPaddedNorBlamed()
        async throws {
        let root = TestMedia.scratchDirectory("EmbeddedAudioFed")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = Self.pipeline(root: root, preRoll: 0)
        let errors = EventCollector<PipelineAlarm>()
        let recStates = EventCollector<Bool>()
        let finished = TakeCollector()
        pipeline.onError = { errors.append($0) }
        pipeline.onRecStateChanged = { recStates.append($0) }
        pipeline.onTakeFinished = { finished.append($0) }
        pipeline.handleFormat(TakeIntegrityBoundsTests.format)
        pipeline.setExpectedAudioChannels(16) // SignalDriver feeds 16

        let driver = SignalDriver(pipeline: pipeline, withAudio: true)
        pipeline.toggleManualRecord()
        #expect(await TestWait.becomesTrue { pipeline.health.isRecording },
                "the take never opened")
        try await driver.pushStalled(
            Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25),
            count: 60, pixelBuffer: TestMedia.pixelBuffer())
        pipeline.toggleManualRecord()

        await TestWait.untilWritten { recStates.last == false }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { !finished.isEmpty }
        let take: Take = try #require(finished.first,
                                      "the take was never published")

        #expect(!errors.contains(.takeAudioStarved),
                "a take with sound under it was reported as starved")
        let padded: Int = pipeline.health.paddedAudioPacketsInTake
        #expect(padded == 0,
                "\(padded) packets of silence invented for a take with sound")
        #expect(take.comment.isEmpty,
                "the log row blames the sound: \(take.comment)")
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
