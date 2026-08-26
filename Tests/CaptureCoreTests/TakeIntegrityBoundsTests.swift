import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The ceilings and the timestamps: what the capture path holds in memory when
/// the board misbehaves, and what a take's audio does when the pre-roll and a
/// USB source meet.
///
/// Every rule here is one the pipeline already states somewhere — the pre-roll
/// ring has a hard memory ceiling, a take's audio is continuous, a crash
/// mid-take must not cost the whole file. What these pin is the cases where the
/// rule was written for one input and the board can supply another: a packet
/// stamped in the wrong century, a frame whose stream time jumps, an audio
/// source whose channel count moves under a cached format description.
@Suite struct TakeIntegrityBoundsTests {
    static let format = CaptureFormat(
        width: 320, height: 180, frameRate: 25, timecodeFPS: 25, name: "test 25")

    static func settings(root: URL, preRoll: Int) -> CaptureSettings {
        var settings = CaptureSettings()
        settings.capture.codec = .proResProxy // the tests encode in real time
        settings.capture.destinationPath = root.path
        settings.naming.namingTemplate = "{scene}_T{take}_{tc}"
        settings.naming.projectName = "Test"
        settings.capture.detectionMode = .manual
        settings.capture.preRollFrames = preRoll
        return settings
    }

    // MARK: - the audio pre-roll ring

    /// The picture ring is bounded by a frame COUNT computed from a memory
    /// budget; the audio ring beside it is bounded by a TIME WINDOW measured
    /// against the oldest packet it holds. A window is only a bound while the
    /// clock goes forwards.
    ///
    /// One packet stamped far in the future makes every later packet look OLDER
    /// than the oldest one held, so the trim never fires again and the ring
    /// grows for as long as the app stands by. At sixteen channels a 40 ms
    /// packet is ~60 KB, i.e. ~1.5 MB a second — a shooting day of RAM on one
    /// bad timestamp.
    @Test func aMisstampedAudioPacketDoesNotUnboundTheAudioPreRollRing() async throws {
        let root = TestMedia.scratchDirectory("PreRollAudioCeiling")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = CapturePipeline(config: .init(
            settings: Self.settings(root: root, preRoll: 10), takeNumber: 1))
        pipeline.handleFormat(Self.format)

        var cache: CMAudioFormatDescription?
        // a board that mis-stamps exactly one packet — an hour into the future
        let stray: CMSampleBuffer = try #require(
            TestMedia.audioBuffer(seconds: 3600, channels: 2, cache: &cache),
            "the fixture could not build the stray packet")
        pipeline.handleAudio(stray)
        // …and then MORE than the ceiling of perfectly good ones, because a
        // count under it proves nothing about a ring that is not bounded at all
        for index: Int in 0..<(CapturePipeline.maximumPreRollAudioPackets + 600) {
            let packet: CMSampleBuffer = try #require(
                TestMedia.audioBuffer(seconds: Double(index) * 0.04,
                                      channels: 2, cache: &cache),
                "the fixture could not build a packet")
            pipeline.handleAudio(packet)
        }

        let held: Int = pipeline.queue.sync { pipeline.preRollAudio.count }
        #expect(held <= CapturePipeline.maximumPreRollAudioPackets,
                "the audio pre-roll ring is holding \(held) packets")
    }

    /// …and the ceiling is the BACKSTOP, not the bound that does the work: the
    /// same feed with no stray packet in it is trimmed to the window, which is
    /// three orders of magnitude tighter. Without this the test above passes just
    /// as well if the time trim stops firing altogether.
    @Test func anHonestFeedIsStillTrimmedToTheWindowAndNotTheCeiling() async throws {
        let root = TestMedia.scratchDirectory("PreRollAudioWindow")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = CapturePipeline(config: .init(
            settings: Self.settings(root: root, preRoll: 10), takeNumber: 1))
        pipeline.handleFormat(Self.format)

        var cache: CMAudioFormatDescription?
        for index: Int in 0..<400 {
            let packet: CMSampleBuffer = try #require(
                TestMedia.audioBuffer(seconds: Double(index) * 0.04,
                                      channels: 2, cache: &cache),
                "the fixture could not build a packet")
            pipeline.handleAudio(packet)
        }

        // window = 10 frames / 25 fps + 1 s of slack = 1.4 s, i.e. 35 packets
        let held: Int = pipeline.queue.sync { pipeline.preRollAudio.count }
        #expect(held <= 40, "an honest feed left \(held) packets in the ring")
    }

    /// …and the ceiling does not shorten the window it exists to protect. The
    /// worst honest combination the app can be put into: the settings pane's
    /// deepest pre-roll (100 frames) at the slowest rate it supports (23.976),
    /// against a USB interface running 512-sample buffers — ~94 packets a second
    /// rather than the board's 25.
    @Test func theAudioCeilingIsAboveTheDeepestHonestPreRoll() {
        let windowSeconds: Double = 100.0 / 23.976 + 1.0 // + the jitter slack
        let packetsPerSecond: Double = 48_000 / 512
        let wanted: Int = Int((windowSeconds * packetsPerSecond).rounded(.up))
        #expect(wanted < CapturePipeline.maximumPreRollAudioPackets,
                "the deepest honest pre-roll wants \(wanted) packets")
    }

    // MARK: - what a shortened ring costs, said out loud

    /// The memory ceiling's justification is that a short ring costs the head of
    /// ONE take "and those frames are counted and shown". They were not: the
    /// eviction is silent and the drain only ever counted frames the WRITER
    /// refused, so a ring the budget had shortened produced a take with a short
    /// head and no notice at all.
    ///
    /// Arithmetic rather than a pipeline, for the same reason `preRollCapacity`
    /// is: reaching a shortened ring needs a 12-bit UHD signal, which no
    /// synthetic feed in this suite is, and the answer is a count either way.
    @Test func aRingTheBudgetShortenedReportsWhatItCouldNotHold() {
        // 12-bit UHD: 100 frames of pre-roll asked for, 22 held (see
        // `PreRollAudioTests.theRingStaysInsideItsBudgetAtTwelveBitUHD`), a take
        // detected on frame 500
        let missing: Int = CapturePipeline.preRollShortfall(
            startIndex: 500, cutoff: 400, heldInWindow: 22)
        #expect(missing == 79, "a shortened ring reported \(missing) frames")

        // …and a ring that held the whole window says nothing
        #expect(CapturePipeline.preRollShortfall(startIndex: 500, cutoff: 400,
                                                 heldInWindow: 101) == 0)
    }

    /// The first take of a session legitimately has fewer frames behind it than
    /// the window asks for. Reporting that would put a notice on screen at the
    /// top of every shooting day — which is how an operator learns to ignore the
    /// banner that matters.
    @Test func theFirstTakeOfASessionIsNotAShortfall() {
        // REC on capture frame 3, with a 100-frame pre-roll configured: the ring
        // holds frames 1, 2 and 3 and that is all there has ever been
        #expect(CapturePipeline.preRollShortfall(startIndex: 3, cutoff: 0,
                                                 heldInWindow: 3) == 0)
        // …and a take opened before the first frame at all
        #expect(CapturePipeline.preRollShortfall(startIndex: 0, cutoff: 0,
                                                 heldInWindow: 0) == 0)
    }

    // MARK: - a cached audio format against a channel count that moved

    /// `PCMAudio.makeSampleBuffer` caches the format description because
    /// building one per 40 ms packet is real work. The cache was keyed on
    /// nothing: a cached description was reused whatever channel count the
    /// caller asked for, so a source whose count changed produced buffers that
    /// DESCRIBED the old count and CARRIED the new one — mis-interleaved audio,
    /// silently, in the file.
    ///
    /// The pipeline resets its caches on the two changes it is told about — the
    /// operator's channel mask and a source switch — and cannot reset them for
    /// the one it only learns from a packet, which is a source changing its own
    /// count (`handleAudio` assigns `sourceAudioChannels` per packet, and the
    /// silence padding is built from that live count).
    @Test func aCachedAudioFormatIsNotReusedForADifferentChannelCount() throws {
        var cache: CMAudioFormatDescription?
        let two: CMSampleBuffer = try #require(
            TestMedia.audioBuffer(seconds: 0, channels: 2, cache: &cache),
            "the fixture could not build the two-channel packet")
        let twoCount: Int = PCMAudio.peakLevels(of: two).count
        #expect(twoCount == 2, "a two-channel packet reads as \(twoCount)")

        let eight: CMSampleBuffer = try #require(
            TestMedia.audioBuffer(seconds: 0.04, channels: 8, cache: &cache),
            "the fixture could not build the eight-channel packet")
        let eightCount: Int = PCMAudio.peakLevels(of: eight).count
        #expect(eightCount == 8,
                "an eight-channel packet describes itself as \(eightCount)")
    }

    /// …and the pipeline half of the same event, which is the one that costs a
    /// take. The writer's channel count is latched when the take opens; a source
    /// that changes its own count mid-take then hands `recordAudio` a packet of a
    /// different width, and `selectChannels` filters the mask to what ARRIVED, so
    /// a shrunk packet reaches a wider track. The integrity rules say that kills
    /// the file, and nothing guarded it: the audio input refuses the packet, the
    /// writer goes to `.failed`, and the next video frame closes the take as a
    /// loss — the rest of the shot gone because the sound changed shape.
    ///
    /// The packets are conformed to the latched count instead: extra channels
    /// trimmed, missing ones silent. The take survives, and the change is
    /// reported in the sticky register because the channel MAP after it is a
    /// guess — post has to know before the edit, not after.
    @Test func aSourceThatChangesChannelCountMidTakeDoesNotCostTheTake() async throws {
        let root = TestMedia.scratchDirectory("AudioChannelsMoved")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = CapturePipeline(config: .init(
            settings: Self.settings(root: root, preRoll: 0), takeNumber: 1))
        let takes = TakeCollector()
        let errors = EventCollector<PipelineAlarm>()
        let recStates = EventCollector<Bool>()
        pipeline.onTakeFinished = { takes.append($0) }
        pipeline.onError = { errors.append($0) }
        pipeline.onRecStateChanged = { recStates.append($0) }
        pipeline.handleFormat(Self.format)

        let feed = ChannelChangingFeed(pipeline: pipeline)
        try await feed.push(frames: 4, audioChannels: 8) // the writer latches 8
        pipeline.toggleManualRecord()
        #expect(await TestWait.becomesTrue { pipeline.health.isRecording },
                "the take never opened")
        try await feed.push(frames: 6, audioChannels: 8)
        try await feed.push(frames: 10, audioChannels: 2) // …and the source moves
        pipeline.toggleManualRecord()

        await TestWait.untilWritten { recStates.last == false }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { !takes.isEmpty }

        let take: Take = try #require(takes.first,
                                      "the take was lost to the channel change")
        #expect(pipeline.health.takesFailedToFinalize == 0,
                "the channel change killed the finalize")
        #expect(!errors.all.contains { $0.message.contains("TAKE LOST") },
                "the channel change was reported as a lost take")
        #expect(errors.contains(.takeAudioChannelsConformed(from: 2, to: 8)),
                "the channel change was never reported")
        #expect(PipelineAlarm.takeAudioChannelsConformed(from: 2, to: 8)
                    .severity == .integrity,
                "a guessed channel map was reported as a passing notice")

        // …and the track really is the width it was declared: a file whose
        // header says eight and whose samples carry two is unplayable audio.
        await TestWait.fileExists(at: take.url)
        let channels: Int = try await TestAudio.channelCount(of: take.url)
        #expect(channels == 8,
                "the take's audio track came out with \(channels) channel(s)")

        // The damage a bare mismatch actually does on this host, and the reason
        // the file is what has to be asserted rather than the writer's status:
        // an 8-channel track fed 2-channel packets is not refused, it is
        // MISREAD — a 1920-frame packet of two channels is 480 frames of eight,
        // so the sound runs out a quarter of the way through and the tail of the
        // take is silent. Nothing anywhere says so.
        let audio: (first: Double?, seconds: Double) =
            try await TestAudio.span(of: take.url)
        let picture: Double = try await AVURLAsset(url: take.url)
            .load(.duration).seconds
        #expect(audio.seconds > picture - 0.2,
                "\(audio.seconds) s of sound under \(picture) s of picture")
    }

    /// …and the same change one moment EARLIER, which is a different code path
    /// and was the reason the guard belongs in the writer rather than in
    /// `recordAudio`. A source that changes its count while the app stands by
    /// leaves the pre-roll ring holding the old width and the take latching the
    /// new one, and the drain appends those packets without going through the
    /// live path at all — so a guard on the live path alone leaves the HEAD of
    /// the take mis-shaped, which is the part pre-roll exists to save.
    @Test func aChannelCountThatMovedInsideThePreRollIsConformedToo() async throws {
        let root = TestMedia.scratchDirectory("AudioChannelsPreRoll")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = CapturePipeline(config: .init(
            settings: Self.settings(root: root, preRoll: 10), takeNumber: 1))
        let takes = TakeCollector()
        let errors = EventCollector<PipelineAlarm>()
        let recStates = EventCollector<Bool>()
        pipeline.onTakeFinished = { takes.append($0) }
        pipeline.onError = { errors.append($0) }
        pipeline.onRecStateChanged = { recStates.append($0) }
        pipeline.handleFormat(Self.format)

        let feed = ChannelChangingFeed(pipeline: pipeline)
        // eight channels into the ring, then the source drops to two, and only
        // THEN does the take open — so the latch is 2 and the ring holds 8
        try await feed.push(frames: 6, audioChannels: 8)
        try await feed.push(frames: 3, audioChannels: 2)
        pipeline.toggleManualRecord()
        #expect(await TestWait.becomesTrue { pipeline.health.isRecording },
                "the take never opened")
        try await feed.push(frames: 8, audioChannels: 2)
        pipeline.toggleManualRecord()

        await TestWait.untilWritten { recStates.last == false }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { !takes.isEmpty }

        let take: Take = try #require(takes.first,
                                      "the take was lost to the channel change")
        #expect(errors.contains(.takeAudioChannelsConformed(from: 8, to: 2)),
                "a pre-roll packet of the old width was never reported")
        #expect(take.comment.contains("audio channel count changed"),
                "the log row says nothing: \(take.comment)")

        // Eight channels read as two is FOUR TIMES the samples, so the failure
        // here is sound running past the picture rather than falling short of it
        // — the head of the take overlapping everything after it.
        await TestWait.fileExists(at: take.url)
        let audio: (first: Double?, seconds: Double) =
            try await TestAudio.span(of: take.url)
        let picture: Double = try await AVURLAsset(url: take.url)
            .load(.duration).seconds
        #expect(audio.seconds < picture + 0.2,
                "\(audio.seconds) s of sound under \(picture) s of picture")
        let channels: Int = try await TestAudio.channelCount(of: take.url)
        #expect(channels == 2,
                "the take's audio track came out with \(channels) channel(s)")
    }

    /// Frames at the live pace with one embedded audio packet beside each, at a
    /// channel count the caller can change mid-run — which is the input no
    /// shared fixture produces, and the only way to reach the latch.
    private final class ChannelChangingFeed {
        private let pipeline: CapturePipeline
        private let picture: CVPixelBuffer = TestMedia.pixelBuffer()
        /// One cache across both widths on purpose: rebuilding it when the count
        /// moves is exactly what `PCMAudio.makeSampleBuffer` has to do.
        private var cache: CMAudioFormatDescription?
        private var frame = 0

        init(pipeline: CapturePipeline) {
            self.pipeline = pipeline
        }

        func push(frames: Int, audioChannels: Int) async throws {
            for _ in 0..<frames {
                frame += 1
                pipeline.handleFrame(
                    pixelBuffer: picture,
                    pts: CMTime(value: CMTimeValue(frame * 40), timescale: 1000),
                    timecode: nil)
                if let packet: CMSampleBuffer = TestMedia.audioBuffer(
                    seconds: Double(frame) * 0.04, channels: audioChannels,
                    cache: &cache) {
                    pipeline.handleAudio(packet)
                }
                try await Task.sleep(for: .milliseconds(40))
            }
        }
    }
}

/// The crash the fragment interval exists for, in its own extension so the
/// suite above stays inside the house type-body limit — one theme per block, and
/// this one is about what survives a process that never finishes its writer.
extension TakeIntegrityBoundsTests {
    /// `movieFragmentInterval` is set so a crash or a power loss mid-take does
    /// not cost the whole file. Nothing pinned that, and the property being
    /// assigned is not the same statement as the bytes being on disk.
    ///
    /// A writer that is simply abandoned — never finished, never cancelled — is
    /// the file a killed process leaves behind. It has to be readable, and its
    /// duration has to be most of what was written.
    ///
    /// It was not, and the reason was the timecode track: its only samples were
    /// appended in `finish()`, so that input had no data while the take rolled,
    /// and `AVAssetWriter` will not cut a fragment until EVERY input has data up
    /// to the boundary. Measured on this machine: an abandoned single-track file
    /// is `ftyp` + `moov` + `moof`/`mdat` pairs and reads back as 10 s of 13; add
    /// one input that never receives a sample and the same file is `ftyp` + one
    /// 170 KB `mdat` with **no `moov` at all**. The picture was on disk and
    /// nothing described it — so the guarantee held only for a take with no
    /// timecode and no audio, which is the case nobody has.
    ///
    /// The timecode samples are now written AS THE TAKE RUNS — one per second,
    /// lagging the picture by that much (`TakeWriter.commitTimecodeSamples`), so
    /// what a crash costs is the fragment still open. Measured here: 10 s of the
    /// 13 come back. This used to be pinned with `withKnownIssue`; it is a plain
    /// assertion because the gap is closed, and the bound is deliberately 5 s
    /// rather than 10 so that a host which fragments on a different boundary
    /// (CI is two macOS releases behind) reports the loss of the GUARANTEE
    /// rather than the loss of a second.
    @Test func anAbandonedTakeIsStillReadableUpToItsLastFragment() async throws {
        let root = TestMedia.scratchDirectory("AbandonedTake")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url: URL = root.appendingPathComponent("abandoned.mov")

        try await Self.abandonWriter(at: url, frames: 325) // 13 s at 25 fps
        // The picture on disk, which held even while the moov did not.
        let size: Int = (try FileManager.default.attributesOfItem(
            atPath: url.path)[.size] as? Int) ?? 0
        #expect(size > 100_000,
                "the abandoned take left \(size) bytes — no picture at all")

        let asset = AVURLAsset(url: url)
        let duration: Double = (try await asset.load(.duration)).seconds
        #expect(duration > 5,
                "an abandoned 13 s take reads back as \(duration) s")
        let tracks: [AVAssetTrack] = try await asset.tracks(ofType: .video)
        #expect(tracks.count == 1,
                "the abandoned take has \(tracks.count) video tracks")
    }

    /// …and the same crash on the take an operator actually shoots. The case
    /// above is the one the gap was measured on; every real take also carries
    /// audio, which is a SECOND input the fragment boundary waits for — so a
    /// timecode fix that worked only for a silent take would leave the rule
    /// broken for every file on the disk.
    @Test func anAbandonedTakeWithSoundIsStillReadable() async throws {
        let root = TestMedia.scratchDirectory("AbandonedTakeAudio")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url: URL = root.appendingPathComponent("abandoned-audio.mov")

        try await Self.abandonWriter(at: url, frames: 325, audioChannels: 2)
        let asset = AVURLAsset(url: url)
        let duration: Double = (try await asset.load(.duration)).seconds
        #expect(duration > 5,
                "an abandoned 13 s take with sound reads back as \(duration) s")
        let audio: [AVAssetTrack] = try await asset.tracks(ofType: .audio)
        #expect(audio.count == 1,
                "the abandoned take has \(audio.count) audio tracks")
    }

    /// …and the take where the board DECLARED audio and then never delivered a
    /// packet. The same shape the timecode track had, one input over: the writer
    /// opens an audio input because the signal said it carried channels, the
    /// embedded audio never arrives, and `movieFragmentInterval` will not cut a
    /// fragment until EVERY input has passed the boundary.
    ///
    /// Measured on this tree before the fix, and it is the worst failure this
    /// project has — not a degraded take but no take: the abandoned file is
    /// `ftyp` plus one `mdat` with no `moov` at all, and
    ///
    ///     Error Domain=AVFoundationErrorDomain Code=-11829 "Cannot Open"
    ///     NSLocalizedFailureReason=This media may be damaged.
    ///
    /// is what the operator's picture comes back as. Nothing exotic gets there:
    /// `CDLCapture.embeddedAudioChannels` is a hard-coded 16 handed to the
    /// pipeline at capture start, so an HDMI camera with its audio switched off
    /// reaches this on every take it shoots.
    ///
    /// The track is asserted present as well as the file being readable, and
    /// that is the other direction this can regress in: simply not opening an
    /// audio input until the first packet arrived would satisfy every assertion
    /// about the file OPENING while quietly costing the take its sound (see
    /// `TakeWriter.padAudioIfNeeded` for why that was rejected).
    @Test func anAbandonedTakeWithADeclaredButUnfedAudioTrackIsStillReadable()
        async throws {
        let root = TestMedia.scratchDirectory("AbandonedTakeUnfedAudio")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url: URL = root.appendingPathComponent("abandoned-unfed.mov")

        try await Self.abandonWriter(at: url, frames: 325, audioChannels: 2,
                                     feedAudio: false)
        let size: Int = (try FileManager.default.attributesOfItem(
            atPath: url.path)[.size] as? Int) ?? 0
        #expect(size > 100_000,
                "the abandoned take left \(size) bytes — no picture at all")

        let asset = AVURLAsset(url: url)
        let duration: Double = (try await asset.load(.duration)).seconds
        #expect(duration > 5,
                "an abandoned 13 s take reads back as \(duration) s")
        let tracks: [AVAssetTrack] = try await asset.tracks(ofType: .video)
        #expect(tracks.count == 1,
                "the abandoned take has \(tracks.count) video tracks")
        let audio: [AVAssetTrack] = try await asset.tracks(ofType: .audio)
        #expect(audio.count == 1,
                "the abandoned take has \(audio.count) audio tracks")
    }

    /// Write `frames` and let the writer go without finishing it. Its own
    /// function so the instance is released before the assertions run.
    ///
    /// `feedAudio` is what tells the two audio cases apart: `audioChannels`
    /// opens the track (the board said it had channels), `feedAudio` decides
    /// whether a single packet ever reaches it.
    private static func abandonWriter(at url: URL, frames: Int,
                                      audioChannels: Int = 0,
                                      feedAudio: Bool = true) async throws {
        let writer = try TakeWriter(
            url: url, format: Self.format, codec: .proResProxy,
            startTimecode: Timecode(hours: 10, minutes: 0, seconds: 0,
                                    frames: 0, fps: 25),
            audioChannelCount: audioChannels)
        let picture: CVPixelBuffer = TestMedia.pixelBuffer()
        var cache: CMAudioFormatDescription?
        for index: Int in 0..<frames {
            let pts = CMTime(value: CMTimeValue(index * 1000), timescale: 25_000)
            var attempts: Int = 0
            while !writer.append(pixelBuffer: picture, pts: pts), attempts < 400 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
            guard audioChannels > 0, feedAudio,
                  let packet: CMSampleBuffer = TestMedia.audioBuffer(
                    seconds: Double(index) * 0.04, channels: audioChannels,
                    cache: &cache) else { continue }
            // buffered, not live: the loop feeds a take's worth of packets far
            // faster than 40 ms apart, and offered through `append` the input
            // simply refuses most of them — which would leave the audio input
            // starved and prove nothing about the fragment rule
            writer.appendBuffered(audioSampleBuffer: packet,
                                  deadline: Date().addingTimeInterval(0.5))
        }
    }
}
