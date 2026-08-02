@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import CaptureCore

// Shared fixtures for the dailies suites: real takes written by the app's own
// TakeWriter, and the read-back helpers the pixel assertions are made of.
// Fixture files would keep passing after the writer changed what it writes —
// the round trip through THIS build is the thing under test.

enum DailiesRig {
    static let startTC = Timecode(hours: 10, minutes: 0, seconds: 0,
                                  frames: 0, fps: 25)

    static func scratch() throws -> URL {
        let url = TestMedia.scratchDirectory("DailiesTests")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real take: grey ProRes frames, a timecode track, optionally audio —
    /// the same retry loop every writer test feeds the encoder through.
    @discardableResult
    static func writeTake(at url: URL, width: Int = 320, height: Int = 180,
                          frames: Int = 25, audioChannels: Int = 0,
                          level: UInt8 = 128) async throws -> URL {
        let format = CaptureFormat(width: width, height: height, frameRate: 25,
                                   timecodeFPS: 25, name: "test")
        let writer = try TakeWriter(url: url, format: format,
                                    codec: .proResProxy,
                                    startTimecode: startTC,
                                    audioChannelCount: audioChannels)
        let picture = TestMedia.grayBuffer(level, width: width, height: height)
        var audioCache: CMAudioFormatDescription?
        for frame in 0..<frames {
            let pts = CMTime(value: CMTimeValue(frame * 1000), timescale: 25_000)
            var attempts = 0
            while !writer.append(pixelBuffer: picture, pts: pts),
                  attempts < 400 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
            if audioChannels > 0,
               let audio = TestMedia.audioBuffer(
                   seconds: Double(frame) * 0.04, channels: audioChannels,
                   cache: &audioCache) {
                writer.append(audioSampleBuffer: audio)
            }
        }
        return try await writer.finish()
    }

    /// The engine-facing description of a fixture take — built here exactly
    /// as it is built for the engine, so the overlay layout the assertions
    /// sample is the one that was drawn.
    static func item(for url: URL) -> DailiesItem {
        DailiesItem(source: url,
                    outputName: url.deletingPathExtension()
                        .lastPathComponent + "_DAILY",
                    clipName: url.deletingPathExtension().lastPathComponent,
                    projectLine: "UnitFilm · A001", dateText: "2026-08-02",
                    startTimecode: startTC)
    }

    /// Everything the sheet can switch on, plus the custom line.
    static var allBurnins: DailiesBurnins {
        DailiesBurnins(timecode: true, clipName: true, project: true,
                       date: true, customText: "FOR REVIEW")
    }

    static var noBurnins: DailiesBurnins {
        DailiesBurnins(timecode: false, clipName: false, project: false,
                       date: false, customText: "")
    }

    // MARK: - reading the output back

    /// Frame `index` of a finished daily, decoded to BGRA.
    static func decodeFrame(_ index: Int, of url: URL) async throws
        -> CVPixelBuffer {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.tracks(ofType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
            ])
        reader.add(output)
        try #require(reader.startReading())
        defer { reader.cancelReading() }
        var remaining = index
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                continue
            }
            if remaining == 0 { return buffer }
            remaining -= 1
        }
        throw Failure("frame \(index) is past the end of \(url.lastPathComponent)")
    }

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Mean per-pixel |a-b| over all three channels inside `rect` (top-left
    /// image coordinates) — how the burn-in assertions see a strip without
    /// OCR: present vs absent is a large number, static vs static a tiny one.
    static func meanAbsDiff(_ first: CVPixelBuffer, _ second: CVPixelBuffer,
                            in rect: CGRect) -> Double {
        CVPixelBufferLockBaseAddress(first, .readOnly)
        CVPixelBufferLockBaseAddress(second, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(first, .readOnly)
            CVPixelBufferUnlockBaseAddress(second, .readOnly)
        }
        guard let baseA = CVPixelBufferGetBaseAddress(first),
              let baseB = CVPixelBufferGetBaseAddress(second) else { return 0 }
        let rowA = CVPixelBufferGetBytesPerRow(first)
        let rowB = CVPixelBufferGetBytesPerRow(second)
        let bytesA = baseA.assumingMemoryBound(to: UInt8.self)
        let bytesB = baseB.assumingMemoryBound(to: UInt8.self)
        var total = 0
        var counted = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                for channel in 0..<3 {
                    let a = Int(bytesA[y * rowA + x * 4 + channel])
                    let b = Int(bytesB[y * rowB + x * 4 + channel])
                    total += abs(a - b)
                    counted += 1
                }
            }
        }
        return counted > 0 ? Double(total) / Double(counted) : 0
    }

    /// A patch of picture no strip reaches — the control region.
    static func centerRegion(of size: CGSize) -> CGRect {
        CGRect(x: size.width * 0.4, y: size.height * 0.4,
               width: size.width * 0.2, height: size.height * 0.2)
    }
}

/// A progress recorder the engine's @Sendable callback can write to, with an
/// optional trip-wire the cancel tests pull mid-run.
final class DailiesProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [DailiesProgress] = []
    private var tripped = false
    private let tripWire: (@Sendable (DailiesProgress) -> Bool)?
    private let onTrip: (@Sendable () -> Void)?

    init(tripWire: (@Sendable (DailiesProgress) -> Bool)? = nil,
         onTrip: (@Sendable () -> Void)? = nil) {
        self.tripWire = tripWire
        self.onTrip = onTrip
    }

    func record(_ snapshot: DailiesProgress) {
        let fire: Bool = lock.withLock {
            snapshots.append(snapshot)
            guard !tripped, tripWire?(snapshot) == true else { return false }
            tripped = true
            return true
        }
        if fire { onTrip?() }
    }

    var all: [DailiesProgress] {
        lock.withLock { snapshots }
    }
}
