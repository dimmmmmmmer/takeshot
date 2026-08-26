import AVFoundation
@preconcurrency import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// What the standby measurement does to a real take: the width of the track it
/// opens, who is allowed to override it, and — the one that matters most — what
/// it does NOT do to the starved-audio alarm.
///
/// `AudioChannelDetectorTests` pins the measurement. This pins the consequences,
/// end to end through the pipeline and into the file, because the mask is
/// latched at take open and read again by the trim, the track width and the log
/// row, and a change that moved one of those without the others would pass any
/// unit test of the detector alone.
@Suite struct AudioChannelDefaultTests {
    /// A sixteen-channel embed carrying a tone on channels 1-2 and bit-exact
    /// zero on the other fourteen — the HDMI camera this whole feature is about.
    final class Embed {
        private var cache: CMAudioFormatDescription?
        private var frames: Int64 = 0
        let channels: Int
        let carrying: [Int]

        init(channels: Int, carrying: [Int]) {
            self.channels = channels
            self.carrying = carrying
        }

        func next() -> CMSampleBuffer? {
            var samples = [Int16](repeating: 0, count: 1920 * channels)
            for channel in carrying {
                for frame in 0..<1920 {
                    samples[frame * channels + channel] =
                        frame % 2 == 0 ? 9_000 : -9_000
                }
            }
            let pts = Double(frames) / 48_000
            frames += 1920
            return samples.withUnsafeBytes { raw -> CMSampleBuffer? in
                guard let bytes = raw.baseAddress else { return nil }
                return PCMAudio.makeSampleBuffer(
                    bytes: bytes, sampleFrames: 1920, channelCount: channels,
                    ptsSeconds: pts, formatCache: &cache)
            }
        }
    }

    /// Frames at the live pace with the embed's packets alongside — the same
    /// shape as `ExternalAudioPreRollTests.Feeder`, on the embedded path.
    final class Feeder {
        private let pipeline: CapturePipeline
        private let embed: Embed
        private let frame = TestMedia.pixelBuffer()
        private var millis = 0

        init(pipeline: CapturePipeline, embed: Embed) {
            self.pipeline = pipeline
            self.embed = embed
        }

        func push(frames: Int, withAudio: Bool = true) async throws {
            for _ in 0..<frames {
                millis += 40
                pipeline.handleFrame(
                    pixelBuffer: frame,
                    pts: CMTime(value: CMTimeValue(millis), timescale: 1000),
                    timecode: nil)
                if withAudio, let packet = embed.next() {
                    pipeline.handleAudio(packet)
                }
                try await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    private static func pipeline(root: URL,
                                 settings: CaptureSettings? = nil) -> CapturePipeline {
        CapturePipeline(config: .init(
            settings: settings
                ?? TakeIntegrityBoundsTests.settings(root: root, preRoll: 0),
            takeNumber: 1))
    }

    /// One take, driven from standby through to a finished file.
    private static func roll(pipeline: CapturePipeline, embed: Embed,
                             standbyFrames: Int, takeFrames: Int,
                             audio: Bool = true) async throws -> Take {
        let recStates = EventCollector<Bool>()
        let finished = TakeCollector()
        pipeline.onRecStateChanged = { recStates.append($0) }
        pipeline.onTakeFinished = { finished.append($0) }
        pipeline.handleFormat(TakeIntegrityBoundsTests.format)
        pipeline.setExpectedAudioChannels(embed.channels)

        let feeder = Feeder(pipeline: pipeline, embed: embed)
        try await feeder.push(frames: standbyFrames, withAudio: audio)
        pipeline.toggleManualRecord()
        #expect(await TestWait.becomesTrue { pipeline.health.isRecording },
                "the take never opened")
        try await feeder.push(frames: takeFrames, withAudio: audio)
        pipeline.toggleManualRecord()

        await TestWait.untilWritten { recStates.last == false }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { !finished.isEmpty }
        return try #require(finished.first, "the take was never published")
    }

    /// The fix, stated as the file: a camera embedding stereo into a declaration
    /// of sixteen gets a two-channel take.
    ///
    /// Before this, `CDLCapture.embeddedAudioChannels`'s hard-coded 16 went
    /// straight into the track width and every take carried fourteen channels of
    /// nothing — 1.5 MB/s of it, and fourteen empty tracks arriving in the edit.
    ///
    /// Would still pass if the mask regressed the other way (too NARROW): the
    /// companion test below is the one that fails then, because it feeds every
    /// channel and requires all sixteen back.
    @Test func aStereoEmbedInASixteenChannelDeclarationRecordsTwoChannels()
        async throws {
        let root = TestMedia.scratchDirectory("AudioAutoStereoEmbed")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = Self.pipeline(root: root)
        let take: Take = try await Self.roll(
            pipeline: pipeline, embed: Embed(channels: 16, carrying: [0, 1]),
            standbyFrames: 30, takeFrames: 15)

        let channels: Int = try await TestAudio.channelCount(of: take.url)
        #expect(channels == 2,
                "the take opened \(channels) channels for a stereo embed")
    }

    /// …and a source that really is carrying sixteen keeps all sixteen. The
    /// other direction of the same decision, and the one that says the
    /// measurement is a measurement rather than a smaller constant.
    @Test func anEmbedCarryingEveryChannelKeepsEveryChannel() async throws {
        let root = TestMedia.scratchDirectory("AudioAutoFullEmbed")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = Self.pipeline(root: root)
        let take: Take = try await Self.roll(
            pipeline: pipeline,
            embed: Embed(channels: 16, carrying: Array(0..<16)),
            standbyFrames: 30, takeFrames: 15)

        let channels: Int = try await TestAudio.channelCount(of: take.url)
        #expect(channels == 16,
                "a full sixteen-channel embed was cut to \(channels)")
    }

    /// **The alarm is untouched, and this is why.** A camera whose audio is
    /// switched off delivers no packets at all, so there is nothing to measure,
    /// so the measurement says nothing, so the take opens every declared channel
    /// exactly as it did before — which the writer's backstop then pads and
    /// `takeAudioStarved` names.
    ///
    /// This is the case the alarm exists for (the camera muted by mistake), and
    /// an auto-detect that answered "no channels carried, record none" would
    /// have made it unreachable: a silent take with no track and no alarm, found
    /// in the edit. The detector answers only with POSITIVE evidence for exactly
    /// this reason.
    ///
    /// Would still pass if the detection regressed to "never answer at all" —
    /// the two tests above are what fail then.
    @Test func aCameraWithItsAudioOffStillOpensEveryChannelAndStillSaysSo()
        async throws {
        let root = TestMedia.scratchDirectory("AudioAutoMutedCamera")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = Self.pipeline(root: root)
        let errors = EventCollector<PipelineAlarm>()
        pipeline.onError = { errors.append($0) }
        let take: Take = try await Self.roll(
            pipeline: pipeline, embed: Embed(channels: 8, carrying: []),
            standbyFrames: 30, takeFrames: 60, audio: false)

        let channels: Int = try await TestAudio.channelCount(of: take.url)
        #expect(channels == 8,
                "nothing was measured, yet the track came out \(channels) wide")
        let starved: [PipelineAlarm] = errors.all.filter { $0 == .takeAudioStarved }
        #expect(starved.count == 1,
                "the muted camera raised \(starved.count) starvation alarms")
        #expect(take.comment.contains("audio track starved"),
                "the log row lost it: \(take.comment)")
    }

    /// A source that IS delivering, on channels that are all bit-exact zero, is
    /// the same non-answer: it has told us it is silent, not which of its
    /// channels are real.
    ///
    /// Following a signal up costs padded bandwidth; following it down costs
    /// footage. So the take is wide, and it is wide for a stated reason rather
    /// than by accident.
    @Test func aDeliveringButDigitallySilentSourceIsNotNarrowed() async throws {
        let root = TestMedia.scratchDirectory("AudioAutoDigitalSilence")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = Self.pipeline(root: root)
        let take: Take = try await Self.roll(
            pipeline: pipeline, embed: Embed(channels: 16, carrying: []),
            standbyFrames: 40, takeFrames: 15)

        let channels: Int = try await TestAudio.channelCount(of: take.url)
        #expect(channels == 16,
                "a silent source was read as a channel layout: \(channels)")
    }

    /// The operator's own mask is never widened or narrowed by the measurement.
    /// Auto fills the nil and does nothing else — which is what makes "you can
    /// override it" a property of one expression rather than of a mode.
    @Test func aMaskTheOperatorChoseWins() async throws {
        let root = TestMedia.scratchDirectory("AudioAutoOperatorMask")
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = TakeIntegrityBoundsTests.settings(root: root, preRoll: 0)
        settings.audio.audioChannelMask = 0b1 // channel 1 alone
        let pipeline = Self.pipeline(root: root, settings: settings)
        let take: Take = try await Self.roll(
            pipeline: pipeline, embed: Embed(channels: 16, carrying: [0, 1]),
            standbyFrames: 30, takeFrames: 15)

        let channels: Int = try await TestAudio.channelCount(of: take.url)
        #expect(channels == 1,
                "the measurement overrode the operator: \(channels) channels")
    }

    /// …and switching auto off is the other override: no mask at all, every
    /// declared channel, exactly the behaviour this app had before the
    /// measurement existed.
    ///
    /// Worth its own test rather than folded into the one above, because it is
    /// the escape hatch. A switch that stops the app acting on a measurement is
    /// fine — the operator can see what it does — and this is where "fine" is
    /// checked rather than asserted.
    @Test func switchingTheMeasurementOffRecordsEveryDeclaredChannel()
        async throws {
        let root = TestMedia.scratchDirectory("AudioAutoOff")
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = TakeIntegrityBoundsTests.settings(root: root, preRoll: 0)
        settings.audio.audioChannelAuto = false
        let pipeline = Self.pipeline(root: root, settings: settings)
        let take: Take = try await Self.roll(
            pipeline: pipeline, embed: Embed(channels: 16, carrying: [0, 1]),
            standbyFrames: 30, takeFrames: 15)

        let channels: Int = try await TestAudio.channelCount(of: take.url)
        #expect(channels == 16,
                "auto was off and the take still came out \(channels) wide")
    }

    /// The first take after launch, when standby has been short.
    ///
    /// Half a second of standby is not enough to call fourteen channels dead, so
    /// nothing is called dead: the take opens every declared channel, the
    /// backstop and the alarm are exactly where they were, and the operator has
    /// lost nothing. The measurement's cost is paid in bandwidth on the first
    /// take of a session and never in footage.
    @Test func aTakeOpenedBeforeASecondOfStandbyRecordsEveryChannel()
        async throws {
        let root = TestMedia.scratchDirectory("AudioAutoShortStandby")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = Self.pipeline(root: root)
        // 12 frames is 0.48 s — under the one-second window, deliberately
        let take: Take = try await Self.roll(
            pipeline: pipeline, embed: Embed(channels: 16, carrying: [0, 1]),
            standbyFrames: 12, takeFrames: 15)

        let channels: Int = try await TestAudio.channelCount(of: take.url)
        #expect(channels == 16,
                "half a second of standby decided the take's width: \(channels)")
    }

    /// A source SWITCH throws the measurement away, and the answer the panel is
    /// holding with it.
    ///
    /// A sixteen-channel embed's "1-2 carry signal" is a statement about the
    /// BOARD's channels 1 and 2. Applied to the USB cart that replaced it, it is
    /// a mask made of another device's channels — and the operator would be
    /// reading a panel still claiming the old measurement while the take
    /// recorded under the new source.
    @Test func switchingTheAudioSourceThrowsTheMeasurementAway() async throws {
        let root = TestMedia.scratchDirectory("AudioAutoSourceSwitch")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = Self.pipeline(root: root)
        let answers = EventCollector<Int?>()
        pipeline.onAudioChannelsDetected = { answers.append($0) }
        pipeline.handleFormat(TakeIntegrityBoundsTests.format)
        pipeline.setExpectedAudioChannels(16)
        let feeder = Feeder(pipeline: pipeline,
                            embed: Embed(channels: 16, carrying: [0, 1]))
        try await feeder.push(frames: 30)
        let measured: Int? = pipeline.queue.sync { pipeline.detectedAudioMask }
        #expect(measured == 0b11,
                "the embed was never measured at all: \(measured as Any)")

        pipeline.setActiveAudioSource(.external, expectedChannels: 2)

        let cleared: Int? = pipeline.queue.sync { pipeline.detectedAudioMask }
        #expect(cleared == nil,
                "the board's answer survived onto the USB cart: \(cleared as Any)")
        await TestWait.untilWritten { answers.last == Int?.none }
        #expect(answers.last == Int?.none,
                "the panel was never told the old answer had gone")
    }

    /// The mask is LATCHED: a measurement that lands mid-take changes the next
    /// take and not this one.
    ///
    /// The take here opens on a short standby (all sixteen) and then runs long
    /// enough for the measurement to answer 1-2 underneath it. The writer's
    /// channel count is fixed at start, so a mask that moved under the open file
    /// would trim two-channel packets into a sixteen-channel track — which
    /// AVAssetWriter does not refuse, it MISREADS (see `TakeWriter.conformed`).
    @Test func anAnswerArrivingMidTakeDoesNotMoveTheOpenTake() async throws {
        let root = TestMedia.scratchDirectory("AudioAutoLatched")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = Self.pipeline(root: root)
        let take: Take = try await Self.roll(
            pipeline: pipeline, embed: Embed(channels: 16, carrying: [0, 1]),
            standbyFrames: 5, takeFrames: 40)

        let channels: Int = try await TestAudio.channelCount(of: take.url)
        #expect(channels == 16,
                "the open take's track width followed a live measurement")
        // …and the answer IS there by the end, so this is a latch rather than a
        // detector that never ran.
        let detected: Int? = pipeline.queue.sync { pipeline.detectedAudioMask }
        #expect(detected == 0b11,
                "the measurement never answered at all: \(detected as Any)")
    }
}
