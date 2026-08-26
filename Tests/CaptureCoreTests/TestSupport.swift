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
    ///
    /// `signature` fills it instead with a value that identifies the CHANNEL
    /// and the frame, for the suites where the content is the thing being
    /// checked: a buffer that reached the wrong consumer, or a channel taken
    /// from the wrong slot, is then visible rather than being a plausible zero.
    /// Silence is also what makes `AudioChannelDetector` say nothing, which is
    /// load-bearing for every suite that already passes this.
    static func audioBuffer(seconds: Double, channels: Int = 16,
                            signature: Bool = false,
                            cache: inout CMAudioFormatDescription?) -> CMSampleBuffer? {
        let frames = 1920
        var samples = [Int16](repeating: 0, count: frames * channels)
        if signature {
            for frame in 0..<frames {
                for channel in 0..<channels {
                    samples[frame * channels + channel] =
                        Self.audioSignature(frame: frame, channel: channel,
                                            seconds: seconds)
                }
            }
        }
        return samples.withUnsafeBytes { raw in
            PCMAudio.makeSampleBuffer(bytes: raw.baseAddress!, sampleFrames: frames,
                                      channelCount: channels, ptsSeconds: seconds,
                                      formatCache: &cache)
        }
    }

    /// The value one sample carries under `signature`. Deterministic in all
    /// three coordinates, so the same packet built twice is byte-identical and
    /// two different ones never are.
    static func audioSignature(frame: Int, channel: Int,
                               seconds: Double) -> Int16 {
        let packet = Int((seconds * 25).rounded())
        return Int16(truncatingIfNeeded:
            (channel + 1) * 1000 + frame % 97 + packet * 7)
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
    /// How many channels that audio carries, and whether it carries anything at
    /// all — see `TestMedia.audioBuffer`. The defaults are what every existing
    /// suite drove through here before either was a parameter.
    var audioChannels = 16
    var audioSignature = false

    private final class Counter {
        var frame = 0
        var audioCache: CMAudioFormatDescription?
    }

    private let counter = Counter()

    init(pipeline: CapturePipeline, withAudio: Bool = false,
         audioChannels: Int = 16, audioSignature: Bool = false) {
        self.pipeline = pipeline
        self.withAudio = withAudio
        self.audioChannels = audioChannels
        self.audioSignature = audioSignature
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
                                             channels: audioChannels,
                                             signature: audioSignature,
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
    /// How many channels a file's audio really carries, read off a SAMPLE rather
    /// than off the track: a format description crossing out of the nonisolated
    /// scope that loaded it is a crossing the older SDK rejects, and a count is
    /// a value. 0 when there is no audio track at all.
    static func channelCount(of url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.tracks(ofType: .audio).first
        else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        while let buffer = output.copyNextSampleBuffer() {
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                    format)?.pointee else { continue }
            return Int(asbd.mChannelsPerFrame)
        }
        return 0
    }

    /// Every byte of a file's audio track, in order.
    ///
    /// The samples themselves rather than a duration or a channel count,
    /// because "the tap did not change what the file gets" is a claim about
    /// BYTES: a mis-interleave, a channel taken from the wrong slot and a
    /// packet written twice all leave the track the right length. The take is
    /// written LPCM (`TakeWriter.audioSettings`), so the bytes on the disk are
    /// the samples that were appended and two identical takes compare equal.
    static func rawSamples(of url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.tracks(ofType: .audio).first
        else { return Data() }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        var out = Data()
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                             dataLength: length,
                                             destination: &bytes)
                == kCMBlockBufferNoErr else { continue }
            out.append(contentsOf: bytes)
        }
        return out
    }

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
