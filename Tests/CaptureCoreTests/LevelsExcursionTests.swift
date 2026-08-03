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
/// The two answers are deliberately different, and that is what this suite
/// exists to hold in place. The SCREEN gets the nominal expansion and clips
/// them: expanding the whole legal swing instead put nominal black at 60 of
/// 1023, and an operator judging exposure against a black that sits 6 % up the
/// scale is the complaint that started this. The FILE gets every code the
/// camera sent, because the record buffer is no longer built from the expanded
/// value — it carries the wire, precompensated for the codec and nothing else.
/// Both halves are claims about numbers, so the numbers are pinned here, on the
/// converter and then again on a real encoded file.
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

    /// Limited, on the two products at once: the picture clips the excursions
    /// onto black and white, the record buffer keeps all four codes apart.
    @Test func thePictureClipsTheExcursionsAndTheFileKeepsThem() throws {
        let converter = TenBitConverter()
        converter.setLevels(.limited)
        let result = try #require(converter.convert(try bandedFrame()))

        // the sub-black is black and the super-white is white on the monitor…
        #expect(displayByte(result.display, band: 0) == 0)
        #expect(displayByte(result.display, band: 3) == 255)
        // …because nominal black and white are ON the ends, not inside them
        #expect(displayByte(result.display, band: 1) == 0)
        #expect(displayByte(result.display, band: 2) == 255)

        let codes = (0..<4).map { recordCode(result.record, band: $0) }
        #expect(codes == [68, 120, 887, 956], "record codes: \(codes)")
        #expect(Set(codes).count == 4, "two codes collapsed onto one")
    }

    /// The two-state switch still means the same two modes — checked on the
    /// display buffer, which is the only product a levels mode reaches now.
    @Test func theBooleanSwitchStillMeansTheTwoModes() throws {
        let limited = TenBitConverter()
        limited.setLimitedRange(true)
        let viaBool = try #require(limited.convert(try bandedFrame()))
        let named = TenBitConverter()
        named.setLevels(.limited)
        let viaEnum = try #require(named.convert(try bandedFrame()))
        let full = TenBitConverter()
        full.setLimitedRange(false)
        let unexpanded = try #require(full.convert(try bandedFrame()))
        for band in 0..<4 {
            #expect(displayByte(viaBool.display, band: band)
                == displayByte(viaEnum.display, band: band))
        }
        // …and the switch is doing something: Full leaves nominal black at 16
        #expect(displayByte(unexpanded.display, band: 1) == 16)
    }

    /// The setting string resolves to the mode, including the values older
    /// saved settings carry.
    @Test func theSettingStringResolvesToTheMode() {
        #expect(InputLevels.resolved("full") == .full)
        #expect(InputLevels.resolved("limited") == .limited)
        // the retired second studio-swing mode: an operator who had it selected
        // lands on the one Limited, which is the reading they had asked for
        #expect(InputLevels.resolved("limited_excursions") == .limited)
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
        let root = TestMedia.scratchDirectory("LevelsExcursion")
        defer { try? FileManager.default.removeItem(at: root) }
        return try await Self.readBands(from: try await writeBands(levels: levels,
                                                                   in: root))
    }

    /// The banded frame through the converter and a real ProRes HQ encode.
    private func writeBands(levels: InputLevels, in root: URL) async throws -> URL {
        let converter = TenBitConverter()
        converter.setLevels(levels)
        let split = try #require(converter.convert(try bandedFrame()))
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
        return try await writer.finish()
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

    /// The whole point of the record half: the file gives back the codes the
    /// CAMERA sent — including the footroom code and the headroom code, which
    /// is what a colourist has left to pull a highlight out of.
    ///
    /// The tolerance is the codec's, measured: ProRes HQ is a DCT codec and
    /// nothing here claims it is lossless. The four bands came back exact when
    /// this was written; what is asserted is that plus the property the record
    /// path exists for — the excursions are still OUTSIDE the nominal pair
    /// rather than flattened onto it.
    @Test func theFileGivesBackTheWireCodesExcursionsIncluded() async throws {
        let decoded = try await decodedBands(levels: .limited)
        print("LEVELS decoded wire codes: \(decoded)")
        for (band, wire) in Self.bands.enumerated() {
            let detail = "sent \(wire), read \(decoded[band]); all \(decoded)"
            #expect(abs(decoded[band] - wire) <= 4, "band \(band): \(detail)")
        }
        #expect(decoded[0] < decoded[1] - 30,
                "the sub-black collapsed onto nominal black: \(decoded)")
        #expect(decoded[3] > decoded[2] + 30,
                "the super-white collapsed onto nominal white: \(decoded)")
    }

    /// A file the display mode cannot change: the same codes come out of it
    /// whatever the monitor was set to while it was recorded.
    @Test func theFileDoesNotDependOnTheDisplayMode() async throws {
        let limited = try await decodedBands(levels: .limited)
        let full = try await decodedBands(levels: .full)
        #expect(limited == full, "limited \(limited) vs full \(full)")
    }

    /// What the file says about itself, read off the video track rather than
    /// off the settings dictionary that asked for it.
    ///
    /// Rec.709 on all three axes, and NO full-range flag: the picture is coded
    /// video-range, which is what a ProRes track is, and the tags have to say
    /// so or every tool downstream expands it a second time. Tagging a
    /// writer-bound buffer with anything non-standard is a hard-won lesson in
    /// this repo — the encoder colour-converts on a tag mismatch — so the file
    /// carries the standard three and nothing else.
    @Test func theFileIsTaggedRec709AndVideoRange() async throws {
        let root = TestMedia.scratchDirectory("LevelsTags")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await writeBands(levels: .limited, in: root)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.tracks(ofType: .video).first)
        let description = try #require(
            try await track.load(.formatDescriptions).first)
        let extensions = CMFormatDescriptionGetExtensions(description)
            as? [String: Any] ?? [:]
        func tag(_ key: CFString) -> String? {
            extensions[key as String] as? String
        }
        #expect(tag(kCMFormatDescriptionExtension_ColorPrimaries)
            == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String))
        #expect(tag(kCMFormatDescriptionExtension_TransferFunction)
            == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String))
        #expect(tag(kCMFormatDescriptionExtension_YCbCrMatrix)
            == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String))
        // absent, not false: a video-range track carries no full-range flag
        #expect(extensions[kCMFormatDescriptionExtension_FullRangeVideo as String]
            == nil, "the file claims full range: \(extensions)")
    }
}
