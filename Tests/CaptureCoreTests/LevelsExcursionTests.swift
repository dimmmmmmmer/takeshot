@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// What happens to a camera's legal excursions — the sub-blacks below code 64
/// and the super-whites above 940 — on their way to the screen and into the
/// file.
///
/// The operator reported "slight clipping in the shadows and the highlights"
/// and was right: the limited→full expansion clamps, and because the record
/// buffer is built FROM the expanded value the codes are gone from the
/// deliverable as well, not just from the preview. Both readings are pinned
/// here numerically — the default one because it is what ships and someone has
/// to be able to see what it costs, and the new one because "preserves the
/// excursions" is a claim about numbers.
struct LevelsExcursionTests {
    /// The four codes the whole question is about: the bottom and top of the
    /// legal 10-bit range, and nominal black and white between them.
    private static let subBlack = 4
    private static let nominalBlack = 64
    private static let nominalWhite = 940
    private static let superWhite = 1019
    private static let bands = [subBlack, nominalBlack, nominalWhite, superWhite]

    private static let bandWidth = 64
    private static let frameWidth = bandWidth * bands.count
    private static let frameHeight = 64

    /// An r210 frame of four vertical bands, one per code, grey (R = G = B) so
    /// that nothing in the round trip below is measuring chroma subsampling.
    private func bandedFrame() throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Self.frameWidth,
                            Self.frameHeight, TenBitConverter.r210,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        let buffer = try #require(out)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<Self.frameHeight {
            let row = base.advanced(by: y * rowBytes)
                .assumingMemoryBound(to: UInt32.self)
            for x in 0..<Self.frameWidth {
                let code = UInt32(Self.bands[x / Self.bandWidth])
                row[x] = ((code << 20) | (code << 10) | code).bigEndian
            }
        }
        return buffer
    }

    /// Centre of band `index` — never an edge, so a DCT codec's ringing is not
    /// what is being measured.
    private func bandColumn(_ index: Int) -> Int {
        index * Self.bandWidth + Self.bandWidth / 2
    }

    private func displayByte(_ buffer: CVPixelBuffer, band: Int) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let row = base.advanced(by: 0).assumingMemoryBound(to: UInt32.self)
        return Int((row[bandColumn(band)] >> 16) & 0xFF) // red of BGRA
    }

    private func recordCode(_ buffer: CVPixelBuffer, band: Int) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let row = base.assumingMemoryBound(to: UInt32.self)
        return Int((UInt32(bigEndian: row[bandColumn(band)]) >> 20) & 0x3FF)
    }

    // MARK: - the converter, with no codec in the way

    /// The default. 4 and 64 both become black, 1019 and 940 both become white
    /// — in the DISPLAY buffer, which is what the scopes used to read, and in
    /// the RECORD buffer, which is what the colourist gets.
    @Test func theDefaultReadingDestroysTheExcursions() throws {
        let converter = TenBitConverter()
        converter.setLevels(.limited)
        let result = try #require(converter.convert(try bandedFrame()))

        #expect(displayByte(result.display, band: 0) == 0)   // 4    → 0
        #expect(displayByte(result.display, band: 1) == 0)   // 64   → 0
        #expect(displayByte(result.display, band: 2) == 255) // 940  → 255
        #expect(displayByte(result.display, band: 3) == 255) // 1019 → 255

        // and the record buffer, which is derived from the same expanded value
        #expect(recordCode(result.record, band: 0)
            == recordCode(result.record, band: 1),
                "the sub-black is already gone from the recorded frame")
        #expect(recordCode(result.record, band: 2)
            == recordCode(result.record, band: 3),
                "the super-white is already gone from the recorded frame")
        // the exact codes, so a change to the precompensation is visible here
        #expect(recordCode(result.record, band: 0) == 64)
        #expect(recordCode(result.record, band: 3) == 960)
    }

    /// The new mode. Every one of the four codes survives as its own value.
    @Test func preservingExcursionsKeepsEveryCode() throws {
        let converter = TenBitConverter()
        converter.setLevels(.limitedPreservingExcursions)
        let result = try #require(converter.convert(try bandedFrame()))

        // 4 and 1019 are the ends of the scale now
        #expect(displayByte(result.display, band: 0) == 0)
        #expect(displayByte(result.display, band: 3) == 255)
        // …and nominal black and white sit just inside them rather than on them
        #expect(displayByte(result.display, band: 1) == 15)
        #expect(displayByte(result.display, band: 2) == 235)

        let codes = (0..<4).map { recordCode(result.record, band: $0) }
        #expect(codes == [64, 117, 890, 960], "record codes: \(codes)")
        #expect(Set(codes).count == 4, "two codes collapsed onto one")
    }

    /// Nothing about the default changed. Same test as above run through the
    /// old two-state switch, because that is the call the settings plumbing
    /// still makes for the two original modes.
    @Test func theBooleanSwitchStillMeansTheOldTwoModes() throws {
        let limited = TenBitConverter()
        limited.setLimitedRange(true)
        let viaBool = try #require(limited.convert(try bandedFrame()))
        let named = TenBitConverter()
        named.setLevels(.limited)
        let viaEnum = try #require(named.convert(try bandedFrame()))
        for band in 0..<4 {
            #expect(recordCode(viaBool.record, band: band)
                == recordCode(viaEnum.record, band: band))
        }
    }

    /// The setting string resolves to the mode, including the values older
    /// saved settings carry.
    @Test func theSettingStringResolvesToTheMode() {
        #expect(InputLevels.resolved("full") == .full)
        #expect(InputLevels.resolved("limited") == .limited)
        #expect(InputLevels.resolved("limited_excursions")
            == .limitedPreservingExcursions)
        // auto, and anything unrecognised, is studio swing
        #expect(InputLevels.resolved(nil) == .limited)
        #expect(InputLevels.resolved("something else") == .limited)
    }

    // MARK: - through the writer and back out of the decoder

    /// The four codes decoded out of a real ProRes file.
    ///
    /// `TakeWriterTests` proves the writer round-trips a mid-grey within ±2/255;
    /// this asks the harder question the operator asked — whether the codes at
    /// the ENDS still exist once the file has been written and read back.
    private func decodedBands(levels: InputLevels) async throws -> [Int] {
        let converter = TenBitConverter()
        converter.setLevels(levels)
        let split = try #require(converter.convert(try bandedFrame()))
        let root = TestMedia.scratchDirectory("LevelsExcursion")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("take.mov")
        let format = CaptureFormat(width: Self.frameWidth,
                                   height: Self.frameHeight, frameRate: 25,
                                   timecodeFPS: 25, name: "bands")
        let writer = try TakeWriter(url: url, format: format,
                                    codec: .proResHQ, startTimecode: nil)
        for frame in 0..<6 {
            let pts = CMTime(value: CMTimeValue(frame * 40), timescale: 1000)
            var attempts = 0
            while !writer.append(pixelBuffer: split.record, pts: pts),
                  attempts < 200 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        _ = try await writer.finish()
        return try await Self.readBands(from: url)
    }

    /// First frame of the file, decoded into a 16-bit RGB buffer and reported
    /// back in 10-bit wire units.
    ///
    /// 64RGBALE rather than a `CGImage`: an image generator hands back 8 bits a
    /// channel, which is the very quantization this whole change is about — a
    /// test that measured through one could not tell code 4 from code 64 no
    /// matter what the file held.
    private static func readBands(from url: URL) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_64RGBALE])
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        let sample = try #require(output.copyNextSampleBuffer(),
                                  "the file decoded no frames")
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / 2
        let row = base + stride * (frameHeight / 2)
        return (0..<bands.count).map { band in
            let x = band * bandWidth + bandWidth / 2
            return Int(row[x * 4]) >> 6 // 16-bit red → 10-bit
        }
    }

    /// The default: the file comes back with the sub-black indistinguishable
    /// from nominal black and the super-white from nominal white.
    @Test func theDefaultLosesTheExcursionsInTheFileToo() async throws {
        let decoded = try await decodedBands(levels: .limited)
        print("LEVELS default decoded: \(decoded)")
        #expect(abs(decoded[0] - decoded[1]) <= 8,
                "sub-black and nominal black should be the same code: \(decoded)")
        #expect(abs(decoded[3] - decoded[2]) <= 8,
                "super-white and nominal white should be the same code: \(decoded)")
    }

    /// The new mode: the same four codes come back four different values, with
    /// the ends where the expansion put them.
    ///
    /// The tolerance is the codec's, measured: ProRes HQ is a DCT codec and
    /// nothing here claims it is lossless. What is asserted is the property the
    /// mode exists for — the codes are still TOLD APART — plus each band
    /// landing near the value the converter wrote.
    @Test func preservingExcursionsSurvivesTheEncodeDecodeRoundTrip() async throws {
        let decoded = try await decodedBands(levels: .limitedPreservingExcursions)
        print("LEVELS preserving decoded: \(decoded)")
        // the converter wrote 0, 60, 943, 1023 as intended full-range values
        let intended = [0, 60, 943, 1023]
        for (band, expected) in intended.enumerated() {
            let detail = "wrote \(expected), read \(decoded[band]); all \(decoded)"
            #expect(abs(decoded[band] - expected) <= 12,
                    "band \(band): \(detail)")
        }
        #expect(decoded[1] - decoded[0] >= 30,
                "the sub-black collapsed onto nominal black: \(decoded)")
        #expect(decoded[3] - decoded[2] >= 30,
                "the super-white collapsed onto nominal white: \(decoded)")
    }
}
