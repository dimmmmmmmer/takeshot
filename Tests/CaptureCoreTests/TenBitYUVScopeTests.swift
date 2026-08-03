import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The scopes reading a 10-bit YCbCr wire frame.
///
/// `ScopeWireTests` pins the same properties for `'r210'` and `TwelveBitScopeTests`
/// for `'R12B'`; this is the third wire reader, and the one whose depth matches
/// the analyzer's own sample scale exactly. Nothing is widened from 8 bits and
/// nothing is narrowed from 12 — a code the camera sent is the code on the trace,
/// which is the only format about which that is true.
struct TenBitYUVScopeTests {
    /// The rows the luma trace occupies, top first.
    private func traceRows(_ data: ScopeData) -> [Int] {
        let width = ScopeData.waveWidth
        return (0..<ScopeData.waveHeight).filter { row in
            (0..<width).contains { data.waveformY[row * width + $0] > 0 }
        }
    }

    /// Where the trace's centre of mass sits, 0 = top row, 1 = bottom.
    private func traceUnit(_ data: ScopeData) -> Double {
        let rows = traceRows(data)
        guard !rows.isEmpty else { return .nan }
        let mid = Double(rows.reduce(0, +)) / Double(rows.count)
        return mid / Double(ScopeData.waveHeight - 1)
    }

    private func analyzed(_ luma: Int, cb: Int = V210Fixtures.chromaZero,
                          cr: Int = V210Fixtures.chromaZero,
                          levels: ScopeWireLevels = .limited) throws -> ScopeData {
        let frame = try V210Fixtures.makeV210(width: 336, height: 180) { _, _ in
            V210Fixtures.Sample(luma: luma, cb: cb, cr: cr)
        }
        return try #require(ScopeAnalyzer.analyze(frame, wireLevels: levels),
                            "the analyzer refused a 'v210' frame")
    }

    /// The analyzer accepts the format at all — a missing case in that switch
    /// means the scopes go blank the moment 10-bit YUV capture is switched on,
    /// which since it is now the DEFAULT would be most rigs.
    @Test func theAnalyzerReadsTheTenBitYUVWireFormat() throws {
        let data = try analyzed(V210Fixtures.midGrey)
        #expect(!traceRows(data).isEmpty, "no trace at all")
    }

    /// Nominal black and white land on the graticule's own 0 % and 100 % lines —
    /// the same lines an `'r210'` source's 64 and 940 land on, because they ARE
    /// 64 and 940.
    @Test func nominalBlackAndWhiteLandOnTheNominalLines() throws {
        let black = try analyzed(V210Fixtures.nominalBlack)
        #expect(abs(traceUnit(black) - black.nominal.black) < 0.01,
                "black at \(traceUnit(black)), line at \(black.nominal.black)")
        let white = try analyzed(V210Fixtures.nominalWhite)
        #expect(abs(traceUnit(white) - white.nominal.white) < 0.01,
                "white at \(traceUnit(white)), line at \(white.nominal.white)")
    }

    /// A camera riding its blacks to code 4 draws BELOW the 0 % line and a
    /// highlight at 1019 draws ABOVE 100 % — which is what the operator opens a
    /// scope to look for, and what the display buffer has already clipped.
    @Test func theLegalExcursionsDrawOutsideTheNominalLines() throws {
        let footroom = try analyzed(V210Fixtures.footroom)
        let lowLine = footroom.nominal.black
        #expect(traceUnit(footroom) > lowLine + 0.01,
                "footroom at \(traceUnit(footroom)), 0 % line at \(lowLine)")
        let headroom = try analyzed(V210Fixtures.headroom)
        let highLine = headroom.nominal.white
        #expect(traceUnit(headroom) < highLine - 0.01,
                "headroom at \(traceUnit(headroom)), 100 % at \(highLine)")
    }

    /// Detail the 8-bit display buffer could not have carried — and, for this
    /// format, detail an 8-bit '2vuy' CAPTURE could not have carried either, which
    /// is the whole reason this wave exists. Codes 500 and 502 are the same byte
    /// once a frame has been through 8 bits.
    @Test func theWireTapSeesDetailAnEightBitCaptureWouldHaveLost() throws {
        #expect(500 >> 2 == 502 >> 2) // the premise
        let lower = try analyzed(500, levels: .full)
        let higher = try analyzed(502, levels: .full)
        #expect(traceUnit(lower) != traceUnit(higher),
                "both traces sit at \(traceUnit(lower)); bits were dropped")
        #expect(traceUnit(higher) < traceUnit(lower),
                "the higher code drew lower down the map")
    }

    /// The YCbCr reader and the RGB one agree about the same scene: a neutral
    /// YCbCr pixel is R = G = B = Y exactly, so the two must put the trace in the
    /// same place. This is what keeps the scopes from jumping when the operator
    /// switches a rig from an RGB feed to an SDI one.
    @Test func theYCbCrReaderAgreesWithTheTenBitRGBOne() throws {
        for code in [4, 64, 500, 940, 1019] {
            let yuv = try analyzed(code)
            var out: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 336, 180,
                                TenBitConverter.r210,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                &out)
            let r210 = try #require(out)
            CVPixelBufferLockBaseAddress(r210, [])
            let base = try #require(CVPixelBufferGetBaseAddress(r210))
            let rowBytes = CVPixelBufferGetBytesPerRow(r210)
            for y in 0..<180 {
                let row = base.advanced(by: y * rowBytes)
                    .assumingMemoryBound(to: UInt32.self)
                let value = UInt32(code)
                for x in 0..<336 {
                    row[x] = ((value << 20) | (value << 10) | value).bigEndian
                }
            }
            CVPixelBufferUnlockBaseAddress(r210, [])
            let rgb = try #require(ScopeAnalyzer.analyze(r210, wireLevels: .limited))
            #expect(abs(traceUnit(yuv) - traceUnit(rgb)) < 0.005,
                    "code \(code): YCbCr \(traceUnit(yuv)) vs RGB \(traceUnit(rgb))")
        }
    }

    /// The vectorscope plots a neutral frame at its centre, and a saturated one
    /// out at the radius the graticule targets sit on. The chroma travels as a
    /// difference measured in luma counts and the accumulator applies its own
    /// gain — a double-scaled or unscaled path would put a 100 % bar visibly
    /// inside or outside its box.
    @Test func theVectorscopeIsCentredOnNeutralAndReachesTheTargets() throws {
        let size = ScopeData.vectorSize
        func centreOfMass(_ data: ScopeData) -> (x: Double, y: Double) {
            var totalX = 0.0, totalY = 0.0, weight = 0.0
            for y in 0..<size {
                for x in 0..<size {
                    let value = Double(data.vector[y * size + x])
                    guard value > 0 else { continue }
                    totalX += Double(x) * value
                    totalY += Double(y) * value
                    weight += value
                }
            }
            guard weight > 0 else { return (.nan, .nan) }
            return (totalX / weight, totalY / weight)
        }
        let neutral = centreOfMass(try analyzed(V210Fixtures.midGrey))
        #expect(abs(neutral.x - Double(size) / 2) < 2, "Cb at \(neutral.x)")
        #expect(abs(neutral.y - Double(size) / 2) < 2, "Cr at \(neutral.y)")
        // 100 % blue: Cb at the top of its range, so the trace sits far to the
        // RIGHT of centre (x = Cb, right = positive) and slightly below it
        let blue = centreOfMass(try analyzed(127, cb: 960, cr: 471))
        #expect(blue.x > Double(size) * 0.85, "Cb only reached \(blue.x)")
        #expect(blue.y > Double(size) / 2, "Cr went the wrong way: \(blue.y)")
    }

    /// A stride too short for whole blocks is refused rather than read past the
    /// end of each row. Synthetic only — a real board always sends whole blocks.
    @Test func aFrameWithTooShortAStrideIsRefused() throws {
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferBytesPerRowAlignmentKey: 4] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, 6, 4,
                            V210Packing.pixelFormat, attrs, &out)
        if let buffer = out,
           CVPixelBufferGetBytesPerRow(buffer)
            < V210Packing.blockRowBytes(width: 6) {
            #expect(ScopeAnalyzer.analyze(buffer) == nil)
        }
    }
}
