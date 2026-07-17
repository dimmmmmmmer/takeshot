import AVFoundation
import Foundation
import Testing
@testable import CaptureCore

struct TakeWriterTests {
    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TakeWriterTests-\(UUID().uuidString)")
            .appendingPathComponent("take.mov")
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x80, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    @Test func writesTakeWithVideoAndTimecodeTracks() async throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let format = CaptureFormat(width: 1280, height: 720, frameRate: 24,
                                   timecodeFPS: 24, name: "720p24")
        let startTC = Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, fps: 24)
        let writer = try TakeWriter(url: tempURL, format: format,
                                    codec: .proRes422, startTimecode: startTC)

        let pixelBuffer = makePixelBuffer(width: 1280, height: 720)
        for frame in 0..<24 {
            let pts = CMTime(value: CMTimeValue(frame * 1000), timescale: 24_000)
            // в тесте кадры подаются быстрее реального времени — ждём готовности энкодера
            var attempts = 0
            while !writer.append(pixelBuffer: pixelBuffer, pts: pts), attempts < 200 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let url = try await writer.finish()

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(abs(writer.durationSeconds - 1.0) < 0.05)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 1.0) < 0.1)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        #expect(videoTracks.count == 1)
        let size = try await videoTracks[0].load(.naturalSize)
        #expect(Int(size.width) == 1280)
        #expect(Int(size.height) == 720)

        let timecodeTracks = try await asset.loadTracks(withMediaType: .timecode)
        #expect(timecodeTracks.count == 1, "timecode-трек должен присутствовать")
    }

    @Test func cancelRemovesFile() throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let format = CaptureFormat(width: 640, height: 360, frameRate: 25,
                                   timecodeFPS: 25, name: "360p25")
        let writer = try TakeWriter(url: tempURL, format: format,
                                    codec: .proResProxy, startTimecode: nil)
        writer.append(pixelBuffer: makePixelBuffer(width: 640, height: 360), pts: .zero)
        writer.cancel()
        #expect(!FileManager.default.fileExists(atPath: tempURL.path))
    }
}
