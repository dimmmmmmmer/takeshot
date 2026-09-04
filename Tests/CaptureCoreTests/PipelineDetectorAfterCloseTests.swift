import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// **A take closed by anything other than the detector still tells the
/// detector.**
///
/// The detector set itself false on its own `.stopped` event and nowhere else.
/// A take closed by a writer failure, a failed start, a disk-full stop or a
/// relay left it believing it was recording — and `vancEvent` ignores a start
/// while recording. A 40-minute interview: the drive fills at minute 20, the
/// operator swaps drives at minute 21, the camera never stopped rolling — and
/// nothing recorded until the camera stopped and started again, with no alarm
/// saying auto-detection was suspended.
@Suite struct PipelineDetectorAfterCloseTests {
    private func pipeline(in root: URL) -> CapturePipeline {
        var settings = CaptureSettings()
        settings.capture.codec = .proResProxy
        settings.capture.destinationPath = root.path
        settings.capture.detectionMode = .vanc
        settings.capture.preRollFrames = 0
        return CapturePipeline(config: .init(settings: settings, takeNumber: 1))
    }

    private func buffer() throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        return try #require(out)
    }

    private func feed(_ pipeline: CapturePipeline, _ buffer: CVPixelBuffer,
                      count: Int, from index: Int, trigger: VancTrigger? = nil)
        async throws -> Int {
        var frame = index
        let standing = Timecode(hours: 9, minutes: 0, seconds: 0, frames: 0, fps: 25)
        for step in 0..<count {
            frame += 1
            pipeline.handleFrame(CapturedFrame(
                pixelBuffer: buffer,
                pts: CMTime(value: CMTimeValue(frame * 40), timescale: 1000),
                timecode: standing, vancTrigger: step == 0 ? trigger : nil,
                ancillaryPackets: []))
            try await Task.sleep(for: .milliseconds(40))
        }
        return frame
    }

    @Test func theCamerasNextFlagOpensATakeAfterADiskFullClose() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DetectorAfterClose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = self.pipeline(in: root)
        let buffer = try self.buffer()
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180, frameRate: 25,
                                            timecodeFPS: 25, name: "test"))

        var index = try await feed(pipeline, buffer, count: 6, from: 0, trigger: .recordStart)
        await TestWait.until({ pipeline.health.isRecording }, timeout: .seconds(3))
        #expect(pipeline.health.isRecording, "the camera's REC flag opened nothing")

        // The disk-full close: not the detector's doing.
        pipeline.stopRecordingIfRolling()
        index = try await feed(pipeline, buffer, count: 3, from: index)
        await TestWait.until({ !pipeline.health.isRecording }, timeout: .seconds(3))
        #expect(!pipeline.health.isRecording, "the disk-full close left the take open")

        // The camera never stopped; it sends its next flag.
        _ = try await feed(pipeline, buffer, count: 6, from: index, trigger: .recordStart)
        await TestWait.until({ pipeline.health.isRecording }, timeout: .seconds(3))
        #expect(pipeline.health.isRecording, """
            after a close the detector did not make, it still believed it was \
            recording and ignored the camera's next REC flag — auto-detection \
            was dead for the rest of the camera take
            """)
        pipeline.stopRecordingIfRolling()
        await pipeline.finishPendingWrites()
    }
}
