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
        settings.codec = .proResProxy
        settings.destinationPath = root.path
        settings.startDebounceFrames = 3
        settings.stopDebounceFrames = 5
        settings.detectionMode = .timecodeRun
        settings.preRollSeconds = 0.8 // 20 frames at 25 fps

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
}
