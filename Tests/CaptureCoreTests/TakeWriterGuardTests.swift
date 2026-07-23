import AVFoundation
import CoreVideo
import Testing
@testable import CaptureCore

/// Guards found in the real-device audit: a backend that misdelivers PTS
/// (duplicates/backwards) must not poison AVAssetWriter, and a take with zero
/// frames must not leave a 0-byte file behind.
@Suite struct TakeWriterGuardTests {
    private let format = CaptureFormat(width: 64, height: 64, frameRate: 25,
                                       timecodeFPS: 25, isDropFrame: false,
                                       name: "test")

    private func makeBuffer() -> CVPixelBuffer? {
        var buf: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                            kCVPixelFormatType_32BGRA, nil, &buf)
        return buf
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("writer_guard_\(UUID().uuidString).mov")
    }

    @Test func duplicateAndBackwardsPTSFramesAreDroppedNotFatal() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TakeWriter(url: url, format: format, codec: .proResProxy,
                                    startTimecode: nil)
        guard let buffer = makeBuffer() else {
            Issue.record("buffer alloc failed"); return
        }
        let t0 = CMTime(seconds: 100.0, preferredTimescale: 240_000)
        let t1 = CMTime(seconds: 100.04, preferredTimescale: 240_000)
        #expect(writer.append(pixelBuffer: buffer, pts: t0))
        #expect(!writer.append(pixelBuffer: buffer, pts: t0))  // duplicate
        #expect(!writer.append(pixelBuffer: buffer, pts: t0 - t1)) // backwards
        #expect(writer.append(pixelBuffer: buffer, pts: t1))  // still alive
        let out = try await writer.finish()
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size]
                    as? Int) ?? 0
        #expect((size ?? 0) > 0)
    }

    @Test func zeroFrameTakeThrowsAndLeavesNoFile() async throws {
        let url = tempURL()
        let writer = try TakeWriter(url: url, format: format, codec: .proResProxy,
                                    startTimecode: nil)
        await #expect(throws: TakeWriter.WriterError.self) {
            _ = try await writer.finish()
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
