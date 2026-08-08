import CaptureCore
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import TakeShotKit

/// An extra multicam camera, driven end to end through a stub backend — no
/// board and no window.
///
/// The failure this guards is the one that cost a shoot day: `isRecording` only
/// flips once the pipeline reports back, after the pre-roll drain, so the
/// channel latches what REC *asked* for separately. When that latch was
/// mis-tracked, a second start was swallowed as "already recording" and B-cam
/// ran one continuous clip out of phase with A-cam for the rest of the day.
@MainActor
struct ModelCameraChannelTests {
    private func pixelBuffer() -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 180,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        guard let out else { fatalError("could not allocate a test frame") }
        return out
    }

    private func settings(destination: String) -> CaptureSettings {
        var settings = CaptureSettings()
        settings.codec = .proResProxy
        settings.destinationPath = destination
        settings.namingTemplate = "{cam}{roll}C{clip}"
        // VANC-only (the shipping default) with a standing timecode: nothing can
        // start a take except the REC request under test
        settings.detectionMode = .vanc
        settings.preRollFrames = 0
        // deliberately the MAIN camera's label — the channel has to override it
        settings.cameraLabel = "A"
        return settings
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCameraChannel-\(UUID().uuidString)")
    }

    /// Feed `count` frames at the live 40 ms pace; a synthetic feed running flat
    /// out overtakes the writer and the assertions turn into coin flips.
    private func feed(_ backend: StubBackend, buffer: CVPixelBuffer,
                      count: Int, startingAt index: Int) async throws -> Int {
        var frame = index
        let standing = Timecode(hours: 9, minutes: 0, seconds: 0, frames: 0, fps: 25)
        for _ in 0..<count {
            frame += 1
            backend.delegate?.backend(backend, didReceive: CapturedFrame(
                pixelBuffer: buffer,
                pts: CMTime(value: CMTimeValue(frame * 40), timescale: 1000),
                timecode: standing))
            try await Task.sleep(for: .milliseconds(40))
        }
        return frame
    }

    /// A board already held by another app used to fail completely silently.
    @Test func startSurfacesABackendFailure() {
        struct Busy: Error {}
        let backend = StubBackend(devices: [CaptureDeviceInfo(id: "x", name: "X")])
        backend.startError = Busy()
        let channel = CameraChannel(camLabel: "B", backend: backend, deviceID: "x",
                                    settings: settings(destination: "/tmp"),
                                    roll: "001")
        #expect(throws: Busy.self) { try channel.start() }
    }

    @Test func startTellsThePipelineHowManyChannelsTheBoardEmbeds() throws {
        let backend = StubBackend(devices: [CaptureDeviceInfo(id: "x", name: "X")],
                                  audioChannels: 8)
        let channel = CameraChannel(camLabel: "B", backend: backend, deviceID: "x",
                                    settings: settings(destination: "/tmp"),
                                    roll: "001")
        try channel.start()
        #expect(backend.startedDeviceIDs == ["x"])
        channel.stopStreams()
        #expect(backend.stopCount >= 1)
    }

    /// The channel names its files after ITS camera, not the main one's — that
    /// is the whole point of a second channel.
    @Test func aTakeIsNamedForTheChannelsOwnCamera() async throws {
        let root = scratch()
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let backend = StubBackend(devices: [CaptureDeviceInfo(id: "x", name: "X")])
        let channel = CameraChannel(camLabel: "B", backend: backend, deviceID: "x",
                                    settings: settings(destination: root.path),
                                    roll: "007")
        var takes: [Take] = []
        var errors: [String] = []
        channel.onTakeFinished = { takes.append($0) }
        channel.onError = { errors.append($0) }
        try channel.start()

        let buffer = pixelBuffer()
        channel.pipeline.handleFormat(CaptureFormat(
            width: 320, height: 180, frameRate: 25, timecodeFPS: 25, name: "test"))
        var index = try await feed(backend, buffer: buffer, count: 3, startingAt: 0)
        channel.setRecording(true)
        index = try await feed(backend, buffer: buffer, count: 12, startingAt: index)
        channel.setRecording(false)
        _ = try await feed(backend, buffer: buffer, count: 2, startingAt: index)

        await ControllerWait.untilWritten { !takes.isEmpty }
        channel.stopStreams()
        await channel.pipeline.finishPendingWrites()

        // a video-only feed legitimately warns about the missing audio track;
        // whatever it reports has to name the channel it came from
        #expect(errors.allSatisfy { $0.hasPrefix("B: ") },
                "untagged: \(errors.joined(separator: "; "))")
        let take = try #require(takes.first)
        #expect(take.displayName.hasPrefix("B007C"),
                "named \(take.displayName) — the main camera's label leaked in")
        #expect(take.roll == "007")
        #expect(FileManager.default.fileExists(atPath: take.url.path))
    }

    /// REC arriving twice (the hotkey and the button, or a repeat) must not be
    /// read as start-then-stop.
    @Test func aRepeatedRecordRequestIsIgnored() async throws {
        let root = scratch()
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let backend = StubBackend(devices: [CaptureDeviceInfo(id: "x", name: "X")])
        let channel = CameraChannel(camLabel: "B", backend: backend, deviceID: "x",
                                    settings: settings(destination: root.path),
                                    roll: "001")
        var takes: [Take] = []
        channel.onTakeFinished = { takes.append($0) }
        try channel.start()

        let buffer = pixelBuffer()
        channel.pipeline.handleFormat(CaptureFormat(
            width: 320, height: 180, frameRate: 25, timecodeFPS: 25, name: "test"))
        var index = try await feed(backend, buffer: buffer, count: 3, startingAt: 0)
        channel.setRecording(true)
        channel.setRecording(true) // the repeat that used to close the take
        index = try await feed(backend, buffer: buffer, count: 12, startingAt: index)
        // still rolling, so nothing has been handed up yet
        #expect(takes.isEmpty, "the repeated request closed the take")
        channel.setRecording(false)
        channel.setRecording(false) // …and a repeated stop must not open one
        _ = try await feed(backend, buffer: buffer, count: 3, startingAt: index)

        await ControllerWait.untilWritten { !takes.isEmpty }
        channel.stopStreams()
        await channel.pipeline.finishPendingWrites()
        #expect(takes.count == 1, "expected one take, got \(takes.count)")
    }

    /// Two takes in a row: the second start must not be swallowed, and the clip
    /// number has to move so the files do not collide.
    @Test func consecutiveTakesAreDistinctAndNumbered() async throws {
        let root = scratch()
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let backend = StubBackend(devices: [CaptureDeviceInfo(id: "x", name: "X")])
        let channel = CameraChannel(camLabel: "B", backend: backend, deviceID: "x",
                                    settings: settings(destination: root.path),
                                    roll: "001")
        var takes: [Take] = []
        channel.onTakeFinished = { takes.append($0) }
        try channel.start()

        let buffer = pixelBuffer()
        channel.pipeline.handleFormat(CaptureFormat(
            width: 320, height: 180, frameRate: 25, timecodeFPS: 25, name: "test"))
        var index = try await feed(backend, buffer: buffer, count: 2, startingAt: 0)
        for take in 1...2 {
            channel.setRecording(true)
            index = try await feed(backend, buffer: buffer, count: 10,
                                   startingAt: index)
            channel.setRecording(false)
            index = try await feed(backend, buffer: buffer, count: 3,
                                   startingAt: index)
            await ControllerWait.untilWritten { takes.count >= take }
            // the channel bumps its own clip number after each finished take
            channel.update(settings: settings(destination: root.path),
                           roll: "001", takeNumber: take + 1)
        }

        channel.stopStreams()
        await channel.pipeline.finishPendingWrites()

        #expect(takes.count == 2, "the second start was swallowed")
        let urls = Set(takes.map(\.url))
        #expect(urls.count == 2, "both takes went to the same file")
        for take in takes {
            #expect(take.displayName.hasPrefix("B001C"))
            #expect(FileManager.default.fileExists(atPath: take.url.path))
        }
    }

    /// A recording failure on an extra channel used to be discarded outright:
    /// a take joins the list only on success, so a failed B-cam take left no
    /// trace at all. It now surfaces, tagged with the camera it came from.
    @Test func recordingErrorsSurfaceTaggedWithTheCameraLabel() async throws {
        let backend = StubBackend(devices: [CaptureDeviceInfo(id: "x", name: "X")])
        // a destination no writer can create a file in
        let channel = CameraChannel(
            camLabel: "C", backend: backend, deviceID: "x",
            settings: settings(destination: "/dev/null/nowhere"), roll: "001")
        var errors: [String] = []
        var takes: [Take] = []
        channel.onError = { errors.append($0) }
        channel.onTakeFinished = { takes.append($0) }
        try channel.start()

        let buffer = pixelBuffer()
        channel.pipeline.handleFormat(CaptureFormat(
            width: 320, height: 180, frameRate: 25, timecodeFPS: 25, name: "test"))
        _ = try await feed(backend, buffer: buffer, count: 2, startingAt: 0)
        channel.setRecording(true)
        _ = try await feed(backend, buffer: buffer, count: 3, startingAt: 2)

        await ControllerWait.until { !errors.isEmpty }
        channel.stopStreams()
        await channel.pipeline.finishPendingWrites()

        #expect(takes.isEmpty)
        let message = try #require(errors.first)
        #expect(message.hasPrefix("C: "), "untagged channel error: \(message)")
    }
}
