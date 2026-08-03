import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The 10-bit YCbCr split: one `'v210'` wire frame into a NOMINAL-mapped display
/// buffer and a record product that IS the wire frame.
///
/// `TenBitConverterTests`/`LevelsExcursionTests` ('r210') and
/// `TwelveBitConverterTests` ('R12B') pin the same properties for the two RGB
/// paths, and the display numbers here are deliberately the same statements in
/// another colour space — 10-bit studio swing is 64…940 whether the codes arrived
/// as R'G'B' or as Y'CbCr.
struct TenBitYUVConverterTests {
    private func displayPixel(_ buffer: CVPixelBuffer, x: Int, y: Int = 0) -> UInt32 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
            .assumingMemoryBound(to: UInt32.self)
        return row[x]
    }

    /// Blue of BGRA — the low byte. The grey fixtures make all three equal, so
    /// this is "the display byte" for them.
    private func displayByte(_ buffer: CVPixelBuffer, x: Int, y: Int = 0) -> Int {
        Int(displayPixel(buffer, x: x, y: y) & 0xFF)
    }

    /// One component of the record product, read as `'v210'`.
    private func recordPixel(_ buffer: CVPixelBuffer, x: Int,
                             y: Int = 0) -> V210Packing.Pixel {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
        return V210Packing.pixel(UnsafeRawPointer(row), x: x)
    }

    /// The five codes the whole levels question is about.
    private static let codes = [
        V210Fixtures.footroom, V210Fixtures.nominalBlack, V210Fixtures.midGrey,
        V210Fixtures.nominalWhite, V210Fixtures.headroom,
    ]

    @Test func productsKeepTheirOwnPixelFormats() throws {
        let converter = TenBitYUVConverter()
        let source = try V210Fixtures.makeGrey(width: 48, height: 4) { _, _ in 500 }
        let result = try #require(converter.convert(source))
        #expect(CVPixelBufferGetPixelFormatType(result.display)
            == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetPixelFormatType(result.record)
            == V210Packing.pixelFormat)
        #expect(CVPixelBufferGetWidth(result.display) == 48)
        #expect(CVPixelBufferGetHeight(result.display) == 4)
    }

    /// The record product is the frame that came in — the same buffer, not a
    /// copy of it. That is the strongest form of "the record path does not
    /// resample chroma": it does not touch the pixels at all.
    @Test func theRecordProductIsTheWireFrameItself() throws {
        let converter = TenBitYUVConverter()
        let source = try V210Fixtures.makeGrey(width: 48, height: 4) { _, _ in 500 }
        let result = try #require(converter.convert(source))
        #expect(result.record === source,
                "the record buffer is a copy — a full frame of memcpy per frame")
    }

    @Test func aNonV210InputIsRejected() {
        let converter = TenBitYUVConverter()
        for format in [kCVPixelFormatType_32BGRA, TenBitConverter.r210,
                       R12BPacking.pixelFormat, kCVPixelFormatType_422YpCbCr8] {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 48, 16, format, nil, &buffer)
            if let buffer {
                #expect(converter.convert(buffer) == nil,
                        "a frame of \(format) was unpacked as 'v210'")
            }
        }
    }

    @Test func theConverterStatesItsRecordFormatAndFrameCost() {
        let yuv = TenBitYUVConverter()
        #expect(yuv.wireFormat == V210Packing.pixelFormat)
        #expect(yuv.recordPixelFormat == V210Packing.pixelFormat)
        // 'v210' is 2⅔ bytes a pixel, rounded UP: the pre-roll ring divides a
        // byte budget by this, so rounding down would overshoot the budget
        #expect(yuv.recordBytesPerPixel == 3)
        // and the asymmetry the whole playback question turns on
        #expect(!yuv.recordNeedsPlaybackExpansion)
        #expect(TenBitConverter().recordNeedsPlaybackExpansion)
        #expect(TwelveBitConverter().recordNeedsPlaybackExpansion)
    }

    // MARK: - levels

    @Test func fullRangeSourcePassesCodesThroughToDisplay() throws {
        let converter = TenBitYUVConverter()
        converter.setLevels(.full)
        let source = try V210Fixtures.makeGrey(width: 12, height: 2) { _, _ in 940 }
        let result = try #require(converter.convert(source))
        #expect(displayByte(result.display, x: 0) == 940 >> 2)
    }

    /// Limited expands the NOMINAL pair: black 64 onto 0 and white 940 onto 1023,
    /// with the camera's excursions clipped against those ends. The same rule the
    /// two RGB paths apply, the same reason — the operator judges exposure
    /// against a black that is black.
    @Test func limitedRangeSourceIsExpandedOnTheNominalPair() throws {
        let converter = TenBitYUVConverter() // limited is the default
        let codes = Self.codes
        let source = try V210Fixtures.makeGrey(width: codes.count * 2,
                                               height: 2) { x, _ in codes[x / 2] }
        let result = try #require(converter.convert(source))
        let shown = (0..<codes.count).map { displayByte(result.display, x: $0 * 2) }
        // footroom and nominal black are both 0; the headroom and nominal white
        // are both 255 — the excursions clip, deliberately
        #expect(shown == [0, 0, 127, 255, 255], "display bytes: \(shown)")
    }

    /// The record product cannot depend on the levels mode, because it is the
    /// wire frame — but the claim is worth a test rather than an argument, since
    /// the 10-bit RGB path had exactly this bug once.
    @Test func theRecordProductIsTheSameWhateverTheDisplayIsDoing() throws {
        let codes = Self.codes
        for levels in [InputLevels.limited, .full] {
            let converter = TenBitYUVConverter()
            converter.setLevels(levels)
            let source = try V210Fixtures.makeGrey(width: codes.count * 2,
                                                   height: 2) { x, _ in codes[x / 2] }
            let result = try #require(converter.convert(source))
            let recorded = (0..<codes.count).map {
                recordPixel(result.record, x: $0 * 2).luma
            }
            #expect(recorded == codes, "\(levels) record luma: \(recorded)")
        }
    }

    // MARK: - chroma

    /// The chroma upsample is LINEAR, not nearest, and this is the difference
    /// between them in numbers.
    ///
    /// The picture is a step in Cb from one chroma pair to the next. Under
    /// nearest, pixel 1 would carry pair 0's chroma exactly and equal pixel 0 —
    /// the two-pixel staircase. Under linear it sits between its neighbours, at
    /// their midpoint, because 4:2:2 chroma is co-sited with the even luma and
    /// only the odd pixel needs interpolating.
    @Test func theChromaUpsampleIsLinearAcrossThePair() throws {
        let converter = TenBitYUVConverter()
        converter.setLevels(.full)
        let source = try V210Fixtures.makeV210(width: 12, height: 2) { x, _ in
            V210Fixtures.Sample(luma: 500,
                                cb: x < 2 ? V210Fixtures.chromaZero : 712)
        }
        let result = try #require(converter.convert(source))
        let blue = (0..<4).map { displayByte(result.display, x: $0) }
        // nearest would leave pixel 1 on pair 0's chroma, equal to pixel 0
        #expect(blue[0] < blue[1], "nearest, not linear: \(blue)")
        #expect(blue[1] < blue[2], "pixel 1 overshot pair 1: \(blue)")
        // …and it is the MIDPOINT, within the rounding of an 8-bit display byte
        let midpoint = Double(blue[0] + blue[2]) / 2
        #expect(abs(Double(blue[1]) - midpoint) <= 1.5,
                "pixel 1 at \(blue[1]), midpoint \(midpoint)")
        // the even pixels are the coded samples, untouched: pixel 2 and pixel 3
        // are both inside the flat run, so they agree
        #expect(blue[2] == blue[3], "the flat run is not flat: \(blue)")
    }

    /// R, G and B must not be swapped, and neither must Cb and Cr. A grey fixture
    /// cannot see either, so this one is a saturated colour whose three channels
    /// are all different.
    @Test func theChannelsDoNotGetSwapped() throws {
        let converter = TenBitYUVConverter()
        converter.setLevels(.limited)
        // 100 % blue in Rec.709 studio swing: Y 127, Cb 960, Cr 471
        let source = try V210Fixtures.makeV210(width: 12, height: 2) { _, _ in
            V210Fixtures.Sample(luma: 127, cb: 960, cr: 471)
        }
        let result = try #require(converter.convert(source))
        let pixel = displayPixel(result.display, x: 4)
        let blue = Int(pixel & 0xFF)
        let green = Int((pixel >> 8) & 0xFF)
        let red = Int((pixel >> 16) & 0xFF)
        #expect(pixel >> 24 == 0xFF, "the alpha is not opaque")
        // blue is at the top of the scale, the other two at the bottom. A Cb/Cr
        // swap would light up red instead; a channel-order slip would move it to
        // the wrong byte of the word.
        #expect(blue == 255, "blue \(blue) (r \(red), g \(green))")
        #expect(red <= 1, "red \(red) is not black — Cb and Cr are swapped?")
        #expect(green <= 1, "green \(green) is not black")
    }

    // MARK: - the awkward pixels

    /// Rows are converted in parallel bands, and a band-boundary mistake shows up
    /// as rows carrying another row's value — so every row gets its own code.
    @Test func everyRowSurvivesTheParallelBandSplit() throws {
        let converter = TenBitYUVConverter()
        converter.setLevels(.full)
        let height = 1080 // enough rows to reach the maximum band count
        let source = try V210Fixtures.makeGrey(width: 48, height: height) { _, y in
            (y * 7 + 11) & 0x3FF
        }
        let result = try #require(converter.convert(source))
        for y in 0..<height {
            let expected = (y * 7 + 11) & 0x3FF
            #expect(recordPixel(result.record, x: 17, y: y).luma == expected,
                    "row \(y) record came back wrong")
            #expect(displayByte(result.display, x: 17, y: y) == expected >> 2,
                    "row \(y) display came back wrong")
        }
    }

    /// A width that is not a multiple of six leaves a partial trailing block, and
    /// the pixels of it past the frame edge hold `V210Fixtures.padding` — a
    /// violent magenta that no expansion can hide. Every pixel INSIDE the frame
    /// still has to be exactly right, chroma included.
    @Test func aPartialTrailingBlockIsStillExact() throws {
        let converter = TenBitYUVConverter()
        converter.setLevels(.full)
        let width = 100 // sixteen full blocks plus four pixels
        let source = try V210Fixtures.makeV210(width: width, height: 2) { x, _ in
            V210Fixtures.Sample(luma: 100 + x * 9, cb: 600, cr: 400)
        }
        let result = try #require(converter.convert(source))
        for x in 0..<width {
            #expect(recordPixel(result.record, x: x).luma == 100 + x * 9,
                    "pixel \(x) of a partial block came back wrong")
        }
        // The display half is where the padding could leak in: the last in-frame
        // pixel is odd, so it wants a chroma pair that does not exist. Measured on
        // a FLAT picture, where any difference between two pixels is the padding
        // and nothing else — the varying luma above would mask it.
        let flatSource = try V210Fixtures.makeV210(width: width, height: 2) { _, _ in
            V210Fixtures.Sample(luma: 500, cb: 600, cr: 400)
        }
        let flat = try #require(converter.convert(flatSource))
        let expected = displayPixel(flat.display, x: 0)
        for x in 0..<width {
            #expect(displayPixel(flat.display, x: x) == expected,
                    "pixel \(x) was tinted by the partial block's padding")
        }
    }

    /// The other edge the format has: a width that IS a multiple of six, so every
    /// block is whole, but the row is still padded out to 48 pixels. The last
    /// pixel of the picture is odd and its right-hand chroma pair lies in that
    /// padding — which the fixture has filled with poison.
    @Test func thePaddedRowEndDoesNotReachThePicture() throws {
        let converter = TenBitYUVConverter()
        converter.setLevels(.full)
        let width = 12 // two whole blocks; the row itself is 48 pixels wide
        let source = try V210Fixtures.makeV210(width: width, height: 2) { _, _ in
            V210Fixtures.Sample(luma: 500, cb: 600, cr: 400)
        }
        // the premise: there really is padding out there, and it really is poison
        #expect(CVPixelBufferGetBytesPerRow(source)
            > V210Packing.blockRowBytes(width: width))
        let result = try #require(converter.convert(source))
        let flat = displayPixel(result.display, x: 0)
        for x in 0..<width {
            // a difference here means the row padding reached the picture
            #expect(displayPixel(result.display, x: x) == flat,
                    "pixel \(x) differs from the flat picture")
        }
    }

    /// A stride too short for whole blocks is refused rather than read past the
    /// end of each row. Synthetic only — a real board always sends whole blocks.
    @Test func aFrameWithTooShortAStrideIsRefused() throws {
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferBytesPerRowAlignmentKey: 4] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, 6, 4,
                            V210Packing.pixelFormat, attrs, &out)
        // CoreVideo pads generously, so this normally succeeds; the guard is
        // still what protects a buffer that arrives with a tight stride
        if let buffer = out,
           CVPixelBufferGetBytesPerRow(buffer)
            < V210Packing.blockRowBytes(width: 6) {
            #expect(TenBitYUVConverter().convert(buffer) == nil)
        }
    }
}

/// The YCbCr → R'G'B' matrix on its own, against numbers derived from the
/// standard rather than from the implementation.
///
/// It is a colour-space change and NOT a levels stage, which is the design claim
/// that lets a 10-bit YCbCr source and a 10-bit RGB source share one display
/// table. The identity test below is what that claim reduces to.
struct WireYCbCrTests {
    /// A neutral pixel comes out `R = G = B = Y`, exactly, at every code and in
    /// both modes. This is what makes a grey 'v210' frame and a grey 'r210' frame
    /// the same picture on the monitor — and it holds because the matrix scales
    /// only the chroma DIFFERENCES, which are zero here.
    @Test func aNeutralPixelIsGreyAtEveryCode() {
        for studioSwing in [true, false] {
            let matrix = WireYCbCr(studioSwing: studioSwing)
            for code in 0...V210Packing.maxCode {
                let rgb = matrix.rgb(luma: code, cb: 512, cr: 512)
                #expect(rgb.r == code && rgb.g == code && rgb.b == code,
                        "studioSwing \(studioSwing) code \(code): \(rgb)")
            }
        }
    }

    /// The Rec.709 colour bars, encoded by hand from the standard's own
    /// definitions and decoded back. ±2 because the fixture's own codes are
    /// rounded to integers before they get here, not because the matrix is
    /// approximate.
    @Test func theStandardColourBarsInvert() {
        let matrix = WireYCbCr(studioSwing: true)
        // (luma, cb, cr) → expected (r, g, b), all in 10-bit studio-swing codes
        let bars: [(V210Packing.Pixel, WireYCbCr.RGB)] = [
            (.init(luma: 940, cb: 512, cr: 512), .init(r: 940, g: 940, b: 940)),
            (.init(luma: 64, cb: 512, cr: 512), .init(r: 64, g: 64, b: 64)),
            // 100 % blue: Y' = 0.0722, Cb = +0.5, Cr = −0.0722/1.5748
            (.init(luma: 127, cb: 960, cr: 471), .init(r: 64, g: 64, b: 940)),
            // 100 % red: Y' = 0.2126, Cb = −0.2126/1.8556, Cr = +0.5
            (.init(luma: 250, cb: 409, cr: 960), .init(r: 940, g: 64, b: 64)),
            // 100 % green: Y' = 0.7152
            (.init(luma: 691, cb: 167, cr: 105), .init(r: 64, g: 940, b: 64)),
        ]
        for (wire, expected) in bars {
            let rgb = matrix.rgb(luma: wire.luma, cb: wire.cb, cr: wire.cr)
            #expect(abs(rgb.r - expected.r) <= 2, "\(wire) → \(rgb), want \(expected)")
            #expect(abs(rgb.g - expected.g) <= 2, "\(wire) → \(rgb), want \(expected)")
            #expect(abs(rgb.b - expected.b) <= 2, "\(wire) → \(rgb), want \(expected)")
        }
    }

    /// The two modes differ only in the chroma gain, and the ratio is the one the
    /// coding ranges dictate: 876 luma counts against 896 chroma counts.
    @Test func theModesDifferOnlyInTheChromaGain() {
        #expect(WireYCbCr(studioSwing: false).chromaGain == 1)
        let studio = WireYCbCr(studioSwing: true).chromaGain
        #expect(abs(studio - 876.0 / 896.0) < 1e-12)
        // and the difference is real but small — a strong chroma difference moves
        // by about two percent of itself between the modes. Well inside the range
        // at both ends, or the clamp would hide the whole effect.
        let limited = WireYCbCr(studioSwing: true).rgb(luma: 200, cb: 800, cr: 512)
        let full = WireYCbCr(studioSwing: false).rgb(luma: 200, cb: 800, cr: 512)
        #expect(full.b > limited.b, "limited \(limited.b) full \(full.b)")
        #expect(full.b < V210Packing.maxCode, "the comparison hit the clamp")
        #expect(full.b - limited.b < 30, "limited \(limited.b) full \(full.b)")
    }

    /// The chroma difference the scopes are handed is measured in LUMA counts, so
    /// the accumulator's own gain lands it on the full-range scale exactly. Zero
    /// chroma is zero difference — a neutral frame must plot at the centre of the
    /// vectorscope and not near it.
    @Test func theChromaDifferenceIsMeasuredInLumaCounts() {
        let matrix = WireYCbCr(studioSwing: true)
        let neutral = matrix.chromaDifference(cb: 512, cr: 512)
        #expect(neutral.cb == 0 && neutral.cr == 0)
        // a full-scale chroma excursion, through the scopes' own gain, reaches
        // the full-range half-scale the graticule targets are placed on
        let saturated = matrix.chromaDifference(cb: 960, cr: 512)
        let plotted = saturated.cb * ScopeWireLevels.limited.chromaGain
        #expect(abs(plotted - 1023.0 / 2) < 1.0, "plotted at \(plotted)")
    }
}
