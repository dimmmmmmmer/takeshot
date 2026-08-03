@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// What the 12-bit record path actually delivers, measured through a real
/// ProRes encode and decode rather than argued from the format's name.
///
/// This is the 12-bit counterpart of `LevelsExcursionTests`, and the headline
/// result is different — better, and worth being precise about. The 10-bit path
/// has to precompensate because VideoToolbox reads `'r210'` as video-range
/// 64–960 and clamps outside it, so a 10-bit file is wire-REFERRED: a tool that
/// expands 64–940 once recovers what the camera sent. The 12-bit record buffer
/// is `kCVPixelFormatType_64RGBALE`, which VideoToolbox treats as FULL range —
/// no window, no clamp, no precompensation — so the file is wire-EXACT and the
/// codes come straight back.
///
/// Everything here is synthetic: there is no board, so the wire frames are
/// hand-built from Blackmagic's published byte table. What cannot be checked
/// without hardware is whether a real UltraStudio 4K Mini puts studio-swing
/// codes in an 'R12B' frame at all (the SDK calls the CONTAINER full-range) —
/// see the report.
struct TwelveBitRecordTests {
    private static let bands = [
        R12BFixtures.footroom, R12BFixtures.nominalBlack, R12BFixtures.midGrey,
        R12BFixtures.nominalWhite, R12BFixtures.headroom,
    ]
    private static let bandWidth = 64
    private static let frameWidth = bandWidth * bands.count
    private static let frameHeight = 64

    /// Centre of band `index` — never an edge, so a DCT codec's ringing is not
    /// what is being measured.
    private static func bandColumn(_ index: Int) -> Int {
        index * bandWidth + bandWidth / 2
    }

    private func bandedFrame() throws -> CVPixelBuffer {
        try R12BFixtures.makeGrey(width: Self.frameWidth,
                                  height: Self.frameHeight) { x, _ in
            Self.bands[x / Self.bandWidth]
        }
    }

    /// A wire frame through the converter and a real encode. The one place a
    /// file is written in this suite, so every measurement below is going
    /// through the same encoder settings the app uses.
    private func encode(_ wire: CVPixelBuffer, codec: CaptureCodec,
                        levels: InputLevels, name: String,
                        in root: URL) async throws -> URL {
        let converter = TwelveBitConverter()
        converter.setLevels(levels)
        let split = try #require(converter.convert(wire))
        let url = root.appendingPathComponent("\(name).mov")
        let format = CaptureFormat(width: CVPixelBufferGetWidth(wire),
                                   height: CVPixelBufferGetHeight(wire),
                                   frameRate: 25, timecodeFPS: 25, name: name,
                                   isRGB444: true, bitDepth: 12)
        let writer = try TakeWriter(url: url, format: format, codec: codec,
                                    startTimecode: nil)
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

    private func writeBands(codec: CaptureCodec, levels: InputLevels,
                            in root: URL) async throws -> URL {
        try await encode(try bandedFrame(), codec: codec, levels: levels,
                         name: "bands12", in: root)
    }

    /// The middle row of the first decoded frame, in 12-bit units. Rounded, not
    /// truncated: the 16-bit value the decoder hands back can sit a count either
    /// side, and truncating would report a bias that is an artefact of the
    /// readback rather than of the file.
    private static func middleRow(of url: URL,
                                  height: Int) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let track = try #require(
            try await asset.loadTracks(withMediaType: .video).first)
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
        let row = base + stride * (height / 2)
        let width = CVPixelBufferGetWidth(buffer)
        return (0..<width).map { (Int(row[$0 * 4]) + 8) >> 4 } // red, 16 → 12
    }

    private func decodedBands(codec: CaptureCodec = .proRes4444,
                              levels: InputLevels = .limited) async throws -> [Int] {
        let root = TestMedia.scratchDirectory("TwelveBitRecord")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await writeBands(codec: codec, levels: levels, in: root)
        let row = try await Self.middleRow(of: url, height: Self.frameHeight)
        return (0..<Self.bands.count).map { row[Self.bandColumn($0)] }
    }

    /// The measurement the whole record path exists for: the file gives back
    /// the codes the CAMERA sent, at 12-bit precision, footroom and headroom
    /// included.
    @Test func theFileGivesBackTheWireCodesExactly() async throws {
        let decoded = try await decodedBands()
        print("R12B decoded 12-bit wire codes: \(decoded) (sent \(Self.bands))")
        for (band, wire) in Self.bands.enumerated() {
            let detail = "sent \(wire), read \(decoded[band]); all \(decoded)"
            // ±1 in 12-bit units is the codec's, measured; the flat bands came
            // back EXACT when this was written
            #expect(abs(decoded[band] - wire) <= 1, "band \(band): \(detail)")
        }
        // and the property the record path exists for: the excursions are still
        // OUTSIDE the nominal pair rather than flattened onto it
        #expect(decoded[0] < decoded[1] - 100,
                "the footroom collapsed onto nominal black: \(decoded)")
        #expect(decoded[4] > decoded[3] + 100,
                "the headroom collapsed onto nominal white: \(decoded)")
    }

    /// No video-range window and no clamp, which is what makes this path
    /// wire-exact rather than wire-referred. Code 0 and code 4095 are the test:
    /// on the 10-bit path VideoToolbox clamps them into 64–960.
    @Test func theCodecDoesNotImposeAVideoRangeWindow() async throws {
        let root = TestMedia.scratchDirectory("TwelveBitFullRange")
        defer { try? FileManager.default.removeItem(at: root) }
        let ends = [0, R12BPacking.maxCode]
        let source = try R12BFixtures.makeGrey(width: 128, height: 64) { x, _ in
            ends[x / 64]
        }
        let url = try await encode(source, codec: .proRes4444, levels: .limited,
                                   name: "ends", in: root)
        let row = try await Self.middleRow(of: url, height: 64)
        let black = row[32], white = row[96]
        print("R12B range ends: 0 -> \(black), 4095 -> \(white)")
        #expect(black <= 1, "code 0 came back as \(black) — a footroom clamp")
        #expect(white >= R12BPacking.maxCode - 1,
                "code 4095 came back as \(white) — a headroom clamp")
    }

    /// A file the display mode cannot change: the same codes come out whatever
    /// the monitor was set to while it was recorded.
    @Test func theFileDoesNotDependOnTheDisplayMode() async throws {
        let limited = try await decodedBands(levels: .limited)
        let full = try await decodedBands(levels: .full)
        #expect(limited == full, "limited \(limited) vs full \(full)")
    }

    /// The codec is really ProRes 4444 ('ap4h'), and the file carries the same
    /// colour tags every other take does — Rec.709 on all three axes and NO
    /// full-range flag. Tagging a writer-bound buffer with anything
    /// non-standard is a hard-won lesson in this repo.
    @Test func theFileIsProRes4444AndTaggedLikeEveryOtherTake() async throws {
        let root = TestMedia.scratchDirectory("TwelveBitTags")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await writeBands(codec: .proRes4444, levels: .limited,
                                       in: root)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.tracks(ofType: .video).first)
        let description = try #require(
            try await track.load(.formatDescriptions).first)
        let subType = CMFormatDescriptionGetMediaSubType(description)
        #expect(subType == kCMVideoCodecType_AppleProRes4444,
                "the file is not ProRes 4444")
        let extensions = CMFormatDescriptionGetExtensions(description)
            as? [String: Any] ?? [:]
        func tag(_ key: CFString) -> String? { extensions[key as String] as? String }
        #expect(tag(kCMFormatDescriptionExtension_ColorPrimaries)
            == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String))
        #expect(tag(kCMFormatDescriptionExtension_TransferFunction)
            == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String))
        #expect(tag(kCMFormatDescriptionExtension_YCbCrMatrix)
            == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String))
        #expect(extensions[kCMFormatDescriptionExtension_FullRangeVideo as String]
            == nil, "the file claims full range: \(extensions)")
    }

    /// Why the codec had to be added rather than reusing ProRes 422 HQ.
    ///
    /// On the grey bands above the two measure the SAME — a flat grey patch has
    /// no chroma detail for 4:2:2 to lose, and that is worth knowing rather than
    /// glossing over. The difference is horizontal chroma resolution, so this
    /// uses alternating colour columns, which is the case that separates them.
    @Test func onlyProRes4444KeepsTheChromaSampling() async throws {
        let full444 = try await chromaSwing(.proRes4444)
        let subsampled = try await chromaSwing(.proResHQ)
        print("chroma swing 12-bit: 4444 \(full444), 422 HQ \(subsampled)")
        #expect(full444 > subsampled,
                "4444 \(full444) did not beat 422 HQ \(subsampled)")
        #expect(CaptureCodec.proRes4444.isRGB444Capable)
        #expect(!CaptureCodec.proResHQ.isRGB444Capable)
    }

    /// Red swing between neighbouring columns of a one-pixel red/green pattern,
    /// in 12-bit units: full through a 4:4:4 codec, roughly halved by the
    /// horizontal average a 4:2:2 one applies.
    private func chromaSwing(_ codec: CaptureCodec) async throws -> Int {
        let root = TestMedia.scratchDirectory("TwelveBitChroma")
        defer { try? FileManager.default.removeItem(at: root) }
        let width = 128, height = 64
        let source = try R12BFixtures.makeR12B(width: width,
                                               height: height) { x, _ in
            x.isMultiple(of: 2)
                ? R12BPacking.Pixel(r: 3760, g: 256, b: 256)
                : R12BPacking.Pixel(r: 256, g: 3760, b: 256)
        }
        let url = try await encode(source, codec: codec, levels: .full,
                                   name: "chroma", in: root)
        let row = try await Self.middleRow(of: url, height: height)
        var swing = 0
        for x in 32..<96 where x.isMultiple(of: 2) {
            swing = max(swing, abs(row[x] - row[x + 1]))
        }
        return swing
    }
}
