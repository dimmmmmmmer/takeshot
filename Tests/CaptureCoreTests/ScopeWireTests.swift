import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The scopes reading the 10-bit wire instead of the 8-bit display buffer.
///
/// Two separate complaints, one tap. The parades looked "8-bit and undetailed"
/// because they WERE 8-bit — a 10-bit source quantized to 256 levels on its way
/// into the display buffer, and then onto a 256-row trace map, which is a
/// staircase however good the camera is. And the shadows and highlights looked
/// slightly clipped because they were: the expansion onto 64…940 clamped
/// everything outside it before the scopes ever saw it.
///
/// The display buffer still clamps them, and now deliberately: it is expanded
/// on the nominal pair so that black is black on the monitor. That decision is
/// exactly why the tap is not redundant, and the tests below say so in numbers
/// — off the display buffer the footroom does not exist at all, and a
/// full-range buffer cannot tell a scope WHERE nominal black and white are.
struct ScopeWireTests {
    private func r210(width: Int = 320, height: Int = 180,
                      code: (_ x: Int) -> Int) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            TenBitConverter.r210,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        let buffer = try #require(out)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes)
                .assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                let value = UInt32(code(x) & 0x3FF)
                row[x] = ((value << 20) | (value << 10) | value).bigEndian
            }
        }
        return buffer
    }

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

    // MARK: - the excursions exist again

    /// Nominal black and white land on the graticule's own 0 % and 100 %
    /// lines — the scale is only honest if the reference codes sit on it.
    @Test func nominalBlackAndWhiteLandOnTheNominalLines() throws {
        let black = try #require(ScopeAnalyzer.analyze(
            try r210 { _ in 64 }, wireLevels: .limited))
        #expect(abs(traceUnit(black) - black.nominal.black) < 0.01,
                "black at \(traceUnit(black)), line at \(black.nominal.black)")
        let white = try #require(ScopeAnalyzer.analyze(
            try r210 { _ in 940 }, wireLevels: .limited))
        #expect(abs(traceUnit(white) - white.nominal.white) < 0.01,
                "white at \(traceUnit(white)), line at \(white.nominal.white)")
    }

    /// The whole point: a camera riding its blacks to code 4 draws BELOW the
    /// 0 % line, and a highlight at 1019 draws ABOVE 100 %.
    @Test func theLegalExcursionsDrawOutsideTheNominalLines() throws {
        let subBlack = try #require(ScopeAnalyzer.analyze(
            try r210 { _ in 4 }, wireLevels: .limited))
        let low = "\(traceUnit(subBlack)) vs line \(subBlack.nominal.black)"
        #expect(traceUnit(subBlack) > subBlack.nominal.black + 0.02,
                "the sub-black is not below the 0 % line: \(low)")
        let superWhite = try #require(ScopeAnalyzer.analyze(
            try r210 { _ in 1019 }, wireLevels: .limited))
        let high = "\(traceUnit(superWhite)) vs line \(superWhite.nominal.white)"
        #expect(traceUnit(superWhite) < superWhite.nominal.white - 0.02,
                "the super-white is not above the 100 % line: \(high)")
        #expect(subBlack.nominal.showsExcursions)
    }

    /// Why the tap exists at all, stated as a measurement rather than as a
    /// claim in a comment: the display buffer does not contain the excursions.
    ///
    /// It is expanded on the nominal pair, so code 4 and code 64 are the same
    /// pixel in it — a scope reading the display buffer would show the operator
    /// a clean black where the camera is riding sixty codes below picture
    /// black. It also carries no nominal reference, so such a scope could draw
    /// no 0 % and 100 % lines to judge against.
    @Test func theDisplayBufferHasNoExcursionsLeftToMeasure() throws {
        let converter = TenBitConverter() // limited is the default
        let atFour = try #require(converter.convert(try r210 { _ in 4 }))
        let atSixtyFour = try #require(converter.convert(try r210 { _ in 64 }))
        let low = try #require(ScopeAnalyzer.analyze(atFour.display))
        let black = try #require(ScopeAnalyzer.analyze(atSixtyFour.display))

        #expect(!low.nominal.showsExcursions,
                "a full-range buffer must not claim excursion room")
        #expect(low.nominal.black == black.nominal.black)
        let shown = "\(traceUnit(low)) vs \(traceUnit(black))"
        #expect(traceUnit(low) == traceUnit(black),
                "the display buffer still holds the footroom: \(shown)")
        // …while the wire, which is what the scopes actually read, keeps the
        // whole 60 codes of it
        let wireLow = try #require(ScopeAnalyzer.analyze(try r210 { _ in 4 },
                                                         wireLevels: .limited))
        let wireBlack = try #require(ScopeAnalyzer.analyze(try r210 { _ in 64 },
                                                           wireLevels: .limited))
        let measured = "\(traceUnit(wireLow)) vs \(traceUnit(wireBlack))"
        #expect(traceUnit(wireLow) > traceUnit(wireBlack) + 0.02,
                "the wire lost the footroom too: \(measured)")
    }

    // MARK: - the detail that was quantized away

    /// How many distinct heights the trace takes across the frame — the number
    /// of steps in the staircase, which is what "undetailed" means when you are
    /// looking at one.
    ///
    /// Not the number of occupied ROWS: the accumulator joins adjacent columns
    /// with a segment, so a coarse trace and a fine one over the same signal
    /// cover the same span. What separates them is how many times the trace
    /// changes height on the way across.
    private func traceSteps(_ data: ScopeData) -> Int {
        let width = ScopeData.waveWidth
        var heights: Set<Int> = []
        for col in 0..<width {
            let top = (0..<ScopeData.waveHeight).first {
                data.waveformY[$0 * width + col] > 0
            }
            if let top { heights.insert(top) }
        }
        return heights.count
    }

    /// A shallow 10-bit gradient — the near-flat sky an operator judges banding
    /// on. Read off the wire it draws twice as many steps as the same content
    /// read off the 8-bit display buffer, and that is the ceiling: the map puts
    /// two 10-bit codes on a row, and the display buffer's codes are four
    /// apart. Both halves of the change are needed to get it — a 10-bit tap
    /// into a 256-row map would quantize straight back to where it started.
    @Test func aShallowGradientKeepsItsDetailOffTheWire() throws {
        let width = 320
        // 100 codes of 10-bit swing across the frame: 25 once the display
        // buffer has divided by four
        let ramp = { (x: Int) in 500 + x * 100 / (width - 1) }
        let wire = try #require(ScopeAnalyzer.analyze(
            try r210(width: width) { ramp($0) }, wireLevels: .limited))
        let converter = TenBitConverter()
        converter.setLimitedRange(false) // full: the display buffer is a plain >>2
        let split = try #require(
            converter.convert(try r210(width: width) { ramp($0) }))
        let display = try #require(ScopeAnalyzer.analyze(split.display))

        let wireSteps = traceSteps(wire)
        let displaySteps = traceSteps(display)
        print("SCOPEDETAIL shallow gradient: wire \(wireSteps) steps, "
            + "display buffer \(displaySteps) steps")
        let counts = "\(wireSteps) vs \(displaySteps)"
        #expect(wireSteps > displaySteps * 3 / 2,
                "the wire tap gained no vertical detail: \(counts)")
        // the two cover the same range of values — this is about detail inside
        // it, not about reaching further
        let spanRatio = Double(traceRows(wire).count)
            / Double(traceRows(display).count)
        #expect(abs(spanRatio - 1) < 0.2, "the spans differ: \(spanRatio)")
    }

    /// The same, for one of the parade's channel maps.
    private func traceSteps(_ bytes: [UInt8]) -> Int {
        let width = ScopeData.waveWidth
        var heights: Set<Int> = []
        for col in 0..<width {
            let top = (0..<ScopeData.waveHeight).first {
                bytes[$0 * width + col] > 0
            }
            if let top { heights.insert(top) }
        }
        return heights.count
    }

    /// The waveform and the parade are the SAME measurement.
    ///
    /// The owner reported the parade as excellent and the waveform, beside it,
    /// as thick and hazy. This is the half of that which is not true: on a
    /// neutral signal the luma map and all three channel maps resolve the same
    /// steps over the same rows, because one accumulator writes all four in one
    /// pass. Whatever the two scopes look like, they cannot be looking at
    /// different data — which is what sent the fix to the drawing side.
    @Test func theWaveformAndTheParadeAreTheSameMeasurement() throws {
        let width = 320
        let ramp = { (x: Int) in 300 + x * 400 / (width - 1) }
        let data = try #require(ScopeAnalyzer.analyze(
            try r210(width: width) { ramp($0) }, wireLevels: .limited))
        let luma = traceSteps(data)
        for (name, map) in [("R", data.waveformR), ("G", data.waveformG),
                            ("B", data.waveformB)] {
            #expect(traceSteps(map) == luma,
                    "\(name) resolves \(traceSteps(map)) steps, luma \(luma)")
        }
        #expect(luma > 100, "a 400-code ramp resolved only \(luma) steps")
    }

    /// The map is wide enough that a waveform is not stretched across the box
    /// it is drawn in.
    ///
    /// A parade squeezes the whole map into a third of its box and is always
    /// downscaling. A waveform draws one map across all of it, so the map's
    /// width has to cover the box in DEVICE pixels or the interpolator invents
    /// the difference — which is what the thick hazy trace was. The scopes
    /// window opens at 980 pt and puts two scopes side by side, leaving 472 pt
    /// of canvas each; on the 2x display the operator is looking at that is 944
    /// pixels.
    @Test func aFullWidthWaveformGetsAMapColumnPerDevicePixel() {
        let canvasPoints = 472.0
        let retinaScale = 2.0
        let devicePixels = canvasPoints * retinaScale
        #expect(Double(ScopeData.waveWidth) >= devicePixels,
                "\(ScopeData.waveWidth) columns across \(devicePixels) pixels")
    }

    /// The map is tall enough for the signal it now carries, and wide enough
    /// for the box it is drawn in.
    ///
    /// Neither number is a style preference. A 256-row map quantizes a 10-bit
    /// code straight back to 8 bits and the tap buys nothing. And 512 columns
    /// is a downscale in a parade, which draws the map three times across a
    /// box, but a two-to-fourfold STRETCH in a waveform, which draws it once —
    /// same data, and the operator reported the waveform as thick and hazy
    /// beside a parade he was happy with. See `ScopeData.waveWidth`.
    @Test func theTraceMapIsTallEnoughForTenBitsAndWideEnoughForTheBox() {
        #expect(ScopeData.waveHeight >= 512)
        #expect(ScopeData.waveWidth == 2 * ScopeData.waveHeight)
    }

    /// The softening is vertical, 1-2-1, and there is no horizontal half.
    ///
    /// The accumulator used to integrate each difference map and then blur it
    /// twice. The vertical blur folds into the integration for free — the blur
    /// of a prefix sum is `4·I[y] − d[y] + d[y+1]`, and both differences are
    /// already in hand. The horizontal one does not fold, and it was doing no
    /// work: a sample's segment reaches back to its left-hand neighbour's
    /// value, so every column of every grid row is written and there are no
    /// horizontal gaps to close. All it did was widen the trace by a column
    /// each way — invisible in a parade, the dominant blur in a waveform.
    ///
    /// A flat frame puts its whole trace on one row, so the map has to read
    /// 1:2:1 down the three rows around it and be FLAT across them.
    @Test func theSofteningIsVerticalOnly() throws {
        let data = try #require(ScopeAnalyzer.analyze(try r210 { _ in 512 },
                                                      wireLevels: .full))
        let rows = traceRows(data)
        #expect(rows.count == 3, "rows: \(rows)")
        let width = ScopeData.waveWidth
        let column = width / 2 // interior, where a horizontal tap would be real
        let values = rows.map { Int(data.waveformY[$0 * width + column]) }
        #expect(values[1] == 255, "the centre row is the peak: \(values)")
        // the log curve turns half the density into 0.89 of the peak byte:
        // 255 * log(271) / log(541)
        #expect(abs(values[0] - 227) <= 2, "\(values)")
        #expect(values[0] == values[2], "the blur is not symmetric: \(values)")
        // …and an interior column reads exactly like the one beside it: a
        // horizontal pass would have made the two edge columns differ from it
        let neighbour = rows.map { Int(data.waveformY[$0 * width + column + 1]) }
        #expect(neighbour == values, "\(values) vs \(neighbour)")
        let edge = rows.map { Int(data.waveformY[$0 * width]) }
        #expect(edge == values, "the first column was blurred: \(edge)")
    }

    // MARK: - the nominal range itself

    @Test func aFullRangeFrameKeepsTheOldGeometryExactly() throws {
        let data = try #require(ScopeAnalyzer.analyze(
            try r210 { _ in 512 }, wireLevels: .full))
        #expect(data.nominal == .full)
        #expect(data.nominal.unit(ofLevel: 1) == 0)
        #expect(data.nominal.unit(ofLevel: 0) == 1)
        #expect(!data.nominal.showsExcursions)
        #expect(data.nominal.excursionFreeVisibleLevels)
    }

    @Test func theNominalRangeMapsLevelsAndBack() {
        let wire = ScopeNominalRange(white: 0.08, black: 0.94)
        #expect(abs(wire.unit(ofLevel: 1) - 0.08) < 1e-9)
        #expect(abs(wire.unit(ofLevel: 0) - 0.94) < 1e-9)
        #expect(abs(wire.level(atUnit: 0.51) - 0.5) < 0.01)
        // the map reaches past both ends, which is what the shaded bands mean
        #expect(wire.visibleLevels.upperBound > 1)
        #expect(wire.visibleLevels.lowerBound < 0)
        #expect(wire.showsExcursions)
    }
}

private extension ScopeNominalRange {
    /// A full-range map shows exactly 0…1 and nothing outside it.
    var excursionFreeVisibleLevels: Bool {
        abs(visibleLevels.lowerBound) < 1e-9
            && abs(visibleLevels.upperBound - 1) < 1e-9
    }
}
