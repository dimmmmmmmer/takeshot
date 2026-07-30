import AVFoundation
import CaptureCore
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

// Real media for the playback half of the app.
//
// Everything the playback suites load is written here by the app's own
// TakeWriter rather than checked in as a sample: the thing under test is that
// what THIS build records is what THIS build can play back, read timecode out
// of, thumbnail and tag. A fixture file would keep passing after the writer
// started producing something the player cannot open.
enum MediaFixtures {
    /// A scratch directory the caller removes in a `defer`. Never the record
    /// folder of a controller under test unless the test says so.
    static func scratchDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
    }

    static func makeDirectory(_ name: String) throws -> URL {
        let url = scratchDirectory(name)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    /// The 25 fps standby timecode the rest of the fixtures start from.
    static let startTimecode = Timecode(hours: 10, minutes: 0, seconds: 0,
                                        frames: 0, fps: 25)

    /// The signal every fixture clip pretends to be unless a test says
    /// otherwise. Size/rate travel as ONE CaptureFormat — four loose numbers
    /// here were four parameters every caller had to not-care about.
    static func format(width: Int = 320, height: Int = 180,
                       frameRate: Double = 25,
                       timecodeFPS: Int = 25) -> CaptureFormat {
        CaptureFormat(width: width, height: height, frameRate: frameRate,
                      timecodeFPS: timecodeFPS, name: "\(height)p")
    }

    /// A real .mov: video track, timecode track, and an audio track when
    /// `audioChannels > 0`. `bakedLUTName` writes the com.takeshot.lut tag the
    /// player uses to decide the look is already in the file.
    @discardableResult
    static func writeClip(at url: URL,
                          format: CaptureFormat = MediaFixtures.format(),
                          frames: Int = 25,
                          startTimecode: Timecode? = MediaFixtures.startTimecode,
                          audioChannels: Int = 0,
                          bakedLUTName: String? = nil,
                          level: UInt8 = 128) async throws -> URL {
        var metadata: [String: String] = [:]
        if let bakedLUTName { metadata[TakeWriter.lutKey] = bakedLUTName }
        let writer = try TakeWriter(url: url, format: format,
                                   codec: .proResProxy,
                                   startTimecode: startTimecode,
                                   markerMetadata: metadata,
                                   audioChannelCount: audioChannels)
        let picture = pixelBuffer(level: level, width: format.width,
                                  height: format.height)
        var audioCache: CMAudioFormatDescription?
        for frame in 0..<frames {
            let pts = CMTime(value: CMTimeValue(frame * 1000),
                             timescale: CMTimeScale(format.frameRate * 1000))
            try await appendWhenReady(picture, pts: pts, to: writer)
            guard audioChannels > 0 else { continue }
            appendSilence(channels: audioChannels, frame: frame,
                          cache: &audioCache, to: writer)
        }
        return try await writer.finish()
    }

    /// The suites feed the encoder faster than real time and it refuses while
    /// it catches up — the same retry loop TakeWriterTests uses.
    private static func appendWhenReady(_ buffer: CVPixelBuffer, pts: CMTime,
                                        to writer: TakeWriter) async throws {
        var attempts = 0
        while !writer.append(pixelBuffer: buffer, pts: pts), attempts < 400 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Silence, not a tone: a clip whose audio track is loaded into the app's
    /// player is played through the machine's default output, and the suite has
    /// no business making noise on the developer's or the runner's speakers.
    private static func appendSilence(channels: Int, frame: Int,
                                      cache: inout CMAudioFormatDescription?,
                                      to writer: TakeWriter) {
        let sampleFrames = 1920
        let samples = [Int16](repeating: 0, count: sampleFrames * channels)
        samples.withUnsafeBytes { raw in
            guard let base = raw.baseAddress,
                  let buffer = PCMAudio.makeSampleBuffer(
                      bytes: base, sampleFrames: sampleFrames,
                      channelCount: channels,
                      ptsSeconds: Double(frame) * 0.04,
                      formatCache: &cache) else { return }
            writer.append(audioSampleBuffer: buffer)
        }
    }

    /// A solid, opaque BGRA frame. Opaque matters: CoreImage reads 32BGRA as
    /// premultiplied, so a partial alpha silently rescales every value read back.
    static func pixelBuffer(level: UInt8, width: Int = 320,
                            height: Int = 180) -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        guard let out else { fatalError("could not allocate a \(width)x\(height) frame") }
        CVPixelBufferLockBaseAddress(out, [])
        if let base = CVPixelBufferGetBaseAddress(out) {
            let rowBytes = CVPixelBufferGetBytesPerRow(out)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = bytes + y * rowBytes
                for x in 0..<width {
                    row[x * 4] = level
                    row[x * 4 + 1] = level
                    row[x * 4 + 2] = level
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(out, [])
        return out
    }

    /// A file that is named like a movie and is not one — the decoder failure
    /// path every thumbnail and player test needs a subject for.
    @discardableResult
    static func writeCorruptClip(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 4096).write(to: url)
        return url
    }

    /// A valid 2³ .cube that maps every input to red. Small on purpose: the
    /// parser is covered elsewhere, what these suites need is a look whose
    /// effect on a frame is impossible to mistake for a rounding difference.
    @discardableResult
    static func writeRedCube(at url: URL) throws -> URL {
        var lines = ["TITLE \"test red\"", "LUT_3D_SIZE 2", ""]
        lines.append(contentsOf: Array(repeating: "1.0 0.0 0.0", count: 8))
        try lines.joined(separator: "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Collects what the playback tap delivers. The handler fires on the tap
    /// queue, so the storage is locked rather than main-actor bound.
    final class FrameCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [CVPixelBuffer] = []

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return buffers.count
        }

        var last: CVPixelBuffer? {
            lock.lock()
            defer { lock.unlock() }
            return buffers.last
        }

        func record(_ buffer: CVPixelBuffer) {
            lock.lock()
            buffers.append(buffer)
            lock.unlock()
        }
    }

    // MARK: - reading media back

    /// One read-back pixel. A named type rather than a triple: three unlabelled
    /// numbers read the same whatever order they are in, and BGRA memory order
    /// is the opposite of how the assertions talk about them.
    struct Pixel: Equatable {
        var r = 0
        var g = 0
        var b = 0

        var description: String { "\(r)/\(g)/\(b)" }
    }

    /// A BGRA pixel at a fraction across the middle row — how the compare
    /// suites tell which side of a wipe seam they are looking at.
    static func sample(_ buffer: CVPixelBuffer,
                       atFractionX fraction: Double) -> Pixel {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Pixel() }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let x = min(width - 1, max(0, Int(Double(width) * fraction)))
        let row = base.assumingMemoryBound(to: UInt8.self) + (height / 2) * rowBytes
        return Pixel(r: Int(row[x * 4 + 2]), g: Int(row[x * 4 + 1]),
                     b: Int(row[x * 4]))
    }

    /// Mute the controller's player before anything is loaded into it.
    /// `play(url:)` starts playback immediately on the machine's default output
    /// device, so a clip with an audio track would come out of the speakers of
    /// whoever runs the suite — the same reason the harness kills the monitor.
    @MainActor
    static func silence(_ controller: CaptureController) {
        controller.player.volume = 0
        controller.player.isMuted = true
    }

    /// Put the player and the tap back to rest at the end of a test. The tap's
    /// 60 Hz poll timer is owned by the dispatch system once resumed, so a test
    /// that walks away from a loaded clip leaves it ticking for the rest of the
    /// suite run.
    @MainActor
    static func stopPlayback(_ controller: CaptureController) {
        controller.player.pause()
        controller.player.replaceCurrentItem(with: nil)
        controller.rawPlayer = nil
        controller.playbackTap.setRunning(false)
        controller.playbackTap.detach()
    }
}
