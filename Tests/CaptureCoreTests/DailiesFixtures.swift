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
    ///
    /// `wireCodes` writes the levels key an RGB take carries, which is the
    /// file's own statement that its codes are studio swing rather than
    /// display values.
    @discardableResult
    static func writeTake(at url: URL, width: Int = 320, height: Int = 180,
                          frames: Int = 25, audioChannels: Int = 0,
                          level: UInt8 = 128,
                          wireCodes: Bool = false) async throws -> URL {
        let format = CaptureFormat(width: width, height: height, frameRate: 25,
                                   timecodeFPS: 25, name: "test")
        let writer = try TakeWriter(
            url: url, format: format, codec: .proResProxy,
            startTimecode: startTC,
            markerMetadata: wireCodes
                ? [TakeWriter.levelsKey: TakeWriter.wireValue] : [:],
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

    /// A real HDR take: a flat `'v210'` wire field at one luminance, split by
    /// the app's own converter and written by its own writer with the tags a
    /// PQ or HLG source forces on a file. The round trip through THIS build,
    /// like every other fixture here — a canned .mov would keep passing after
    /// the record path changed what it records.
    ///
    /// Flat on purpose: the question these suites ask is where ONE luminance
    /// lands, and a field of it can be sampled anywhere the burn-ins are not.
    @discardableResult
    static func writeHDRTake(at url: URL, transfer: SignalTransfer,
                             nits: Double, width: Int = 960, height: Int = 540,
                             frames: Int = 10) async throws -> URL {
        let signal: Double = try #require(
            transfer.signal(forNits: nits),
            "an SDR transfer has no signal for a luminance")
        let code = Int((64 + signal * 876).rounded())
        let wire = try V210Fixtures.makeGrey(width: width,
                                             height: height) { _, _ in code }
        let colorimetry = WireColorimetry(transfer: transfer,
                                          primaries: .rec2020)
        let converter = TenBitYUVConverter()
        converter.setLevels(.limited)
        converter.setColorimetry(colorimetry)
        let split = try #require(converter.convert(wire),
                                 "the converter would not split the wire frame")
        let format = CaptureFormat(width: width, height: height, frameRate: 25,
                                   timecodeFPS: 25, name: "hdr",
                                   isRGB444: false, bitDepth: 10)
        let writer = try TakeWriter(url: url, format: format,
                                    codec: .proResHQ, startTimecode: startTC,
                                    colorTagPreset: colorimetry.filePreset)
        for frame in 0..<frames {
            let pts = CMTime(value: CMTimeValue(frame * 1000), timescale: 25_000)
            var attempts = 0
            while !writer.append(pixelBuffer: split.record, pts: pts),
                  attempts < 400 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        return try await writer.finish()
    }

    /// A clip this app did not write: plain H.264, no colour properties, no
    /// metadata of any kind. The `Other content` block's case, and the one a
    /// take from before either tag existed looks exactly like.
    @discardableResult
    static func writeForeignClip(at url: URL, level: UInt8 = 128,
                                 width: Int = 320, height: Int = 180,
                                 frames: Int = 10) async throws -> URL {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                             AVVideoWidthKey: width,
                             AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        try #require(writer.startWriting(),
                     "the foreign-clip writer would not start")
        writer.startSession(atSourceTime: .zero)
        let picture = TestMedia.grayBuffer(level, width: width, height: height)
        for frame in 0..<frames {
            var attempts = 0
            while !input.isReadyForMoreMediaData, attempts < 400 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
            adaptor.append(picture, withPresentationTime:
                CMTime(value: CMTimeValue(frame * 1000), timescale: 25_000))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
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

    /// Mean of the three colour channels inside `rect` (top-left image
    /// coordinates). The burn-in assertions are made of `meanAbsDiff`, which
    /// asks whether something is there; the levels assertions are made of this,
    /// which asks WHERE on the scale it landed.
    static func meanLevel(_ buffer: CVPixelBuffer, in rect: CGRect) -> Double {
        var total = 0
        var counted = 0
        forEachChannel(of: buffer, in: rect) { value in
            total += value
            counted += 1
        }
        return counted > 0 ? Double(total) / Double(counted) : 0
    }

    /// The brightest single channel inside `rect` — what a burn-in's own white
    /// still reads as after H.264 has been over it.
    static func peakLevel(_ buffer: CVPixelBuffer, in rect: CGRect) -> Int {
        var peak = 0
        forEachChannel(of: buffer, in: rect) { peak = max(peak, $0) }
        return peak
    }

    private static func forEachChannel(of buffer: CVPixelBuffer, in rect: CGRect,
                                       _ body: (Int) -> Void) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                for channel in 0..<3 {
                    body(Int(bytes[y * row + x * 4 + channel]))
                }
            }
        }
    }

    /// A patch of picture no strip reaches — the control region.
    static func centerRegion(of size: CGSize) -> CGRect {
        CGRect(x: size.width * 0.4, y: size.height * 0.4,
               width: size.width * 0.2, height: size.height * 0.2)
    }

    /// Bare plate inside a burn-in strip: the left edge, well inside the text
    /// inset (0.45 of the strip height), where no glyph and no ringing from
    /// one reaches. The plate is a fixed fraction of whatever picture is under
    /// it, which is what makes it a reading of the FINISHED picture.
    static func plateRegion(of strip: CGRect) -> CGRect {
        let inset = (strip.height * 0.45).rounded()
        return CGRect(x: strip.minX + 2, y: strip.minY + 3,
                      width: max(2, inset - 5), height: max(2, strip.height - 6))
    }

    /// The fraction of the picture a strip's plate leaves showing — the
    /// overlay's own alpha, stated once so the expectation and the drawing
    /// cannot drift.
    static let plateTransmission: Double =
        1 - Double(DailiesStripMetrics.plateColor.alpha)
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
