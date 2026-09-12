import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

/// **How late a source's sound arrives, as a number the operator sets** (owner:
/// "по звуку – хочу еще добавить настройку задержки звука. мне кажется с
/// разными источниками может быть полезно").
///
/// Embedded audio comes off the board with the frame it belongs to; a USB
/// interface adds its own buffer, and a cart feeding through a long chain adds
/// more. So there are two numbers, one per source, and the one in force
/// follows whichever source is selected — an operator who switches mid-shift
/// does not have to remember to retype anything.
///
/// The shift lands at the single door both sources come through, so the take,
/// the monitoring and the stereo fold the network legs carry all move
/// together. The TIMECODE does not move with them, and that is the decision
/// worth a test of its own: LTC is not sound.
struct AudioDelayTests {
    private func settings(embedded: Double? = nil,
                          external: Double? = nil,
                          device: String? = nil) -> CaptureSettings {
        var value = CaptureSettings()
        value.audio.embeddedDelayMS = embedded
        value.audio.externalDelayMS = external
        value.audio.audioInputDeviceUID = device
        return value
    }

    // MARK: - the value

    /// Each source keeps its own number, and a hand-edited blob cannot push a
    /// take's sound out of its own file.
    @Test func eachSourceKeepsItsOwnDelayAndBothAreClamped() {
        let audio = settings(embedded: -12.5, external: 38).audio
        #expect(audio.delayMS(for: false) == -12.5)
        #expect(audio.delayMS(for: true) == 38)

        // nothing set is nothing applied, on both
        #expect(CaptureSettings().audio.delayMS(for: false) == 0)
        #expect(CaptureSettings().audio.delayMS(for: true) == 0)

        // …and a number nobody could have typed here is brought back inside
        let wild = settings(embedded: 9_000, external: -9_000).audio
        #expect(wild.delayMS(for: false) == AudioSettings.delayRangeMS.upperBound)
        #expect(wild.delayMS(for: true) == AudioSettings.delayRangeMS.lowerBound)
        let broken = settings(embedded: .nan, external: .infinity).audio
        // A non-finite number is not a delay somebody meant — it is garbage in
        // the blob — so it reads as nothing applied rather than as "as far as
        // the range goes", which is what clamping it would say.
        #expect(broken.delayMS(for: false) == 0, "a NaN reached the capture path")
        #expect(broken.delayMS(for: true) == 0,
                "an infinity reached the capture path")
    }

    // MARK: - the shift

    /// The packet is stamped back to when its sound happened, by exactly the
    /// number that was set — and by the number for the source it came from.
    @Test func thePacketMovesByExactlyTheDelayForItsOwnSource() throws {
        let pipeline = CapturePipeline(config: .init(
            settings: settings(embedded: 40, external: -25, device: nil),
            takeNumber: 1))
        var cache: CMAudioFormatDescription?
        let packet = try #require(Self.silence(atSeconds: 2, cache: &cache))
        let pts = CMSampleBufferGetPresentationTimeStamp(packet)

        let embedded = try #require(pipeline.delayed(packet, from: .embedded))
        let moved = CMSampleBufferGetPresentationTimeStamp(embedded)
        #expect(abs(CMTimeGetSeconds(CMTimeSubtract(moved, pts)) - 0.040)
            < 0.000_1, "the embedded packet moved by the wrong amount")

        let external = try #require(pipeline.delayed(packet, from: .external))
        let back = CMSampleBufferGetPresentationTimeStamp(external)
        #expect(abs(CMTimeGetSeconds(CMTimeSubtract(back, pts)) + 0.025)
            < 0.000_1, "the external packet took the embedded source's number")

        // …and the samples themselves are untouched: this is a timing change
        #expect(CMSampleBufferGetNumSamples(embedded)
            == CMSampleBufferGetNumSamples(packet))
        #expect(CMSampleBufferGetDuration(embedded)
            == CMSampleBufferGetDuration(packet))
    }

    /// **Nothing set costs nothing.** nil rather than a re-stamped copy, so an
    /// operator who never touches this pays one `Double` comparison per packet
    /// and no allocation at all.
    @Test func noDelayCostsNoCopy() throws {
        let pipeline = CapturePipeline(config: .init(settings: CaptureSettings(),
                                                     takeNumber: 1))
        var cache: CMAudioFormatDescription?
        let packet = try #require(Self.silence(atSeconds: 1, cache: &cache))
        #expect(pipeline.delayed(packet, from: .embedded) == nil)
        #expect(pipeline.delayed(packet, from: .external) == nil)
    }

    // MARK: - and the clock does not move with it

    /// **LTC is not sound.** The operator's number is about where the sound
    /// sits against the picture; the timecode a take opens on is what conforms
    /// it against the camera original, and a dial set by ear against lips must
    /// not take it along. Driven end to end, because the guard is an argument
    /// at one call site and nothing else would see it.
    @Test func aDelayDoesNotMoveTheTakesTimecode() async throws {
        let root = TestMedia.scratchDirectory("AudioDelayLTC")
        defer { try? FileManager.default.removeItem(at: root) }
        var value = settings(embedded: 400)
        value.capture.codec = .proResProxy
        value.capture.destinationPath = root.path
        value.capture.startDebounceFrames = 3
        value.capture.stopDebounceFrames = 5
        value.capture.detectionMode = .timecodeRun
        value.capture.preRollSeconds = 0
        value.capture.timecodeSource = "ltc"
        value.capture.ltcChannel = 1

        let pipeline = CapturePipeline(config: .init(
            settings: value, slate: SlateMetadata(scene: "9"), takeNumber: 1))
        let takes = TakeCollector()
        let recStates = EventCollector<Bool>()
        pipeline.onTakeFinished = { takes.append($0) }
        pipeline.onRecStateChanged = { recStates.append($0) }
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180,
                                            frameRate: 25, timecodeFPS: 25,
                                            name: "test"))

        let standby = Timecode(hours: 15, minutes: 30, seconds: 0, frames: 0,
                               fps: 25)
        let driver = LTCDelayDriver(pipeline: pipeline)
        for _ in 0..<10 { try await driver.push(standby) }
        var rolling = standby
        for _ in 0..<40 {
            rolling = rolling.advanced(by: 1)
            try await driver.push(rolling)
        }
        for _ in 0..<10 { try await driver.push(rolling) }

        await TestWait.untilWritten { recStates.last == false }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { !takes.isEmpty }

        let take = try #require(takes.first, "no take was finished")
        let start = try #require(take.startTimecode,
                                 "the take carries no timecode at all")
        // Ten frames of standby then the roll: the take opens within a couple
        // of frames of where the LTC said, which is where it opens with no
        // delay set at all. 400 ms is TEN frames at 25 — an LTC moved with the
        // sound would land a long way outside this.
        let wanted = standby.advanced(by: 1).frameNumber
        #expect(abs(start.frameNumber - wanted) <= 3, """
            the take opened at \\(start.description) — the delay moved the \\
            camera's timecode with the sound
            """)
    }

    /// **The offset reaches the recorded sound**, which is the claim the whole
    /// feature makes and the one an isolated shift cannot hold.
    ///
    /// Measured as how much sound the take HOLDS. A take's audio track starts
    /// and ends where its picture does — the writer normalises to the session
    /// and pads a gap with silence — so the track's own range says nothing.
    /// What moves is the content: sound pushed past the take's start has no
    /// session to land in, so a take made under a 200 ms offset carries 200 ms
    /// less of it. 48 000 frames of stereo 16-bit is 192 000 bytes a second,
    /// so the difference is a number this test can state exactly.
    @Test func theOffsetReachesTheRecordedSound() async throws {
        let plain = try await Self.recordedAudioBytes(delay: nil)
        let moved = try await Self.recordedAudioBytes(delay: 200)
        #expect(plain > 0, "the take carried no sound at all")

        // 200 ms of 48 kHz stereo 16-bit
        let expected = Int(0.2 * 48_000) * 2 * 2
        let difference = plain - moved
        #expect(abs(difference - expected) <= 4 * 2 * 2, """
            the take under a 200 ms offset holds \(difference) bytes less \
            sound, and 200 ms is \(expected)
            """)
    }

    // MARK: - fixtures

    /// Record a short manual take under `delay` and answer with how many
    /// bytes of sound reached the file.
    static func recordedAudioBytes(delay: Double?) async throws -> Int {
        let root = TestMedia.scratchDirectory("AudioDelayTake")
        defer { try? FileManager.default.removeItem(at: root) }
        var value = CaptureSettings()
        value.audio.embeddedDelayMS = delay
        value.capture.codec = .proResProxy
        value.capture.destinationPath = root.path
        value.capture.detectionMode = .manual
        value.capture.preRollFrames = 0
        let pipeline = CapturePipeline(config: .init(settings: value,
                                                     takeNumber: 1))
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180,
                                            frameRate: 25, timecodeFPS: 25,
                                            name: "test"))
        let takes = TakeCollector()
        pipeline.onTakeFinished = { takes.append($0) }
        let driver = SignalDriver(pipeline: pipeline, withAudio: true,
                                  audioChannels: 2, audioSignature: true)
        var timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0,
                                fps: 25)
        let frame = TestMedia.pixelBuffer()
        for _ in 0..<3 {
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: frame)
        }
        pipeline.toggleManualRecord()
        for _ in 0..<25 {
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: frame)
        }
        pipeline.toggleManualRecord()
        await TestWait.untilWritten { takes.first != nil }
        await pipeline.finishPendingWrites()
        let take = try #require(takes.first, "no take was finished")
        await TestWait.fileExists(at: take.url)
        return try await TestAudio.rawSamples(of: take.url).count
    }

    /// One 40 ms packet of silence at `seconds`.
    static func silence(atSeconds seconds: Double,
                        cache: inout CMAudioFormatDescription?)
        -> CMSampleBuffer? {
        let frames = 1920
        let samples = [Int16](repeating: 0, count: frames * 2)
        return samples.withUnsafeBytes { raw in
            PCMAudio.makeSampleBuffer(bytes: raw.baseAddress!,
                                      sampleFrames: frames, channelCount: 2,
                                      ptsSeconds: seconds, formatCache: &cache)
        }
    }
}

/// `PipelineLTCTests`' driver, which is private to that suite: an LTC frame as
/// two-channel audio (timecode on channel 1) and then a picture frame with no
/// timecode on the wire at all.
private final class LTCDelayDriver {
    let pipeline: CapturePipeline
    private let pixelBuffer = TestMedia.pixelBuffer()
    private var polarity = false
    private var cache: CMAudioFormatDescription?
    private var frame = 0

    init(pipeline: CapturePipeline) { self.pipeline = pipeline }

    func push(_ timecode: Timecode) async throws {
        frame += 1
        if let audio = ltcAudio(timecode) { pipeline.handleAudio(audio) }
        pipeline.handleFrame(
            pixelBuffer: pixelBuffer,
            pts: CMTime(value: CMTimeValue(frame * 40), timescale: 1000),
            timecode: nil, vancTrigger: nil)
        try await Task.sleep(for: .milliseconds(40))
    }

    private func ltcAudio(_ timecode: Timecode) -> CMSampleBuffer? {
        let mono = LTCTestSignal.encode(timecode, fps: 25, polarity: &polarity)
        var interleaved = [Int16](repeating: 0, count: mono.count * 2)
        for (index, sample) in mono.enumerated() {
            interleaved[index * 2 + 1] = sample
        }
        return interleaved.withUnsafeBytes { raw in
            PCMAudio.makeSampleBuffer(bytes: raw.baseAddress!,
                                      sampleFrames: mono.count,
                                      channelCount: 2,
                                      ptsSeconds: Double(frame) * 0.04,
                                      formatCache: &cache)
        }
    }
}
