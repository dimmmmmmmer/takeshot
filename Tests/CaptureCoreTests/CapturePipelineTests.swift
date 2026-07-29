import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import CaptureCore

/// End-to-end pipeline test without hardware: a synthetic signal with Rec Run
/// timecode goes through the detector, writer, and naming — a finished take appears on disk.
struct CapturePipelineTests {
    @Test func autoTakeFromRunningTimecodeProducesFile() async throws {
        let root = TestMedia.scratchDirectory("PipelineTests")
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = CaptureSettings()
        settings.codec = .proResProxy
        settings.destinationPath = root.path
        settings.namingTemplate = "{scene}_T{take}_{tc}"
        settings.projectName = "Test"
        settings.startDebounceFrames = 3
        settings.stopDebounceFrames = 5
        settings.detectionMode = .timecodeRun
        settings.preRollSeconds = 0 // pre-roll is checked by a separate test

        let pipeline = CapturePipeline(config: .init(
            settings: settings, scene: "7", takeNumber: 2))

        var finishedTakes: [Take] = []
        var recStates: [Bool] = []
        // Deliberately NOT a `confirmation`: its token is only valid inside the
        // body, the pipeline holds onTakeFinished past it, and the take is
        // published from a detached finalize task. On a slow machine that call
        // lands after the body has gone and retains a dead confirmation —
        // which is the SIGBUS that took CI down for a week. The wait below and
        // the #require afterwards assert exactly the same thing.
        pipeline.onTakeFinished = { finishedTakes.append($0) }
        pipeline.onRecStateChanged = { recStates.append($0) }

        pipeline.handleFormat(CaptureFormat(
            width: 320, height: 180, frameRate: 25, timecodeFPS: 25, name: "test"))

        let pixelBuffer = TestMedia.pixelBuffer()
        let driver = SignalDriver(pipeline: pipeline)
        let standby = Timecode(hours: 11, minutes: 0, seconds: 0, frames: 0, fps: 25)

        try await driver.pushStalled(standby, count: 10, pixelBuffer: pixelBuffer)
        // "camera recording": TC runs for 50 frames (2 seconds)
        let rolled = try await driver.pushRunning(from: standby, count: 50,
                                                  pixelBuffer: pixelBuffer)
        try await driver.pushStalled(rolled, count: 10, pixelBuffer: pixelBuffer)

        // the pipeline processes asynchronously — wait for the take-finished event
        await TestWait.until { !finishedTakes.isEmpty }
        // and let every finalize task complete before the defer above removes
        // the folder out from under a writer that is still finishing
        await pipeline.finishPendingWrites()

        let take = try #require(finishedTakes.first)
        #expect(recStates.contains(true) && recStates.last == false)
        #expect(take.scene == "7")
        #expect(take.takeNumber == 2)

        // name by template: scene, take number, and start TC (11:00:00:00 ± pre-roll)
        #expect(take.displayName.hasPrefix("Test_7_T02_11.00.00"))
        // write straight into the chosen folder — no auto subfolders by date/project
        #expect(take.url.deletingLastPathComponent().path == root.path)
        #expect(take.url.path.hasSuffix(".mov"))

        // the file is finished asynchronously after the event — wait for it to appear
        await TestWait.fileExists(at: take.url)
        #expect(FileManager.default.fileExists(atPath: take.url.path),
                "the take file must exist: \(take.url.path)")

        // and it's a valid ~2 s clip with video and timecode tracks
        let asset = AVURLAsset(url: take.url)
        let duration = try await asset.load(.duration)
        // wide tolerance: under load (parallel tests, CI) the encoder may drop
        // some synthetic frames — what matters is the take exists and is ~2 s
        #expect(duration.seconds > 1.2 && duration.seconds < 2.6)
        let videoTracks = try await asset.tracks(ofType: .video)
        #expect(videoTracks.count == 1)
        let tcTracks = try await asset.tracks(ofType: .timecode)
        #expect(tcTracks.count == 1)
    }

    @Test func preRollIncludesFramesBeforeRecStart() async throws {
        let root = TestMedia.scratchDirectory("PipelineTests")
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = CaptureSettings()
        settings.codec = .proResProxy
        settings.destinationPath = root.path
        settings.startDebounceFrames = 3
        settings.stopDebounceFrames = 5
        settings.detectionMode = .timecodeRun
        settings.preRollSeconds = 0.8 // 20 frames at 25 fps

        let pipeline = CapturePipeline(config: .init(
            settings: settings, scene: "1", takeNumber: 1))
        var finishedTakes: [Take] = []
        pipeline.onTakeFinished = { finishedTakes.append($0) }

        pipeline.handleFormat(CaptureFormat(
            width: 320, height: 180, frameRate: 25, timecodeFPS: 25, name: "test"))
        let pixelBuffer = TestMedia.pixelBuffer()
        let driver = SignalDriver(pipeline: pipeline)
        let standby = Timecode(hours: 12, minutes: 0, seconds: 0, frames: 0, fps: 25)

        // long standby — the pre-roll buffer has time to fill
        try await driver.pushStalled(standby, count: 30, pixelBuffer: pixelBuffer)
        // record 50 frames, then stop
        let rolled = try await driver.pushRunning(from: standby, count: 50,
                                                  pixelBuffer: pixelBuffer)
        try await driver.pushStalled(rolled, count: 10, pixelBuffer: pixelBuffer)

        await TestWait.until { !finishedTakes.isEmpty }
        await pipeline.finishPendingWrites()
        let take = try #require(finishedTakes.first)

        await TestWait.fileExists(at: take.url)
        #expect(FileManager.default.fileExists(atPath: take.url.path))

        // 50 recorded frames + ~4 trailing + 20 pre-roll ≈ 74 frames ≈ 2.96 s;
        // without pre-roll it would be ~2.2 s — verify the pre-REC frames are included
        let asset = AVURLAsset(url: take.url)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 2.6 && duration.seconds < 3.4,
                "duration=\(duration.seconds)")
    }

    @Test func trimChannelsKeepsFirstN() throws {
        // 16-channel buffer: channel k is filled with (k+1)*100
        let frames = 48
        let channels = 16
        var samples = [Int16](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                samples[frame * channels + channel] = Int16((channel + 1) * 100)
            }
        }
        var makeCache: CMAudioFormatDescription?
        let source = samples.withUnsafeBytes { raw in
            PCMAudio.makeSampleBuffer(bytes: raw.baseAddress!, sampleFrames: frames,
                                      channelCount: channels, ptsSeconds: 0,
                                      formatCache: &makeCache)
        }
        let sourceBuffer = try #require(source)

        var trimCache: CMAudioFormatDescription?
        let trimmed = try #require(PCMAudio.trimChannels(
            sourceBuffer, to: 2, formatCache: &trimCache))
        let levels = PCMAudio.peakLevels(of: trimmed)
        #expect(levels.count == 2)
        // levels correspond to the source's channels 1 and 2
        let expected1 = 20 * log10(Float(100) / Float(Int16.max))
        let expected2 = 20 * log10(Float(200) / Float(Int16.max))
        #expect(abs(levels[0] - expected1) < 0.01)
        #expect(abs(levels[1] - expected2) < 0.01)

        // if there are already fewer channels than the limit — the buffer is returned as-is
        let untouched = PCMAudio.trimChannels(sourceBuffer, to: 32, formatCache: &trimCache)
        #expect(untouched === sourceBuffer)
    }

    @Test func uniqueURLAddsSuffixOnCollision() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniqueURL-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("A_001_C01").appendingPathExtension("mov")
        // free — the name doesn't change
        #expect(CapturePipeline.uniqueURL(for: url) == url)

        // taken — _2 is added, then _3
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let second = CapturePipeline.uniqueURL(for: url)
        #expect(second.lastPathComponent == "A_001_C01_2.mov")
        FileManager.default.createFile(atPath: second.path, contents: Data())
        #expect(CapturePipeline.uniqueURL(for: url).lastPathComponent == "A_001_C01_3.mov")
    }

    @Test func manualModeIgnoresRunningTimecode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = CaptureSettings()
        settings.destinationPath = root.path
        settings.detectionMode = .manual

        let pipeline = CapturePipeline(config: .init(
            settings: settings, scene: "1", takeNumber: 1))
        var recStarted = false
        pipeline.onRecStateChanged = { if $0 { recStarted = true } }

        pipeline.handleFormat(CaptureFormat(
            width: 320, height: 180, frameRate: 25, timecodeFPS: 25, name: "test"))
        let pixelBuffer = TestMedia.pixelBuffer()
        var tc = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0, fps: 25)
        for frame in 1...30 {
            tc = tc.advanced(by: 1)
            pipeline.handleFrame(
                pixelBuffer: pixelBuffer,
                pts: CMTime(value: CMTimeValue(frame * 40), timescale: 1000),
                timecode: tc, vancTrigger: nil)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!recStarted, "in manual mode a running TC must not start recording")
    }

    @Test func grabNextFrameProducesPNG() async {
        let pipeline = CapturePipeline(config: .init(settings: CaptureSettings(),
                                                     takeNumber: 1))
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180, frameRate: 25,
                                            timecodeFPS: 25, name: "t"))
        let pixelBuffer = TestMedia.pixelBuffer()
        let png: Data? = await withCheckedContinuation { cont in
            pipeline.grabNextFrame { cont.resume(returning: $0) }
            for frame in 0..<3 {
                pipeline.handleFrame(
                    pixelBuffer: pixelBuffer,
                    pts: CMTime(value: CMTimeValue(frame * 40), timescale: 1000),
                    timecode: nil, vancTrigger: nil)
            }
        }
        #expect(png != nil)
        // PNG magic bytes: 89 50 4E 47
        #expect(png?.prefix(4).elementsEqual([0x89, 0x50, 0x4E, 0x47]) == true)
    }
}
