import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The scopes reading a 12-bit wire frame.
///
/// `ScopeWireTests` pins the same properties for 'r210'; this is the sibling
/// reader, and the point of it is that the analyzer sees the frame BEFORE the
/// split — so nothing has been quantized to 256 levels and nothing outside the
/// nominal pair has been clamped away.
///
/// One thing is deliberately NOT claimed here: that the traces resolve 4096
/// distinct levels. The analyzer's sample scale is 10-bit and its maps are 512
/// rows and 256 histogram bins, so it cannot display more than about nine bits
/// however many it is handed — `ScopeAnalyzer.narrowed` rounds onto that scale
/// and the doc comment there says why. What IS claimed, and tested, is that the
/// reference codes stay exact, the excursions stay outside the nominal lines,
/// and detail an 8-bit display buffer would have thrown away survives.
struct TwelveBitScopeTests {
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

    private func analyzed(_ code: Int,
                          levels: ScopeWireLevels = .limited) throws -> ScopeData {
        let frame = try R12BFixtures.makeGrey(width: 320, height: 180) { _, _ in code }
        return try #require(ScopeAnalyzer.analyze(frame, wireLevels: levels),
                            "the analyzer refused an 'R12B' frame")
    }

    /// The analyzer accepts the format at all — a missing case in that switch
    /// means the scopes go blank the moment 12-bit capture is switched on.
    @Test func theAnalyzerReadsTheTwelveBitWireFormat() throws {
        let data = try analyzed(R12BFixtures.midGrey)
        #expect(!traceRows(data).isEmpty, "no trace at all")
    }

    /// Nominal black and white land on the graticule's own 0 % and 100 % lines.
    /// 12-bit studio swing is 256/3760, and those must map to the SAME lines a
    /// 10-bit source's 64/940 map to, or the scale lies.
    @Test func nominalBlackAndWhiteLandOnTheNominalLines() throws {
        let black = try analyzed(R12BFixtures.nominalBlack)
        #expect(abs(traceUnit(black) - black.nominal.black) < 0.01,
                "black at \(traceUnit(black)), line at \(black.nominal.black)")
        let white = try analyzed(R12BFixtures.nominalWhite)
        #expect(abs(traceUnit(white) - white.nominal.white) < 0.01,
                "white at \(traceUnit(white)), line at \(white.nominal.white)")
    }

    /// A camera riding its blacks to code 16 draws BELOW the 0 % line, and a
    /// highlight at 4079 draws ABOVE 100 % — which is what the operator opens a
    /// scope to look for and what the display buffer has already clipped.
    @Test func theLegalExcursionsDrawOutsideTheNominalLines() throws {
        let footroom = try analyzed(R12BFixtures.footroom)
        let lowLine = footroom.nominal.black
        #expect(traceUnit(footroom) > lowLine + 0.01,
                "footroom at \(traceUnit(footroom)), 0 % line at \(lowLine)")
        let headroom = try analyzed(R12BFixtures.headroom)
        let highLine = headroom.nominal.white
        #expect(traceUnit(headroom) < highLine - 0.01,
                "headroom at \(traceUnit(headroom)), 100 % at \(highLine)")
    }

    /// Detail the 8-bit display buffer could not have carried.
    ///
    /// 2048 and 2056 are the same byte once a frame has been quantized to 8
    /// bits, so a scope reading the display buffer cannot tell them apart. Off
    /// the wire they land on different trace rows.
    @Test func theWireTapSeesDetailTheDisplayBufferWouldHaveLost() throws {
        // the premise: these two ARE the same 8-bit code
        #expect(2048 >> 4 == 2056 >> 4)
        let lower = try analyzed(2048, levels: .full)
        let higher = try analyzed(2056, levels: .full)
        #expect(traceUnit(lower) != traceUnit(higher),
                "both traces sit at \(traceUnit(lower)); bits were dropped")
        // higher code draws higher up the map (smaller unit)
        #expect(traceUnit(higher) < traceUnit(lower))
    }

    /// The 12-bit and 10-bit readers agree about the same scene: a 12-bit code
    /// is its 10-bit code times four, and both must put the trace in the same
    /// place. This is what keeps the scopes from jumping when the operator
    /// changes capture depth mid-setup.
    @Test func theTwelveBitReaderAgreesWithTheTenBitOne() throws {
        for tenBitCode in [4, 64, 500, 940, 1019] {
            let twelve = try analyzed(tenBitCode << 2)
            var out: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 320, 180,
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
                let value = UInt32(tenBitCode)
                for x in 0..<320 {
                    row[x] = ((value << 20) | (value << 10) | value).bigEndian
                }
            }
            CVPixelBufferUnlockBaseAddress(r210, [])
            let ten = try #require(ScopeAnalyzer.analyze(r210, wireLevels: .limited))
            let twelveUnit = traceUnit(twelve), tenUnit = traceUnit(ten)
            #expect(abs(twelveUnit - tenUnit) < 0.005,
                    "code \(tenBitCode): 12-bit \(twelveUnit) vs \(tenUnit)")
        }
    }

    /// The reference codes narrow onto the 10-bit scale EXACTLY, which is what
    /// makes the graticule honest. Rounding rather than truncating is the whole
    /// reason: `3760 >> 2` is 940 either way, but `16 >> 2` is 4 only because of
    /// the round, and a truncating narrow would bias every code downwards.
    @Test func theNarrowingKeepsTheReferenceCodesExact() {
        #expect(ScopeAnalyzer.narrowed(R12BFixtures.nominalBlack) == 64)
        #expect(ScopeAnalyzer.narrowed(R12BFixtures.nominalWhite) == 940)
        #expect(ScopeAnalyzer.narrowed(R12BFixtures.footroom) == 4)
        #expect(ScopeAnalyzer.narrowed(0) == 0)
        // the top of the 12-bit scale cannot overflow the 10-bit sample scale
        #expect(ScopeAnalyzer.narrowed(R12BPacking.maxCode) == 1023)
        // unbiased: rounding, not truncation
        #expect(ScopeAnalyzer.narrowed(2) == 1)
        #expect(ScopeAnalyzer.narrowed(1) == 0)
    }

    /// A stride too short for whole blocks is refused rather than read past the
    /// end of each row. Synthetic only — a real board always sends whole blocks.
    @Test func aFrameWithTooShortAStrideIsRefused() throws {
        // 32BGRA at width 8 gives 32 bytes a row, where an 'R12B' row of 8
        // pixels needs 36 — the analyzer must not read it as 12-bit
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferBytesPerRowAlignmentKey: 4] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 4,
                            R12BPacking.pixelFormat, attrs, &out)
        // CoreVideo pads generously, so this normally succeeds; the guard is
        // still what protects a buffer that arrives with a tight stride
        if let buffer = out,
           CVPixelBufferGetBytesPerRow(buffer)
            < R12BPacking.blockRowBytes(width: 8) {
            #expect(ScopeAnalyzer.analyze(buffer) == nil)
        }
    }
}
