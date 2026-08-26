import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// Pre-roll used to buffer picture only: the take opened with frames from
/// before the REC press and an audio track that started where the operator
/// pressed it. Sound arrived seconds late — or, for a short take, not at all.
struct PreRollAudioTests {
    @Test func takeCarriesAudioFromBeforeTheRecPoint() async throws {
        let root = TestMedia.scratchDirectory("PreRollAudio")
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = CaptureSettings()
        settings.capture.codec = .proResProxy
        settings.capture.destinationPath = root.path
        settings.capture.startDebounceFrames = 3
        settings.capture.stopDebounceFrames = 5
        settings.capture.detectionMode = .timecodeRun
        settings.capture.preRollSeconds = 0.8 // 20 frames at 25 fps

        let pipeline = CapturePipeline(config: .init(
            settings: settings, slate: SlateMetadata(scene: "1"), takeNumber: 1))
        let finished = TakeCollector()
        let recStates = EventCollector<Bool>()
        pipeline.onTakeFinished = { finished.append($0) }
        pipeline.onRecStateChanged = { recStates.append($0) }
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180, frameRate: 25,
                                            timecodeFPS: 25, name: "test"))

        // standby long enough to fill the pre-roll window, then record, then stop
        let frame = TestMedia.pixelBuffer()
        let driver = SignalDriver(pipeline: pipeline, withAudio: true)
        let standby = Timecode(hours: 9, minutes: 0, seconds: 0, frames: 0, fps: 25)
        try await driver.pushStalled(standby, count: 30, pixelBuffer: frame)
        let rolled = try await driver.pushRunning(from: standby, count: 50,
                                                  pixelBuffer: frame)
        try await driver.pushStalled(rolled, count: 10, pixelBuffer: frame)

        // stop seen → await the finalize itself → poll for the publication,
        // which is one main-queue hop behind it (see CapturePipelineTests)
        await TestWait.untilWritten { recStates.last == false }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { !finished.isEmpty }
        let take = try #require(finished.first)
        await TestWait.fileExists(at: take.url)

        let asset = AVURLAsset(url: take.url)
        let audioTracks = try await asset.tracks(ofType: .audio)
        #expect(audioTracks.count == 1, "the take must have an audio track")
        let videoDuration = try await asset.load(.duration).seconds
        let audio = try await TestAudio.span(of: take.url)

        let start = try #require(audio.first, "no audio samples in the take at all")
        // the fix: sound is present from the take's first frame, ~0.8 s before
        // the REC point, not only from the press onwards
        #expect(start < 0.12,
                "first audio sample at \(start) s — the pre-roll has no sound")
        #expect(audio.seconds > videoDuration - 0.25,
                "only \(audio.seconds) s of audio for \(videoDuration) s of picture")
    }

    /// The ring's memory budget is a CEILING, and the case that made it one is
    /// 12-bit UHD arriving without anybody choosing it.
    ///
    /// The rule used to be `max(startConfirmSpan + 5, budgetFrames)`: the
    /// detection latency was guaranteed room whatever a frame cost, because
    /// a ring shorter than that loses the head of every take. That was
    /// affordable while the deepest capture needed a deliberate click. Bit depth
    /// follows the signal now, so the arithmetic below is reachable by a camera
    /// changing its output between setups, and it does not hold — with the
    /// taught REC indicator armed the confirm count is multiplied by the
    /// watcher's stride, so a start debounce of 12 asks for 65 frames of a
    /// 66 MB record buffer: 4.3 GB, against a 1.5 GB budget.
    ///
    /// Checked as arithmetic rather than through a pipeline because no synthetic
    /// signal in this suite is a UHD 12-bit one, and a wrong answer here is
    /// measured in gigabytes rather than in a failed assertion.
    @Test func theRingStaysInsideItsBudgetAtTwelveBitUHD() {
        // 3840x2160, 8 bytes a pixel — the 12-bit path's '64RGBALE' record frame
        let bytesPerFrame: Int = 3840 * 2160 * 8
        #expect(bytesPerFrame == 66_355_200, "the UHD frame size moved")
        // wanted = preRoll 5 + confirm span 60 (debounce 12 x stride 5) + 3
        let capacity: Int = CapturePipeline.preRollCapacity(
            wanted: 68, bytesPerFrame: bytesPerFrame)
        #expect(capacity * bytesPerFrame <= CapturePipeline.preRollBudgetBytes,
                "\(capacity) frames is \(capacity * bytesPerFrame) bytes")
        #expect(capacity == 22, "the UHD 12-bit ring holds \(capacity) frames")

        // …and the same rig at 10-bit, which the old floor also blew through
        let tenBit: Int = 3840 * 2160 * 4
        let tenCapacity: Int = CapturePipeline.preRollCapacity(
            wanted: 68, bytesPerFrame: tenBit)
        #expect(tenCapacity * tenBit <= CapturePipeline.preRollBudgetBytes)
    }

    // MARK: - what the setting means, in frames

    /// A LEGACY `preRollSeconds` off an old settings blob is converted at the
    /// SIGNAL's rate, not at a hard-coded 25.
    ///
    /// The conversion used to be `Int((preRollSeconds * 25).rounded())`, which
    /// is the right answer on exactly one signal. On a 23.976 source a legacy
    /// one-second pre-roll came back as 25 frames where it is 24, and on a 50
    /// as 25 where it is 50 — half the head of every take of the day, silently,
    /// with nothing on screen saying a different number was meant.
    @Test func aLegacySecondsPreRollConvertsAtTheSignalsRate() {
        var capture = CaptureSignalSettings()
        capture.preRollSeconds = 1
        for (rate, frames): (Double, Int) in [(23.976, 24), (25, 25), (50, 50)] {
            let got: Int = capture.preRollFramesEffective(atFrameRate: rate)
            #expect(got == frames,
                    "one second at \(rate) fps is \(frames) frames, not \(got)")
        }
        // …and with no signal up — which is exactly when a settings sheet is
        // likely to be open — it reads as the retired field always meant it
        #expect(capture.preRollFramesEffective(atFrameRate: nil) == 25,
                "with nothing connected the legacy value keeps its old reading")
    }

    /// The other half of the same contract: once a frame count is STORED, the
    /// rate cannot move it. A camera changed from 25 to 50 between setups must
    /// not double the operator's pre-roll behind their back — frames is the
    /// stored unit precisely because it stays true across a format change.
    @Test func anEnteredFrameCountDoesNotMoveWithTheSignalsRate() {
        var capture = CaptureSignalSettings()
        capture.preRollFrames = 12
        for rate: Double? in [23.976, 25, 50, 59.94, nil] {
            #expect(capture.preRollFramesEffective(atFrameRate: rate) == 12,
                    "a stored frame count moved at \(rate ?? -1) fps")
        }
    }

    /// A pre-roll typed in SECONDS meets the ring's memory ceiling through the
    /// same code path a frame count does, because it becomes one before
    /// anything downstream sees it.
    ///
    /// The unit switch is the obvious way to get around a bound that is stated
    /// in frames: 60 s at 50 fps is 3000 frames, and at 12-bit UHD that is
    /// ~199 GB of pre-roll ring — two orders of magnitude over a budget that
    /// CLAUDE.md calls a hard ceiling. It cannot be reached, and not by a check
    /// of its own: the conversion clamps to the same `preRollFrameRange` the
    /// frames field is bounded by, and `preRollCapacity` then applies the memory
    /// ceiling to the frame count that comes out.
    @Test func aPreRollTypedInSecondsMeetsTheSameCeilingAsOneTypedInFrames() {
        let bytesPerFrame: Int = 3840 * 2160 * 8
        let unclamped: Int = 3000 // 60 s x 50 fps, if nothing bounded it
        #expect(unclamped * bytesPerFrame > 100 * CapturePipeline.preRollBudgetBytes,
                "60 s at 50 fps unbounded is \(unclamped * bytesPerFrame) bytes")

        let fromSeconds: Int = CaptureSignalSettings.preRollFrames(
            seconds: 60, atFrameRate: 50)
        #expect(fromSeconds == CaptureSignalSettings.preRollFrameRange.upperBound,
                "a seconds entry asked for \(fromSeconds) frames")
        // the same number a frames entry of 60 x 50 would have been held to
        var typed = CaptureSignalSettings()
        typed.preRollFrames = unclamped
        #expect(typed.preRollFramesEffective(atFrameRate: 50) == fromSeconds,
                "the two units disagree about the maximum")

        // …and the memory ceiling then applies to it, unchanged
        let capacity: Int = CapturePipeline.preRollCapacity(
            wanted: fromSeconds + 3, bytesPerFrame: bytesPerFrame)
        #expect(capacity * bytesPerFrame <= CapturePipeline.preRollBudgetBytes,
                "\(capacity) frames is \(capacity * bytesPerFrame) bytes")
        #expect(capacity == 22, "the UHD 12-bit ring holds \(capacity) frames")
    }

    /// Nothing changes for the rasters the budget was never tight on: at 1080p
    /// the ring holds everything that was asked for, at every depth.
    @Test func theBudgetDoesNotShortenAnHDRing() {
        for bytesPerPixel: Int in [3, 4, 8] {
            let bytesPerFrame: Int = 1920 * 1080 * bytesPerPixel
            #expect(CapturePipeline.preRollCapacity(
                wanted: 68, bytesPerFrame: bytesPerFrame) == 68,
                "1080p at \(bytesPerPixel) bytes a pixel was shortened")
        }
        // and a frame so large that the budget holds none of it still keeps a
        // ring rather than dividing to zero
        #expect(CapturePipeline.preRollCapacity(
            wanted: 68, bytesPerFrame: 2_000_000_000)
            == CapturePipeline.minimumPreRollFrames)
    }
}
