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

/// Collects pipeline events behind a lock. The callbacks fire on the main
/// queue while the test polls from a Swift-concurrency worker thread — a plain
/// `var finishedTakes: [Take]` there is a data race, and TSan aborts the suite
/// on it.
final class EventCollector<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Element] = []

    func append(_ element: Element) {
        lock.withLock { stored.append(element) }
    }

    var all: [Element] { lock.withLock { stored } }
    var isEmpty: Bool { lock.withLock { stored.isEmpty } }
    var first: Element? { lock.withLock { stored.first } }
    var last: Element? { lock.withLock { stored.last } }
}

extension EventCollector where Element: Equatable {
    func contains(_ element: Element) -> Bool {
        lock.withLock { stored.contains(element) }
    }
}

typealias TakeCollector = EventCollector<Take>

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

    /// For a condition that waits on encoding, finalizing and writing a file.
    /// The interactive budget above fails on the CI runner under coverage
    /// instrumentation — the take-finalize path there legitimately takes
    /// longer than five seconds, and the tests that wait on it went red in
    /// exactly and only that configuration. Mirrors ControllerWait.untilWritten.
    static func untilWritten(_ condition: () -> Bool) async {
        await until(condition, timeout: .seconds(45))
    }

    /// The same poll, but it ANSWERS. `until` is for getting to a state before
    /// the assertions run; this is for the cases where the arrival itself is
    /// the outcome, so the test fails on the wait rather than on a confusing
    /// assertion three lines later. Mirrors `ControllerWait.until`.
    static func becomesTrue(timeout: Duration = .seconds(45),
                            _ condition: () -> Bool) async -> Bool {
        await until(condition, timeout: timeout)
        return condition()
    }

    static func fileExists(at url: URL, timeout: Duration = .seconds(45)) async {
        // The generous default is the same I/O budget as untilWritten: this is
        // only ever awaited for files the pipeline is finalizing, and it costs
        // nothing when the file is already there.
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
