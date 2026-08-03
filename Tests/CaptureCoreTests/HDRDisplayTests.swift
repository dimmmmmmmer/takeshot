import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// How an HDR signal reaches the monitor: through the SAME `WireDisplayTable`
/// every other signal goes through, with a different curve in it.
///
/// The two halves of this suite are the two promises the design makes. First,
/// that an SDR signal is untouched — not "equivalent", byte-identical, at every
/// depth and in both levels modes. Second, that an HDR signal comes out of all
/// three converters as the same picture, which is the same three-way agreement
/// the project already holds for SDR, one range wider.
struct HDRDisplayTests {
    private static let pq = WireColorimetry(transfer: .pq, primaries: .rec2020)

    // MARK: - the SDR promise

    /// The HDR entry point returns the SDR table UNCHANGED for an SDR signal.
    /// Every depth, both levels modes, entry for entry.
    @Test func sdrGetsExactlyTheTableItAlwaysGot() {
        for bits in [8, 10, 12] {
            for levels in InputLevels.allCases {
                let plain = WireDisplayTable.expand(levels: levels, bits: bits)
                let asked = WireDisplayTable.table(levels: levels, bits: bits,
                                                   transfer: .sdr)
                #expect(plain == asked,
                        "\(bits)-bit \(levels.rawValue) drifted")
            }
        }
    }

    /// And a converter told it is SDR produces the same pixels as one that was
    /// never told anything at all — the state a build without HDR was in.
    @Test func tellingAConverterItIsSDRChangesNoPixel() throws {
        let source = try Self.makeR210(width: 64, height: 4) { x, _ in x * 16 }
        let untouched = TenBitConverter()
        untouched.setLevels(.limited)
        let told = TenBitConverter()
        told.setLevels(.limited)
        told.setColorimetry(.sdr)
        let a = try #require(untouched.convert(source))
        let b = try #require(told.convert(source))
        #expect(Self.greenRow(a.display, y: 1) == Self.greenRow(b.display, y: 1))
    }

    // MARK: - the HDR table

    /// The table is monotonic and spans the display scale, at both wire depths.
    /// A tone map that is not monotonic is a contour in the picture.
    ///
    /// The top of the scale is approached rather than reached, and that is the
    /// shoulder doing exactly what it was built to do: it asymptotes, so
    /// nothing an HDR camera can send comes out as flat clipped white. The gap
    /// is one 10-bit code for PQ and six for HLG (whose peak is its 1000 cd/m²
    /// reference display rather than PQ's 10 000) — in the 8 bits the display
    /// buffer holds, 255 and 254.
    @Test func theHDRTableIsMonotonicAndReachesTheTopOfTheScale() {
        for bits in [10, 12] {
            for transfer in [SignalTransfer.pq, .hlg] {
                let table = WireDisplayTable.table(levels: .limited, bits: bits,
                                                   transfer: transfer)
                let top = (1 << bits) - 1
                let label = "\(bits)-bit \(transfer.rawValue)"
                #expect(table.count == 1 << bits, "\(label) has \(table.count) entries")
                #expect(table.first == 0, "\(label) starts at \(String(describing: table.first))")
                let last = Int(table[table.count - 1])
                #expect(top - last <= top / 128,
                        "\(label) topped out at \(last) of \(top)")
                #expect(last >> (bits - 8) >= 254,
                        "\(label) shows white at \(last >> (bits - 8)) of 255")
                for index in 1..<table.count {
                    #expect(table[index] >= table[index - 1],
                            "\(label) went backwards at \(index)")
                }
            }
        }
    }

    /// Nominal black is black, and the codes outside the nominal pair clip
    /// against the ends — the same rule the SDR table follows, and for the same
    /// reason: the excursions are in the file and on the scopes, which read the
    /// wire.
    @Test func theExcursionsClipAgainstTheEndsExactlyAsInSDR() {
        let table = WireDisplayTable.table(levels: .limited, bits: 10,
                                           transfer: .pq)
        #expect(table[64] == 0, "nominal black at \(table[64])")
        #expect(table[4] == 0, "the footroom did not clip: \(table[4])")
        let white = table[940], headroom = table[1019]
        #expect(white == headroom,
                "the headroom did not clip onto nominal white: \(white)/\(headroom)")
        #expect(Int(white) >> 2 == 255,
                "nominal white shows at \(Int(white) >> 2) of 255")
    }

    /// The measurement the whole display half rests on, in the codes an
    /// operator actually looks at: an 18 % grey card lands in the same place on
    /// the monitor whether the camera is sending Rec.709 or PQ.
    ///
    /// BT.2408 grades that card to 26 cd/m² under PQ; a Rec.709 camera codes it
    /// through its own OETF. Both are turned into wire codes here and run
    /// through their own display tables, and the two 8-bit results are compared.
    @Test func aGreyCardLandsInTheSamePlaceUnderPQAsUnderRec709() {
        let sdrTable = WireDisplayTable.table(levels: .limited, bits: 10,
                                              transfer: .sdr)
        let pqTable = WireDisplayTable.table(levels: .limited, bits: 10,
                                             transfer: .pq)
        // Rec.709 camera signal for 18% scene reflectance, as a studio-swing
        // 10-bit wire code
        let sdrSignal = 1.099 * pow(0.18, 0.45) - 0.099
        let sdrCode = Int((64 + sdrSignal * 876).rounded())
        // the same card under PQ, graded to BT.2408's 26 cd/m²
        let pqCode = Int((64 + HDRTransfer
            .pqSignal(HDRTransfer.referenceGreyNits) * 876).rounded())
        let sdrShown = Int(sdrTable[sdrCode]) >> 2
        let pqShown = Int(pqTable[pqCode]) >> 2
        #expect(abs(sdrShown - pqShown) <= 6,
                "SDR grey shows at \(sdrShown), PQ grey at \(pqShown)")
    }

    /// Diffuse white and the specular range above it are all distinguishable on
    /// an 8-bit monitor — which is the whole point of the shoulder. Without it
    /// everything from 203 cd/m² up would be one flat white.
    @Test func theSpecularRangeIsStillVisibleAboveDiffuseWhite() {
        let table = WireDisplayTable.table(levels: .limited, bits: 10,
                                           transfer: .pq)
        func shown(_ nits: Double) -> Int {
            let code = Int((64 + HDRTransfer.pqSignal(nits) * 876).rounded())
            return Int(table[code]) >> 2
        }
        let white = shown(HDRTransfer.referenceWhiteNits)
        #expect(white >= 238 && white <= 248, "diffuse white at \(white)")
        #expect(shown(400) > white, "400 cd/m² did not clear diffuse white")
        #expect(shown(1000) > shown(400), "1000 did not clear 400")
        #expect(shown(4000) > shown(1000), "4000 did not clear 1000")
    }

    /// An HLG signal and a PQ signal of the same scene reach the monitor at the
    /// same code — BT.2100's two encodings of one picture, and the reason this
    /// app can afford a single display transform for both.
    @Test func hlgAndPQShowTheSamePictureAtTheSameCode() {
        let pqTable = WireDisplayTable.table(levels: .limited, bits: 10,
                                             transfer: .pq)
        let hlgTable = WireDisplayTable.table(levels: .limited, bits: 10,
                                              transfer: .hlg)
        for nits in [1.0, HDRTransfer.referenceGreyNits, 100.0,
                     HDRTransfer.referenceWhiteNits, 400.0, 1000.0] {
            let pqCode = Int((64 + HDRTransfer.pqSignal(nits) * 876).rounded())
            let hlgCode = Int((64 + HDRTransfer.hlgSignal(forNits: nits) * 876)
                .rounded())
            let pqShown = Int(pqTable[pqCode]) >> 2
            let hlgShown = Int(hlgTable[hlgCode]) >> 2
            #expect(abs(pqShown - hlgShown) <= 2,
                    "\(nits) cd/m²: PQ \(pqShown), HLG \(hlgShown)")
        }
    }

    // MARK: - the three converters

    /// All three wire formats show the same PQ picture, which is the property
    /// the project already holds for SDR — no two depths and no two samplings
    /// may drift into showing different blacks, and HDR does not get an
    /// exemption from that.
    @Test func allThreeConvertersShowTheSameHDRPicture() throws {
        let codes = [64, 200, 400, 573, 700, 940]
        let tenBit = TenBitConverter()
        tenBit.setLevels(.limited)
        tenBit.setColorimetry(Self.pq)
        let twelveBit = TwelveBitConverter()
        twelveBit.setLevels(.limited)
        twelveBit.setColorimetry(Self.pq)
        let yuv = TenBitYUVConverter()
        yuv.setLevels(.limited)
        yuv.setColorimetry(Self.pq)
        for code in codes {
            let r210 = try Self.makeR210(width: 12, height: 2) { _, _ in code }
            let r12b = try R12BFixtures.makeGrey(width: 16, height: 2) { _, _ in
                code << 2
            }
            let v210 = try V210Fixtures.makeGrey(width: 12, height: 2) { _, _ in
                code
            }
            let a = Self.greenRow(try #require(tenBit.convert(r210)).display,
                                  y: 1)[2]
            let b = Self.greenRow(try #require(twelveBit.convert(r12b)).display,
                                  y: 1)[2]
            let c = Self.greenRow(try #require(yuv.convert(v210)).display,
                                  y: 1)[2]
            #expect(abs(a - b) <= 1 && abs(a - c) <= 1,
                    "code \(code): r210 \(a), R12B \(b), v210 \(c)")
        }
    }

    /// The record product is untouched by HDR at every depth: the wire-code
    /// rule does not care what a code means, so a PQ take carries exactly the
    /// codes an SDR one would.
    @Test func theRecordProductIsIdenticalUnderHDR() throws {
        let source = try Self.makeR210(width: 64, height: 4) { x, _ in x * 16 }
        let sdr = TenBitConverter()
        sdr.setLevels(.limited)
        let hdr = TenBitConverter()
        hdr.setLevels(.limited)
        hdr.setColorimetry(Self.pq)
        let a = try #require(sdr.convert(source)).record
        let b = try #require(hdr.convert(source)).record
        #expect(Self.r210Row(a, y: 1) == Self.r210Row(b, y: 1))
        // …and the file's own statement about its levels is unchanged too
        #expect(sdr.recordNeedsPlaybackExpansion
            == hdr.recordNeedsPlaybackExpansion)
    }

    /// A Rec.2020 YCbCr signal is matrixed with Rec.2020's weights, not
    /// Rec.709's. A neutral pixel comes out neutral under both — that is the
    /// property the shared display table needs — but a saturated one does not,
    /// and the difference is what would have been a hue error on every face.
    @Test func rec2020YCbCrUsesItsOwnMatrix() {
        let seven = WireYCbCr(studioSwing: true, primaries: .rec709)
        let twenty = WireYCbCr(studioSwing: true, primaries: .rec2020)
        for luma in [64, 300, 512, 700, 940] {
            let a = seven.rgb(luma: luma, cb: 512, cr: 512)
            let b = twenty.rgb(luma: luma, cb: 512, cr: 512)
            #expect(a == b, "neutral drifted at luma \(luma)")
            #expect(a.r == luma && a.g == luma && a.b == luma)
        }
        // a saturated red: Rec.2020's Cr span is narrower, so the same code is
        // a different colour and the matrices must not agree
        let a = seven.rgb(luma: 500, cb: 400, cr: 800)
        let b = twenty.rgb(luma: 500, cb: 400, cr: 800)
        #expect(a != b, "the two matrices agreed on a saturated pixel: \(a)")
        #expect(abs(a.r - b.r) > 10, "Rec.2020 red barely moved: \(a) vs \(b)")
    }

    // MARK: - fixtures

    private static func makeR210(width: Int, height: Int,
                                 code: (_ x: Int, _ y: Int) -> Int) throws
        -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            TenBitConverter.r210,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]]
                                as CFDictionary, &out)
        let buffer = try #require(out)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                let value = UInt32(code(x, y) & 0x3FF)
                row[x] = ((value << 20) | (value << 10) | value).bigEndian
            }
        }
        return buffer
    }

    /// The green channel of one BGRA row — the channel that carries the luma,
    /// and the one the grey fixtures make equal to the other two.
    private static func greenRow(_ buffer: CVPixelBuffer, y: Int) -> [Int] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
            .assumingMemoryBound(to: UInt8.self)
        return (0..<CVPixelBufferGetWidth(buffer)).map { Int(row[$0 * 4 + 1]) }
    }

    private static func r210Row(_ buffer: CVPixelBuffer, y: Int) -> [UInt32] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
            .assumingMemoryBound(to: UInt32.self)
        return (0..<CVPixelBufferGetWidth(buffer)).map { row[$0] }
    }
}
