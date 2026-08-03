@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// What the 10-bit YCbCr record path actually delivers, measured through a real
/// ProRes encode and decode rather than argued from the format's name.
///
/// This is the third measurement of its kind in the project and it has the best
/// answer of the three. `LevelsExcursionTests` found that VideoToolbox reads
/// `'r210'` as video-range 64–960 and expands it inside the codec, so a 10-bit
/// RGB file is wire-REFERRED and has to be precompensated.
/// `TwelveBitRecordTests` found `kCVPixelFormatType_64RGBALE` treated as full
/// range, so a 12-bit file is wire-EXACT — at the price of a 16-bit container and
/// a conversion into it. A `'v210'` frame is wire-exact with no container change,
/// no precompensation and no conversion at all: it goes to the encoder as it came
/// off the wire.
///
/// Everything here is synthetic: there is no board, so the wire frames are
/// hand-built from the published byte table. What cannot be checked without
/// hardware is stated in the report.
struct TenBitYUVRecordTests {
    private static let bands = [
        V210Fixtures.footroom, V210Fixtures.nominalBlack, V210Fixtures.midGrey,
        V210Fixtures.nominalWhite, V210Fixtures.headroom,
    ]
    /// A multiple of six (whole chroma pairs and whole blocks) and of 48 (whole
    /// rows), so a band edge is never also a block edge being measured.
    private static let bandWidth = 96
    private static let frameWidth = bandWidth * bands.count
    private static let frameHeight = 64

    /// Centre of band `index` — never an edge, so a DCT codec's ringing is not
    /// what is being measured. Even, so it is the co-sited pixel of its pair.
    private static func bandColumn(_ index: Int) -> Int {
        index * bandWidth + bandWidth / 2
    }

    private func bandedFrame() throws -> CVPixelBuffer {
        try V210Fixtures.makeGrey(width: Self.frameWidth,
                                  height: Self.frameHeight) { x, _ in
            Self.bands[x / Self.bandWidth]
        }
    }

    /// A wire frame through the converter and a real encode. The one place a file
    /// is written in this suite, so every measurement below goes through the same
    /// encoder settings the app uses.
    private func encode(_ wire: CVPixelBuffer, codec: CaptureCodec,
                        levels: InputLevels, name: String,
                        in root: URL) async throws -> URL {
        let converter = TenBitYUVConverter()
        converter.setLevels(levels)
        let split = try #require(converter.convert(wire))
        let url = root.appendingPathComponent("\(name).mov")
        let format = CaptureFormat(width: CVPixelBufferGetWidth(wire),
                                   height: CVPixelBufferGetHeight(wire),
                                   frameRate: 25, timecodeFPS: 25, name: name,
                                   isRGB444: false, bitDepth: 10)
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

    /// The middle row of the first decoded frame, decoded back to `'v210'` — the
    /// wire format in, the wire format out, so nothing in the measurement is a
    /// conversion of its own.
    private static func middleRow(of url: URL,
                                  height: Int) async throws -> [V210Packing.Pixel] {
        let buffer = try await decoded(url, as: V210Packing.pixelFormat)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let row = base.advanced(
            by: (height / 2) * CVPixelBufferGetBytesPerRow(buffer))
        return (0..<CVPixelBufferGetWidth(buffer)).map {
            V210Packing.pixel(UnsafeRawPointer(row), x: $0)
        }
    }

    /// The same frame decoded to BGRA — what a player shows with no help from the
    /// app at all.
    private static func middleRowAsBGRA(of url: URL,
                                        height: Int) async throws -> [Int] {
        let buffer = try await decoded(url, as: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let row = base + (height / 2) * CVPixelBufferGetBytesPerRow(buffer)
        // green, the channel that carries most of the luma
        return (0..<CVPixelBufferGetWidth(buffer)).map { Int(row[$0 * 4 + 1]) }
    }

    private static func decoded(_ url: URL, as format: OSType) async throws
        -> CVPixelBuffer {
        let asset = AVURLAsset(url: url)
        let track = try #require(
            try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        let sample = try #require(output.copyNextSampleBuffer(),
                                  "the file decoded no frames")
        return try #require(CMSampleBufferGetImageBuffer(sample))
    }

    private func decodedBands(codec: CaptureCodec = .proResHQ,
                              levels: InputLevels = .limited) async throws
        -> [V210Packing.Pixel] {
        let root = TestMedia.scratchDirectory("TenBitYUVRecord")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await encode(try bandedFrame(), codec: codec, levels: levels,
                                   name: "bands210", in: root)
        let row = try await Self.middleRow(of: url, height: Self.frameHeight)
        return (0..<Self.bands.count).map { row[Self.bandColumn($0)] }
    }

    /// The measurement the whole record path rests on: the file gives back the
    /// codes the CAMERA sent, at 10-bit precision, footroom and headroom
    /// included, with no precompensation anywhere in the path.
    @Test func theFileGivesBackTheWireCodesExactly() async throws {
        let decoded = try await decodedBands()
        let luma = decoded.map(\.luma)
        print("v210 decoded 10-bit wire luma: \(luma) (sent \(Self.bands))")
        for (band, wire) in Self.bands.enumerated() {
            let detail = "sent \(wire), read \(luma[band]); all \(luma)"
            // ±1 is the codec's, measured; the flat bands came back EXACT when
            // this was written
            #expect(abs(luma[band] - wire) <= 1, "band \(band): \(detail)")
        }
        // and the property the record path exists for: the excursions are still
        // OUTSIDE the nominal pair rather than flattened onto it
        #expect(luma[0] < luma[1] - 30,
                "the footroom collapsed onto nominal black: \(luma)")
        #expect(luma[4] > luma[3] + 30,
                "the headroom collapsed onto nominal white: \(luma)")
        // a grey picture stays grey through the round trip
        #expect(decoded.allSatisfy { abs($0.cb - 512) <= 1 && abs($0.cr - 512) <= 1 },
                "the neutral chroma drifted: \(decoded)")
    }

    /// There is no video-range window and no expansion inside the codec — which
    /// is exactly what `'r210'` could not manage. The measured limit is a
    /// different and much kinder one: SMPTE reserves 0…3 and 1020…1023 for SDI's
    /// sync words, and VideoToolbox clamps into the legal 4…1019. A real signal
    /// cannot reach those codes, so the clamp is unreachable from a camera.
    @Test func theOnlyLimitIsTheReservedSyncCodes() async throws {
        let root = TestMedia.scratchDirectory("TenBitYUVEnds")
        defer { try? FileManager.default.removeItem(at: root) }
        let ends = [0, V210Packing.maxCode]
        let source = try V210Fixtures.makeGrey(width: 192, height: 64) { x, _ in
            ends[x / 96]
        }
        let url = try await encode(source, codec: .proResHQ, levels: .limited,
                                   name: "ends", in: root)
        let row = try await Self.middleRow(of: url, height: 64)
        let black = row[48].luma, white = row[144].luma
        print("v210 range ends: 0 -> \(black), 1023 -> \(white)")
        #expect(black <= 4, "code 0 came back as \(black)")
        #expect(white >= V210Packing.maxCode - 4,
                "code 1023 came back as \(white)")
        // and NOT the 'r210' behaviour: nothing was pulled to nominal black or
        // nominal white
        #expect(black < V210Fixtures.nominalBlack,
                "code 0 was clamped up to the video-range floor: \(black)")
        #expect(white > V210Fixtures.nominalWhite,
                "code 1023 was clamped down to the video-range ceiling: \(white)")
    }

    /// A file the display mode cannot change: the same codes come out whatever
    /// the monitor was set to while it was recorded.
    @Test func theFileDoesNotDependOnTheDisplayMode() async throws {
        let limited = try await decodedBands(levels: .limited).map(\.luma)
        let full = try await decodedBands(levels: .full).map(\.luma)
        #expect(limited == full, "limited \(limited) vs full \(full)")
    }

    /// Chroma survives the round trip at full 10-bit precision, and it is not
    /// resampled on the way in: ProRes 422 is 4:2:2, which is the wire's own
    /// sampling, so there is nothing for the encoder to average.
    @Test func theChromaSurvivesAtItsOwnSampling() async throws {
        let root = TestMedia.scratchDirectory("TenBitYUVChroma")
        defer { try? FileManager.default.removeItem(at: root) }
        let cbBands = [64, 512, 960]
        let crBands = [960, 512, 64]
        let source = try V210Fixtures.makeV210(width: 288, height: 64) { x, _ in
            V210Fixtures.Sample(luma: 500, cb: cbBands[x / 96], cr: crBands[x / 96])
        }
        let url = try await encode(source, codec: .proResHQ, levels: .limited,
                                   name: "chroma", in: root)
        let row = try await Self.middleRow(of: url, height: 64)
        let read = (0..<3).map { row[$0 * 96 + 48] }
        print("v210 decoded chroma: Cb \(read.map(\.cb)) Cr \(read.map(\.cr))")
        for band in 0..<3 {
            #expect(abs(read[band].cb - cbBands[band]) <= 1, "band \(band) Cb")
            #expect(abs(read[band].cr - crBands[band]) <= 1, "band \(band) Cr")
        }
    }

    /// Why a v210 take must NOT be tagged `com.takeshot.levels = "wire"`.
    ///
    /// The file's own Rec.709 + video-range tags already say what its codes mean,
    /// and AVFoundation acts on them: decoded to BGRA with no help from the app,
    /// nominal black lands on 0 and nominal white on 255 with the excursions
    /// clipped — the SAME picture the live display buffer shows. Expanding it a
    /// second time on playback would crush exactly the shadows the wire record
    /// path exists to protect.
    ///
    /// This also measures the display half of the converter against an
    /// independent implementation of the same conversion, which is worth having
    /// on its own.
    @Test func thePlayerNeedsNoExpansionBecauseTheFileSaysWhatItIs() async throws {
        let root = TestMedia.scratchDirectory("TenBitYUVPlayback")
        defer { try? FileManager.default.removeItem(at: root) }
        let wire = try bandedFrame()
        let url = try await encode(wire, codec: .proResHQ, levels: .limited,
                                   name: "playback", in: root)
        let decoded = try await Self.middleRowAsBGRA(of: url,
                                                     height: Self.frameHeight)
        let shown = (0..<Self.bands.count).map { decoded[Self.bandColumn($0)] }
        print("v210 file decoded to BGRA (green): \(shown)")
        // black is black and white is white, with no expansion applied by us
        #expect(shown[0] <= 2, "nominal-black band came back at \(shown[0])")
        #expect(shown[1] <= 2, "nominal black came back at \(shown[1])")
        #expect(shown[3] >= 253, "nominal white came back at \(shown[3])")
        #expect(shown[4] >= 253, "the headroom came back at \(shown[4])")
        // …and it matches what the live path puts on the monitor for the same
        // frame, band for band
        let converter = TenBitYUVConverter()
        converter.setLevels(.limited)
        let split = try #require(converter.convert(wire))
        CVPixelBufferLockBaseAddress(split.display, .readOnly)
        let base = try #require(CVPixelBufferGetBaseAddress(split.display))
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(split.display)
        // Spelled out in steps rather than as one expression: the type checker
        // gave up on the nested pointer arithmetic inside the closure on CI,
        // where an older Swift on a slower runner hits its budget on what this
        // machine solves without noticing. Same reading, mid-frame row, green.
        let midRow: UnsafeMutablePointer<UInt8> =
            base + stride * (Self.frameHeight / 2)
        var live: [Int] = []
        for band in 0..<Self.bands.count {
            let column: Int = Self.bandColumn(band)
            let green: UInt8 = midRow[column * 4 + 1]
            live.append(Int(green))
        }
        CVPixelBufferUnlockBaseAddress(split.display, .readOnly)
        print("the same frame on the live monitor: \(live)")
        for band in 0..<Self.bands.count {
            #expect(abs(shown[band] - live[band]) <= 2,
                    "band \(band): file \(shown[band]) vs live \(live[band])")
        }
    }

    /// The file carries the same colour tags every other take does — Rec.709 on
    /// all three axes and NO full-range flag. For this path those tags are not
    /// just correct bookkeeping, they are what makes the take play back right
    /// without a levels key, so they matter more here than anywhere.
    @Test func theFileIsTaggedLikeEveryOtherTake() async throws {
        let root = TestMedia.scratchDirectory("TenBitYUVTags")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await encode(try bandedFrame(), codec: .proResHQ,
                                   levels: .limited, name: "tags", in: root)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.tracks(ofType: .video).first)
        let description = try #require(
            try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(description)
            == kCMVideoCodecType_AppleProRes422HQ)
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

    /// Every codec the operator can pick accepts a `'v210'` buffer. A refused
    /// append is a take that records nothing, so this is a recording-integrity
    /// question rather than a colour one — and the answer had to be measured,
    /// because the pixel format handed to the writer changed under all of them.
    @Test func everyOfferedCodecAcceptsTheWireFrame() async throws {
        let root = TestMedia.scratchDirectory("TenBitYUVCodecs")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try V210Fixtures.makeGrey(width: 192, height: 64) { x, _ in
            x < 96 ? V210Fixtures.nominalBlack : V210Fixtures.nominalWhite
        }
        for codec in CaptureCodec.allCases {
            let url = try await encode(source, codec: codec, levels: .limited,
                                       name: "codec-\(codec.rawValue)", in: root)
            let size = try FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            #expect(size > 1000, "\(codec.rawValue) wrote \(size) bytes")
        }
    }

    /// The one measurement that says "do not route this through ProRes 4444",
    /// and the mirror image of the 12-bit RGB path's finding.
    ///
    /// ProRes 4444 codes RGB, so a YCbCr source is matrixed on the way in and the
    /// legal excursions fold onto the nominal pair — measured: 4 and 1019 come
    /// back as 64 and 940. The 4:2:2 family keeps them because it codes YCbCr and
    /// the wire already IS YCbCr. So the codec that is the right answer for a
    /// 12-bit RGB capture is the wrong one for a 10-bit YCbCr capture, and this
    /// is here so that a later tidy-up cannot make them "consistent".
    @Test func proRes4444FoldsTheExcursionsAndTheFourTwoTwoFamilyDoesNot() async throws {
        let subsampled = try await decodedBands(codec: .proResHQ).map(\.luma)
        let rgbCoded = try await decodedBands(codec: .proRes4444).map(\.luma)
        print("v210 through 422 HQ: \(subsampled), through 4444: \(rgbCoded)")
        #expect(subsampled[0] < V210Fixtures.nominalBlack - 30,
                "422 HQ lost the footroom: \(subsampled)")
        #expect(rgbCoded[0] >= V210Fixtures.nominalBlack - 1,
                "4444 kept the footroom after all: \(rgbCoded)")
        #expect(rgbCoded[4] <= V210Fixtures.nominalWhite + 1,
                "4444 kept the headroom after all: \(rgbCoded)")
    }
}
