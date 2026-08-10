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

    // MARK: - the crash the fragment interval exists for

    /// `movieFragmentInterval` is set so a crash or a power loss mid-take does
    /// not cost the whole file. Nothing pinned that, and the property being
    /// assigned is not the same statement as the bytes being on disk.
    ///
    /// A writer that is simply abandoned — never finished, never cancelled — is
    /// the file a killed process leaves behind. It has to be readable, and its
    /// duration has to be most of what was written.
    ///
    /// **It is not, and that is a KNOWN GAP awaiting a decision rather than a
    /// test that has not been written yet.** A take carries a timecode track
    /// whose only samples are appended in `finish()`, so that input has no data
    /// while the take rolls, and `AVAssetWriter` will not cut a fragment until
    /// EVERY input has data up to the boundary. Measured on this machine: an
    /// abandoned single-track file is `ftyp` + `moov` + `moof`/`mdat` pairs and
    /// reads back as 10 s of 13; add one input that never receives a sample and
    /// the same file is `ftyp` + one 170 KB `mdat` with **no `moov` at all**. So
    /// the picture is on disk and nothing describes it — a crash mid-take costs
    /// the whole take, which is the case the fragment interval is there for.
    ///
    /// Both candidate fixes change what every take file contains, which is why
    /// this is pinned as a known issue instead: appending the timecode samples
    /// as the take runs (one per interval, lagging, which keeps
    /// `addTimecodeResync` working), or appending the start sample and marking
    /// that input finished at once (simpler, and it retires the resync). Both
    /// were measured to restore the 10-of-13 seconds. Remove the
    /// `withKnownIssue` when one of them lands.
    @Test func anAbandonedTakeIsStillReadableUpToItsLastFragment() async throws {
        let root = TestMedia.scratchDirectory("AbandonedTake")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url: URL = root.appendingPathComponent("abandoned.mov")

        try await Self.abandonWriter(at: url, frames: 325) // 13 s at 25 fps
        // This half holds today and is where the teeth are: the picture really
        // is on disk, so what is missing is only the moov that describes it.
        let size: Int = (try FileManager.default.attributesOfItem(
            atPath: url.path)[.size] as? Int) ?? 0
        #expect(size > 100_000,
                "the abandoned take left \(size) bytes — no picture at all")

        // `isIntermittent` because the two hosts need not agree: this is
        // AVAssetWriter's fragmenting rule, CI is two macOS releases behind, and
        // asserting either answer would pin the host rather than this app (the
        // same reason the HDR file test prints instead of asserting). What is
        // NOT host-dependent is the reproduction above, and the moment the gap
        // is closed this becomes a plain assertion.
        await withKnownIssue("a crash mid-take loses the whole file",
                             isIntermittent: true) {
            let asset = AVURLAsset(url: url)
            let duration: Double = (try await asset.load(.duration)).seconds
            #expect(duration > 5,
                    "an abandoned 13 s take reads back as \(duration) s")
            let tracks: [AVAssetTrack] = try await asset.tracks(ofType: .video)
            #expect(tracks.count == 1,
                    "the abandoned take has \(tracks.count) video tracks")
        }
    }

    /// Write `frames` and let the writer go without finishing it. Its own
    /// function so the instance is released before the assertions run.
    private static func abandonWriter(at url: URL, frames: Int) async throws {
        let writer = try TakeWriter(
            url: url, format: Self.format, codec: .proResProxy,
            startTimecode: Timecode(hours: 10, minutes: 0, seconds: 0,
                                    frames: 0, fps: 25))
        let picture: CVPixelBuffer = TestMedia.pixelBuffer()
        for index: Int in 0..<frames {
            let pts = CMTime(value: CMTimeValue(index * 1000), timescale: 25_000)
            var attempts: Int = 0
            while !writer.append(pixelBuffer: picture, pts: pts), attempts < 400 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }
}
