import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import CaptureCore

/// A take that dies mid-recording used to be indistinguishable from a busy
/// encoder, and its half-written file was re-adopted by the folder scan looking
/// perfectly healthy. Both behaviours are pinned here.
@Suite struct FailedTakeTests {
    private let format = CaptureFormat(width: 64, height: 64, frameRate: 25,
                                       timecodeFPS: 25, isDropFrame: false,
                                       name: "test")

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed_take_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    private func makeBuffer(side: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                            kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer
    }

    /// A dropped frame now decides whether the take keeps running, so the
    /// routine reasons for a `false` from `append` must never look like a dead
    /// writer — that direction would abort good takes on a 4K peak.
    ///
    /// The opposite direction (a genuinely failed AVAssetWriter) has no
    /// deterministic trigger from a test: deleting the output directory leaves
    /// the open file handle valid on APFS, and both an off-size pixel buffer and
    /// a mismatched audio format are accepted by AVFoundation rather than
    /// failing the writer. It is covered on device, not here.
    @Test func routineDropsAreNotReportedAsWriterFailure() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try TakeWriter(url: dir.appendingPathComponent("t.mov"),
                                    format: format, codec: .proResProxy,
                                    startTimecode: nil)
        let frame = try #require(makeBuffer(side: 64))
        #expect(writer.append(pixelBuffer: frame,
                              pts: CMTime(seconds: 1, preferredTimescale: 600)))
        #expect(!writer.hasFailed)

        // duplicate PTS — refused by our own guard, writer stays healthy
        #expect(!writer.append(pixelBuffer: frame,
                               pts: CMTime(seconds: 1, preferredTimescale: 600)))
        #expect(!writer.hasFailed)

        // backwards PTS — same
        #expect(!writer.append(pixelBuffer: frame,
                               pts: CMTime(seconds: 0.5, preferredTimescale: 600)))
        #expect(!writer.hasFailed)

        // and the take is still writable afterwards
        #expect(writer.append(pixelBuffer: frame,
                              pts: CMTime(seconds: 2, preferredTimescale: 600)))
        #expect(!writer.hasFailed)
    }

    @Test func markFailedRenamesTheFileOutOfTheWay() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("A001C014.mov")
        FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))

        let marked = CapturePipeline.markFailed(url)

        #expect(marked.lastPathComponent == "A001C014_FAILED.mov")
        #expect(FileManager.default.fileExists(atPath: marked.path))
        // the recording is renamed, never deleted: with fragmented moov atoms
        // most of a failed take is still recoverable
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func markFailedDoesNotClobberAnEarlierFailure() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("A001C014.mov")
        FileManager.default.createFile(atPath: first.path, contents: Data([0x01]))
        _ = CapturePipeline.markFailed(first)

        // same name recorded again, fails again
        FileManager.default.createFile(atPath: first.path, contents: Data([0x02]))
        let second = CapturePipeline.markFailed(first)

        #expect(second.lastPathComponent == "A001C014_FAILED_2.mov")
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("A001C014_FAILED.mov").path))
    }

    @Test func markFailedIsIdempotent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("A001C014_FAILED.mov")
        FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))

        #expect(CapturePipeline.markFailed(url) == url)
    }

    @Test func markFailedOnAMissingFileReportsTheOriginalPath() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("gone.mov")
        // nothing to rename — the caller still needs a name for the alarm
        #expect(CapturePipeline.markFailed(url).lastPathComponent == "gone.mov")
    }
}
