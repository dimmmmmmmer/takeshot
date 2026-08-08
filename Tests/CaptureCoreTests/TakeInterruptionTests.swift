import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import CaptureCore

/// What happens to an OPEN take when the shooting day goes wrong: the cable
/// comes out, the camera changes format mid-shot, or the finalize fails.
///
/// Each of these is one of the recording-integrity rules, and every one of them
/// was unexercised — they are the paths nobody reaches by hand, which is exactly
/// why a bug in one costs a take that cannot be re-shot. The assertions are the
/// promises those rules make: the file is closed rather than left starving, the
/// operator is told in the sticky register rather than a toast that scrolls
/// past, and a take that could not be finalized never passes for good footage.
@Suite struct TakeInterruptionTests {
    private static let format = CaptureFormat(
        width: 320, height: 180, frameRate: 25, timecodeFPS: 25, name: "test 25")
    private static let standby = Timecode(hours: 10, minutes: 0, seconds: 0,
                                          frames: 0, fps: 25)

    private static func settings(root: URL) -> CaptureSettings {
        var settings = CaptureSettings()
        settings.codec = .proResProxy // the tests encode in real time
        settings.destinationPath = root.path
        settings.namingTemplate = "{scene}_T{take}_{tc}"
        settings.projectName = "Test"
        // The test owns the trigger: these are assertions about what an
        // INTERRUPTION does to a take, not about what starts one.
        settings.detectionMode = .manual
        settings.preRollSeconds = 0
        return settings
    }

    /// Everything the pipeline reports, collected behind locks — the callbacks
    /// land on the main queue while the test polls from a worker thread.
    private struct Ears {
        let errors = EventCollector<PipelineAlarm>()
        let recStates = EventCollector<Bool>()
        let takes = TakeCollector()
        let signals = EventCollector<Bool>()
        let formats = EventCollector<CaptureFormat?>()

        func listen(to pipeline: CapturePipeline) {
            pipeline.onError = { errors.append($0) }
            pipeline.onRecStateChanged = { recStates.append($0) }
            pipeline.onTakeFinished = { takes.append($0) }
            pipeline.onSignal = { signals.append($0) }
            pipeline.onFormatChanged = { formats.append($0) }
        }

        /// Read through `message`, the English prose CaptureCore states for
        /// itself: what the operator sees is the app's translation of the same
        /// alarm, and this module is where the English is pinned.
        func said(_ fragment: String) -> Bool {
            errors.all.contains { $0.message.contains(fragment) }
        }

        /// …and the register the alarm declares, which is the half a
        /// substring match could never have checked.
        func severity(of fragment: String) -> PipelineAlarm.Severity? {
            errors.all.first { $0.message.contains(fragment) }?.severity
        }
    }

    /// Open a take by hand and get some picture into it, so the writer has real
    /// samples to finalize when the interruption arrives.
    private func rollingTake(pipeline: CapturePipeline,
                             driver: SignalDriver,
                             frames: Int = 12) async throws {
        pipeline.toggleManualRecord()
        #expect(await TestWait.becomesTrue { pipeline.health.isRecording },
                "the take never opened")
        _ = try await driver.pushRunning(from: Self.standby, count: frames,
                                         pixelBuffer: TestMedia.pixelBuffer())
    }

    // MARK: - the cable comes out

    /// No frames means no VANC, so the camera's stop and its next start are both
    /// invisible: left open, the writer swallows the next take into the same
    /// file. The take is closed on the spot and the operator is told.
    @Test func aSignalDropoutClosesTheOpenTakeAndSaysSo() async throws {
        let root = TestMedia.scratchDirectory("SignalDropout")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = CapturePipeline(config: .init(
            settings: Self.settings(root: root),
            slate: SlateMetadata(scene: "3"), takeNumber: 1))
        let ears = Ears()
        ears.listen(to: pipeline)
        pipeline.handleFormat(Self.format)

        let driver = SignalDriver(pipeline: pipeline)
        try await rollingTake(pipeline: pipeline, driver: driver)

        pipeline.handleSignal(present: false)

        await TestWait.untilWritten { ears.recStates.last == false }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { !ears.takes.isEmpty }

        let take = try #require(ears.takes.first,
                                "the interrupted take was never published")
        #expect(!pipeline.health.isRecording)
        #expect(pipeline.health.takesClosed == 1)
        // closed, not lost: the frames that were already recorded are on disk
        #expect(pipeline.health.takesFailedToFinalize == 0)
        #expect(ears.said("Take closed: input signal lost mid-take"))
        #expect(ears.severity(of: "input signal lost") == .integrity,
                "a closed take was reported as a passing notice")
        #expect(ears.signals.last == false)

        await TestWait.fileExists(at: take.url)
        #expect(FileManager.default.fileExists(atPath: take.url.path),
                "an interrupted take must still leave its file: \(take.url.path)")
        let duration = try await AVURLAsset(url: take.url).load(.duration)
        #expect(duration.seconds > 0, "the closed take has no picture in it")
    }

    /// The other half of the same rule: what comes back after a dropout is a new
    /// take, in a file of its own, rather than the tail of the old one.
    @Test func theTakeAfterADropoutIsAFileOfItsOwn() async throws {
        let root = TestMedia.scratchDirectory("DropoutSecondTake")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = CapturePipeline(config: .init(
            settings: Self.settings(root: root),
            slate: SlateMetadata(scene: "3"), takeNumber: 1))
        let ears = Ears()
        ears.listen(to: pipeline)
        pipeline.handleFormat(Self.format)

        let driver = SignalDriver(pipeline: pipeline)
        try await rollingTake(pipeline: pipeline, driver: driver)
        pipeline.handleSignal(present: false)
        await TestWait.untilWritten { ears.recStates.last == false }

        // the cable goes back in and the operator rolls again
        pipeline.handleSignal(present: true)
        try await rollingTake(pipeline: pipeline, driver: driver)
        pipeline.toggleManualRecord()

        await TestWait.untilWritten { pipeline.health.takesClosed == 2 }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { ears.takes.all.count == 2 }

        let urls = Set(ears.takes.all.map(\.url))
        #expect(urls.count == 2,
                "the second take was written into the first take's file")
        #expect(pipeline.health.takesFailedToFinalize == 0)
    }

    // MARK: - the camera changes format mid-shot

    /// A real format change restarts the streams and resets the PTS timeline, so
    /// an open take would starve while REC stayed red. Close it and say so.
    @Test func aFormatChangeMidTakeClosesTheTakeAndSaysSo() async throws {
        let root = TestMedia.scratchDirectory("FormatChangeMidTake")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = CapturePipeline(config: .init(
            settings: Self.settings(root: root),
            slate: SlateMetadata(scene: "9"), takeNumber: 1))
        let ears = Ears()
        ears.listen(to: pipeline)
        pipeline.handleFormat(Self.format)

        let driver = SignalDriver(pipeline: pipeline)
        try await rollingTake(pipeline: pipeline, driver: driver)

        let switched = CaptureFormat(width: 256, height: 144, frameRate: 25,
                                     timecodeFPS: 25, name: "test 25 small")
        pipeline.handleFormat(switched)

        await TestWait.untilWritten { ears.recStates.last == false }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { !ears.takes.isEmpty }

        let take = try #require(ears.takes.first)
        #expect(!pipeline.health.isRecording)
        #expect(pipeline.health.takesClosed == 1)
        #expect(ears.said("Take closed: input format changed mid-take"))
        #expect(ears.severity(of: "input format changed") == .integrity,
                "a closed take was reported as a passing notice")
        // and the new format still reaches the UI — the close must not swallow it
        #expect(ears.formats.last == switched)

        await TestWait.fileExists(at: take.url)
        #expect(FileManager.default.fileExists(atPath: take.url.path))
    }

    /// The guard in front of all of that: a board re-announcing the format it is
    /// already delivering must not close a take. This is the format-detection
    /// restart loop as it reaches the take — an identical announcement that got
    /// through would end a take every time the board re-armed detection.
    @Test func aReannouncedIdenticalFormatLeavesTheTakeAlone() async throws {
        let root = TestMedia.scratchDirectory("FormatReannounce")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = CapturePipeline(config: .init(
            settings: Self.settings(root: root),
            slate: SlateMetadata(scene: "9"), takeNumber: 1))
        let ears = Ears()
        ears.listen(to: pipeline)
        pipeline.handleFormat(Self.format)

        let driver = SignalDriver(pipeline: pipeline)
        try await rollingTake(pipeline: pipeline, driver: driver)

        pipeline.handleFormat(Self.format) // the same one, again
        _ = try await driver.pushRunning(from: Self.standby, count: 5,
                                         pixelBuffer: TestMedia.pixelBuffer())

        #expect(pipeline.health.isRecording, "the take was closed by a no-op")
        #expect(!ears.said("Take closed:"))
        #expect(ears.takes.isEmpty)

        pipeline.toggleManualRecord() // leave nothing finalizing behind
        await TestWait.untilWritten { ears.recStates.last == false }
        await pipeline.finishPendingWrites()
    }

    // MARK: - the finalize fails

    /// A take that cannot be finalized must not pass for good footage: it never
    /// joins the list, the failure is counted, and the alarm names the file.
    ///
    /// The failure here is the one an operator actually produces — REC pressed
    /// and released inside a frame interval, or a source that dies in the 40 ms
    /// between the format arriving and frame one, so the writer has no samples
    /// and `finish()` refuses. It is the same catch branch a dead volume takes.
    @Test func aTakeThatCannotBeFinalizedNeverJoinsTheList() async throws {
        let root = TestMedia.scratchDirectory("FailedFinalize")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = CapturePipeline(config: .init(
            settings: Self.settings(root: root),
            slate: SlateMetadata(scene: "4"), takeNumber: 7))
        let ears = Ears()
        ears.listen(to: pipeline)
        pipeline.handleFormat(Self.format)

        // no frame ever arrives between the two presses
        pipeline.toggleManualRecord()
        #expect(await TestWait.becomesTrue { pipeline.health.isRecording })
        pipeline.toggleManualRecord()

        await TestWait.untilWritten { pipeline.health.takesClosed == 1 }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { pipeline.health.takesFailedToFinalize == 1 }

        #expect(pipeline.health.takesFailedToFinalize == 1,
                "a finalize that failed was not counted")
        #expect(ears.takes.isEmpty,
                "an unfinalized take was published to the list anyway")
        #expect(ears.said("TAKE LOST — failed to finalize"))
        #expect(ears.severity(of: "failed to finalize") == .integrity,
                "a take that never finalized was reported as a notice")
        #expect(!pipeline.health.isRecording)
    }

    /// …and it leaves nothing behind for the folder scan to re-adopt. An empty
    /// take is cancelled rather than renamed, because there is no footage in it
    /// to recover — the `_FAILED.mov` rule is about a half-written file.
    @Test func anEmptyTakeLeavesNoFileForTheScanToFind() async throws {
        let root = TestMedia.scratchDirectory("EmptyTakeNoFile")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = CapturePipeline(config: .init(
            settings: Self.settings(root: root),
            slate: SlateMetadata(scene: "4"), takeNumber: 7))
        pipeline.handleFormat(Self.format)
        pipeline.toggleManualRecord()
        #expect(await TestWait.becomesTrue { pipeline.health.isRecording })
        pipeline.toggleManualRecord()

        await TestWait.untilWritten { pipeline.health.takesClosed == 1 }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { pipeline.health.takesFailedToFinalize == 1 }

        let left = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".mov") }
        #expect(left.isEmpty, "an empty take left \(left) behind")
    }

    /// A take that opens before the audio format is known has no audio track at
    /// all, and every packet of it is discarded without a counter. Silent
    /// scratch audio is only discovered in the edit, so it is a sticky alarm.
    @Test func aTakeWithNoAudioTrackSaysSoWhileItIsStillRolling() async throws {
        let root = TestMedia.scratchDirectory("NoAudioTrack")
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = CapturePipeline(config: .init(
            settings: Self.settings(root: root),
            slate: SlateMetadata(scene: "5"), takeNumber: 1))
        let ears = Ears()
        ears.listen(to: pipeline)
        pipeline.handleFormat(Self.format)

        let driver = SignalDriver(pipeline: pipeline) // picture only
        try await rollingTake(pipeline: pipeline, driver: driver, frames: 6)

        #expect(await TestWait.becomesTrue { ears.said("TAKE LOST audio") },
                "a take with no audio track went unannounced")
        #expect(ears.severity(of: "TAKE LOST audio") == .integrity,
                "silent scratch audio was reported as a passing notice")

        pipeline.toggleManualRecord()
        await TestWait.untilWritten { ears.recStates.last == false }
        await pipeline.finishPendingWrites()
    }
}
