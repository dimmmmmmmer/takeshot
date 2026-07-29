import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

@testable import CaptureCore

// Shared test fixtures. Six suites had grown their own copy of
// `makePixelBuffer`, each subtly different; a signal generator that drives the
// pipeline at the live pace lived in two.

enum TestMedia {
    /// A blank BGRA frame at the size the suites capture at.
    static func pixelBuffer(width: Int = 320, height: Int = 180) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &buffer)
        // A test that cannot allocate a 320x180 buffer has nothing left to check.
        guard let buffer else {
            fatalError("CVPixelBufferCreate failed for \(width)x\(height)")
        }
        return buffer
    }

    /// A solid grey BGRA frame tagged Rec.709, for round-trip level checks.
    static func grayBuffer(_ value: UInt8,
                           width: Int = 320, height: Int = 180) -> CVPixelBuffer {
        let buffer = pixelBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(value),
               CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for (key, tag) in [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ] {
            CVBufferSetAttachment(buffer, key, tag, .shouldPropagate)
        }
        return buffer
    }

    /// 40 ms of silence on `channels` channels — shape matters, not content.
    static func audioBuffer(seconds: Double, channels: Int = 16,
                            cache: inout CMAudioFormatDescription?) -> CMSampleBuffer? {
        let frames = 1920
        let samples = [Int16](repeating: 0, count: frames * channels)
        return samples.withUnsafeBytes { raw in
            PCMAudio.makeSampleBuffer(bytes: raw.baseAddress!, sampleFrames: frames,
                                      channelCount: channels, ptsSeconds: seconds,
                                      formatCache: &cache)
        }
    }

    /// A scratch directory that the caller removes in a `defer`.
    static func scratchDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
    }
}

/// Drives a pipeline at the live 40 ms/frame pace. Synthetic feeds that run
/// flat out overtake the writer under load (CI, a parallel encoder) and the
/// suites flake; every take test pushes through this.
struct SignalDriver {
    let pipeline: CapturePipeline
    /// Set to also feed audio alongside every frame.
    var withAudio = false

    private final class Counter {
        var frame = 0
        var audioCache: CMAudioFormatDescription?
    }

    private let counter = Counter()

    init(pipeline: CapturePipeline, withAudio: Bool = false) {
        self.pipeline = pipeline
        self.withAudio = withAudio
    }

    /// One frame (and its audio) at `timecode`, then a real 40 ms wait.
    func push(_ timecode: Timecode, pixelBuffer: CVPixelBuffer) async throws {
        counter.frame += 1
        let frame = counter.frame
        pipeline.handleFrame(
            pixelBuffer: pixelBuffer,
            pts: CMTime(value: CMTimeValue(frame * 40), timescale: 1000),
            timecode: timecode, vancTrigger: nil)
        if withAudio,
           let audio = TestMedia.audioBuffer(seconds: Double(frame) * 0.04,
                                             cache: &counter.audioCache) {
            pipeline.handleAudio(audio)
        }
        try await Task.sleep(for: .milliseconds(40))
    }

    /// `count` frames with the timecode standing still (camera in standby).
    func pushStalled(_ timecode: Timecode, count: Int,
                     pixelBuffer: CVPixelBuffer) async throws {
        for _ in 0..<count {
            try await push(timecode, pixelBuffer: pixelBuffer)
        }
    }

    /// `count` frames with the timecode advancing (camera rolling); returns
    /// the timecode it ended on.
    func pushRunning(from start: Timecode, count: Int,
                     pixelBuffer: CVPixelBuffer) async throws -> Timecode {
        var timecode = start
        for _ in 0..<count {
            timecode = timecode.advanced(by: 1)
            try await push(timecode, pixelBuffer: pixelBuffer)
        }
        return timecode
    }
}

enum TestWait {
    /// Poll until `condition` holds or the budget runs out. The pipeline
    /// finishes takes asynchronously, so every assertion about a file waits.
    static func until(_ condition: () -> Bool,
                      timeout: Duration = .seconds(5)) async {
        let steps = Int(timeout / .milliseconds(50))
        for _ in 0..<steps where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    static func fileExists(at url: URL, timeout: Duration = .seconds(5)) async {
        await until({ FileManager.default.fileExists(atPath: url.path) },
                    timeout: timeout)
    }
}

enum TestAudio {
    /// What is actually in a file's audio track: where the first sample sits
    /// and how much sound there is. The declared track timeRange follows the
    /// writer's session and looks healthy even with no samples in it, so
    /// anything checking pre-roll sound has to read the samples themselves.
    static func span(of url: URL) async throws -> (first: Double?, seconds: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.tracks(ofType: .audio).first
        else { return (nil, 0) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        var first: Double?
        var total = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            if first == nil, pts.isNumeric { first = pts.seconds }
            let duration = CMSampleBufferGetDuration(buffer)
            if duration.isNumeric { total += duration.seconds }
        }
        return (first, total)
    }
}
