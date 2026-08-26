import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The writer's own audio backstop: what it does to a track nothing is feeding,
/// and — the half that matters more — what it does to every other take, which is
/// nothing at all.
///
/// The rule it keeps is the first recording-integrity rule in CLAUDE.md.
/// `movieFragmentInterval` releases a fragment only once EVERY input has data
/// past the boundary, so an input that never receives a sample means no fragment
/// ever closes and an abandoned file has no `moov` — it does not open at all.
/// The timecode track was that input and was fixed; the audio track, opened
/// because the board DECLARED channels and then never fed, was the one left
/// (`TakeIntegrityBoundsTests
/// .anAbandonedTakeWithADeclaredButUnfedAudioTrackIsStillReadable`).
///
/// Padding silence into a real audio track is a claim about the sound, so the
/// question these answer is not "does the file open" — one test settles that —
/// but "what did it cost the takes that were fine". The answer has to be
/// nothing, and it is checked from three directions: a fed take, a LATE take,
/// and a pre-roll drain.
@Suite struct TakeWriterAudioBackstopTests {
    static let format = CaptureFormat(width: 320, height: 180, frameRate: 25,
                                      timecodeFPS: 25, name: "test 25")

    private static func makeWriter(at url: URL, channels: Int) throws -> TakeWriter {
        try TakeWriter(
            url: url, format: Self.format, codec: .proResProxy,
            startTimecode: Timecode(hours: 10, minutes: 0, seconds: 0,
                                    frames: 0, fps: 25),
            audioChannelCount: channels)
    }

    private static func scratch(_ name: String) -> URL {
        let root = TestMedia.scratchDirectory(name)
        try? FileManager.default.createDirectory(at: root,
                                                 withIntermediateDirectories: true)
        return root
    }

    /// One video frame, waited onto the encoder — the suites feed faster than
    /// real time and a refused frame proves nothing about audio.
    private static func push(_ writer: TakeWriter, frame: CVPixelBuffer,
                             index: Int) async throws {
        let pts = CMTime(value: CMTimeValue(index * 1000), timescale: 25_000)
        var attempts: Int = 0
        while !writer.append(pixelBuffer: frame, pts: pts), attempts < 400 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - what it must not change

    /// The take an operator actually shoots: sound under every frame of it.
    ///
    /// This is the pin the whole change is answerable to. A backstop that fires
    /// on a healthy take writes silence over the microphones, and the file would
    /// carry it — so the assertion is not "roughly the same length" but the
    /// EXACT span that was fed. One padded 40 ms packet anywhere in a 4 s take
    /// moves it by 40 ms and fails this.
    @Test func aNormallyFedTakeIsPaddedNowhereAndItsFileIsUnchanged() async throws {
        let root = Self.scratch("BackstopFedTake")
        defer { try? FileManager.default.removeItem(at: root) }
        let url: URL = root.appendingPathComponent("fed.mov")

        let writer = try Self.makeWriter(at: url, channels: 2)
        let frame: CVPixelBuffer = TestMedia.pixelBuffer()
        var cache: CMAudioFormatDescription?
        let frames: Int = 100 // 4 s at 25 fps — four times the starvation lead
        for index: Int in 0..<frames {
            try await Self.push(writer, frame: frame, index: index)
            let packet: CMSampleBuffer = try #require(
                TestMedia.audioBuffer(seconds: Double(index) * 0.04,
                                      channels: 2, cache: &cache),
                "the fixture could not build a packet")
            writer.appendBuffered(audioSampleBuffer: packet,
                                  deadline: Date().addingTimeInterval(0.5))
        }
        let padded: Int = writer.paddedAudioPackets
        let dropped: Int = writer.droppedAudioPackets
        let finished: URL = try await writer.finish()

        #expect(padded == 0,
                "a take with sound under every frame was padded \(padded) times")
        #expect(dropped == 0,
                "\(dropped) of a fed take's packets never reached the file")

        // …and the file says the same. `span` reads the SAMPLES rather than the
        // declared track range, which follows the writer's session and looks
        // healthy whatever is in it.
        let audio = try await TestAudio.span(of: finished)
        #expect(abs(audio.seconds - Double(frames) * 0.04) < 0.001,
                "\(audio.seconds) s of audio for \(Double(frames) * 0.04) s fed")
        // Sample times come back relative to the TRACK, so where the sound sits
        // on the take's timeline is not readable here — the span above is what
        // carries that. This only says the track has samples in it at all.
        #expect(audio.first != nil, "the take's audio track holds no samples")
        let channels: Int = try await TestAudio.channelCount(of: finished)
        #expect(channels == 2, "the take's audio track is \(channels) channels")
    }

    /// …and the take whose board is merely SLOW. A source that declared its
    /// channels honestly and takes half a second to deliver the first packet is
    /// the case a backstop firing at the first silent frame would ruin: it would
    /// write silence over the head of the take and then refuse the real packets
    /// as overlapping it.
    ///
    /// So the lead is a second (`TakeWriter.audioStarvationLead`) — the same
    /// second the timecode track already lags by, and a fifth of the fragment
    /// interval it protects, so waiting it out costs the guarantee nothing. What
    /// the app can never know is that the declaration was WRONG; all it can
    /// measure is that nothing has arrived for longer than a working source
    /// would take, and this is what that number buys.
    @Test func aSourceThatIsMerelyLateIsWaitedOutRatherThanPaddedOver() async throws {
        let root = Self.scratch("BackstopLateSource")
        defer { try? FileManager.default.removeItem(at: root) }
        let url: URL = root.appendingPathComponent("late.mov")

        let writer = try Self.makeWriter(at: url, channels: 2)
        let frame: CVPixelBuffer = TestMedia.pixelBuffer()
        var cache: CMAudioFormatDescription?
        let firstAudioFrame: Int = 15 // 0.6 s: late, but inside the lead
        for index: Int in 0..<75 {
            try await Self.push(writer, frame: frame, index: index)
            guard index >= firstAudioFrame else { continue }
            let packet: CMSampleBuffer = try #require(
                TestMedia.audioBuffer(seconds: Double(index) * 0.04,
                                      channels: 2, cache: &cache),
                "the fixture could not build a packet")
            writer.appendBuffered(audioSampleBuffer: packet,
                                  deadline: Date().addingTimeInterval(0.5))
        }
        let padded: Int = writer.paddedAudioPackets
        let dropped: Int = writer.droppedAudioPackets
        let finished: URL = try await writer.finish()

        #expect(padded == 0,
                "a source 0.6 s late was padded over \(padded) times")
        #expect(dropped == 0,
                "\(dropped) packets of a late-but-working source were refused")
        // 60 packets from 0.6 s to the end of a 3 s take, and not one more:
        // padding the head would ADD to this, and refusing the real packets as
        // overlapping invented silence would take from it. Either failure of
        // the lead moves this number.
        let audio = try await TestAudio.span(of: finished)
        #expect(abs(audio.seconds - 2.4) < 0.001,
                "\(audio.seconds) s of sound under a take fed 2.4 s of it")
    }

    /// …and the pre-roll drain, which is the one caller that appends a whole
    /// window of PICTURE before it offers the sound that goes under it.
    ///
    /// Run through the live append that path would pad the entire window and
    /// then refuse every real pre-roll packet as an overlap — the take's own
    /// head, invented, which is precisely the failure
    /// `aTakeWithPreRollIsNotPaddedOverItsOwnUSBAudio` exists for one level up.
    /// `appendBuffered(pixelBuffer:)` goes through the picture path alone for
    /// that reason, and this is what says so.
    @Test func aPreRollDrainIsNotPaddedOverItsOwnAudio() async throws {
        let root = Self.scratch("BackstopPreRollDrain")
        defer { try? FileManager.default.removeItem(at: root) }
        let url: URL = root.appendingPathComponent("drained.mov")

        let writer = try Self.makeWriter(at: url, channels: 2)
        let frame: CVPixelBuffer = TestMedia.pixelBuffer()
        // 100 frames is 4 s — the settings pane's deepest pre-roll, and four
        // times the lead, so a drain that padded would pad the lot.
        let window: Int = 100
        let deadline = Date().addingTimeInterval(3)
        for index: Int in 0..<window {
            writer.appendBuffered(
                pixelBuffer: frame,
                pts: CMTime(value: CMTimeValue(index * 1000), timescale: 25_000),
                deadline: deadline)
        }
        var cache: CMAudioFormatDescription?
        for index: Int in 0..<window {
            let packet: CMSampleBuffer = try #require(
                TestMedia.audioBuffer(seconds: Double(index) * 0.04,
                                      channels: 2, cache: &cache),
                "the fixture could not build a packet")
            writer.appendBuffered(audioSampleBuffer: packet, deadline: deadline)
        }
        let padded: Int = writer.paddedAudioPackets
        let dropped: Int = writer.droppedAudioPackets
        let finished: URL = try await writer.finish()

        #expect(padded == 0,
                "the drain padded \(padded) packets over its own audio")
        #expect(dropped == 0,
                "\(dropped) of the pre-roll's packets were refused")
        let audio = try await TestAudio.span(of: finished)
        #expect(abs(audio.seconds - Double(window) * 0.04) < 0.001,
                "the drained head holds \(audio.seconds) s of sound")
    }

    // MARK: - what it does when the track really is starved

    /// The declared-but-unfed track, measured on the writer rather than through
    /// a crash: silence appears, it stays BEHIND the picture, and it stops at
    /// the width the track was opened with.
    ///
    /// The lag is the mechanism and not a rounding error — a track padded up to
    /// the current frame would release the fragment the frame is still inside
    /// and there would be nothing left to recover. It is bounded on both sides:
    /// never past the picture, never more than the lead behind it.
    @Test func aStarvedTrackIsPaddedBehindThePictureAndNeverPastIt() async throws {
        let root = Self.scratch("BackstopStarvedTrack")
        defer { try? FileManager.default.removeItem(at: root) }
        let url: URL = root.appendingPathComponent("starved.mov")

        let writer = try Self.makeWriter(at: url, channels: 2)
        let frame: CVPixelBuffer = TestMedia.pixelBuffer()
        let frames: Int = 125 // 5 s at 25 fps — one whole fragment interval
        for index: Int in 0..<frames {
            try await Self.push(writer, frame: frame, index: index)
        }
        let padded: Int = writer.paddedAudioPackets
        let writtenTo: Double = writer.audioWrittenUntil.seconds
        let lastPicture: Double = writer.lastPTS.seconds
        let finished: URL = try await writer.finish()

        #expect(padded > 0, "a track nothing fed was left empty")
        let lag: Double = lastPicture - writtenTo
        #expect(writtenTo <= lastPicture + 0.001,
                "audio reached \(writtenTo) s over \(lastPicture) s of picture")
        #expect(lag <= TakeWriter.audioStarvationLead.seconds + 0.041,
                "the audio track is \(lag) s behind the picture")

        let audio = try await TestAudio.span(of: finished)
        #expect(abs(audio.seconds - Double(padded) * 0.04) < 0.001,
                "\(audio.seconds) s of silence on disk for \(padded) packets")
        let channels: Int = try await TestAudio.channelCount(of: finished)
        #expect(channels == 2,
                "the padded track came out \(channels) channels wide")
    }

    /// …and the source that comes back INSIDE a span already padded. Its packets
    /// carry timestamps the file has already covered with silence, so writing
    /// one lays a second sample over a span the file already describes.
    ///
    /// The refusal is measured rather than inherited: with the guard removed
    /// this writer did NOT go to `.failed` the way a backwards VIDEO PTS makes
    /// it, and the take still finished — so what the guard buys is the overlap
    /// not happening and the packet being COUNTED, which is the whole difference
    /// between a take that lost 40 ms of sound and one that lost it quietly.
    /// `hasFailed` is asserted anyway, because the day AVFoundation does start
    /// refusing this is the day the take is lost for good, and this is where
    /// that would show up.
    @Test func aPacketInsideAPaddedSpanIsRefusedRatherThanKillingTheTake()
        async throws {
        let root = Self.scratch("BackstopOverlap")
        defer { try? FileManager.default.removeItem(at: root) }
        let url: URL = root.appendingPathComponent("overlap.mov")

        let writer = try Self.makeWriter(at: url, channels: 2)
        let frame: CVPixelBuffer = TestMedia.pixelBuffer()
        for index: Int in 0..<75 { // 3 s with nothing feeding the track
            try await Self.push(writer, frame: frame, index: index)
        }
        #expect(writer.paddedAudioPackets > 0, "nothing was padded to overlap")

        var cache: CMAudioFormatDescription?
        let stale: CMSampleBuffer = try #require(
            TestMedia.audioBuffer(seconds: 0.4, channels: 2, cache: &cache),
            "the fixture could not build the stale packet")
        let before: Int = writer.droppedAudioPackets
        writer.append(audioSampleBuffer: stale)

        #expect(writer.droppedAudioPackets == before + 1,
                "the overlapping packet was not counted")
        #expect(!writer.hasFailed,
                "the overlapping packet killed the writer: \(writer.failureReason)")
        // …and the take still finishes, which is the whole point of refusing it.
        let finished: URL = try await writer.finish()
        let duration: Double = (try await AVURLAsset(url: finished)
            .load(.duration)).seconds
        #expect(duration > 2.5, "the take came back as \(duration) s")
    }

    /// One video frame may not turn into unbounded work on the capture queue.
    ///
    /// The loop fills from the audio cursor to the frame's PTS in 40 ms steps,
    /// and the frame's PTS is whatever the board says — the first hard-won fact
    /// about this hardware is that stream time can jump. Ten minutes of jump is
    /// fifteen thousand allocations and appends inside ONE `append(pixelBuffer:)`
    /// call, on the one queue that may not be handed unbounded work.
    ///
    /// Pinned as equality rather than a ceiling, exactly like the pipeline's own
    /// cap: `<=` would also pass if the padding stopped happening at all.
    @Test func aJumpInStreamTimeCostsOneBoundedBurst() async throws {
        let root = Self.scratch("BackstopStreamJump")
        defer { try? FileManager.default.removeItem(at: root) }
        let url: URL = root.appendingPathComponent("jump.mov")

        let writer = try Self.makeWriter(at: url, channels: 2)
        let frame: CVPixelBuffer = TestMedia.pixelBuffer()
        try await Self.push(writer, frame: frame, index: 0)
        // ten minutes on, says the board
        var attempts: Int = 0
        let jumped = CMTime(value: 600_000, timescale: 1000)
        while !writer.append(pixelBuffer: frame, pts: jumped), attempts < 400 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(writer.paddedAudioPackets
                    == TakeWriter.maximumAudioPadPacketsPerFrame,
                "one frame padded \(writer.paddedAudioPackets) packets")
        // …and the cursor was moved to the frame rather than left behind, so the
        // next five hundred frames do not each carry another burst of the same
        // gap. A silence packet AT the picture releases every boundary behind it
        // at once; grinding forward through the gap leaves them all shut.
        #expect(abs(writer.audioWrittenUntil.seconds - 600) < 0.001,
                "the cursor was left at \(writer.audioWrittenUntil.seconds) s")
        writer.cancel()
    }
}
