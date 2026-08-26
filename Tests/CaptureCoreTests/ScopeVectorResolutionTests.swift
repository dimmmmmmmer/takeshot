import Foundation
import Testing

@testable import CaptureCore

/// The vectorscope's map is 256 cells across a box drawn at three or four times
/// that in device pixels, so where a sample lands INSIDE its cell is the whole
/// difference between a trace that reads as an instrument and one that reads as
/// a low-resolution picture of an instrument (owner: "векторскоп кстати тоже
/// выглядит как low res").
///
/// These tests measure position, not appearance. A sample deposited whole into
/// the cell it falls in can only ever report a cell centre, so the trace jumps
/// a full cell at a time however finely the signal moves; splitting it between
/// the four cells around it lets the map say where the sample really is.
struct ScopeVectorResolutionTests {
    private static let size = ScopeData.vectorSize

    /// Intensity-weighted centre of the vectorscope map, in cells.
    private func centre(_ data: ScopeData) -> (x: Double, y: Double) {
        var totalX = 0.0, totalY = 0.0, weight = 0.0
        for y in 0..<Self.size {
            for x in 0..<Self.size {
                let value = Double(data.vector[y * Self.size + x])
                guard value > 0 else { continue }
                totalX += Double(x) * value
                totalY += Double(y) * value
                weight += value
            }
        }
        return weight > 0 ? (totalX / weight, totalY / weight) : (.nan, .nan)
    }

    private func analyzed(cb: Int, cr: Int = V210Fixtures.chromaZero) throws
        -> ScopeData {
        let frame = try V210Fixtures.makeV210(width: 336, height: 180) { _, _ in
            V210Fixtures.Sample(luma: 512, cb: cb, cr: cr)
        }
        return try #require(ScopeAnalyzer.analyze(frame, wireLevels: .full),
                            "the analyzer refused a 'v210' frame")
    }

    /// How many cells share the maximum along the peak's row (or column).
    ///
    /// One means the trace is sitting ON a cell; two adjacent means it is
    /// sitting BETWEEN them, which is a position the map has no cell for and
    /// can only express by lighting both.
    private func cellsSharingTheMaximum(_ data: ScopeData,
                                        vertical: Bool = false) -> Int {
        let size = Self.size
        let peak = data.vector.firstIndex(of: data.vector.max() ?? 0) ?? 0
        let line = (0..<size).map { index -> UInt8 in
            vertical ? data.vector[index * size + peak % size]
                     : data.vector[(peak / size) * size + index]
        }
        return line.filter { $0 == line.max() }.count
    }

    /// One 10-bit chroma code moves the trace a quarter of a cell, and across a
    /// sweep of one whole cell the map must be able to say so.
    ///
    /// This counts rather than measures, which is what makes it sharp: a sample
    /// deposited whole is always one cell that the separable 1-2-1 spreads
    /// symmetrically, so exactly one cell holds the maximum at EVERY position
    /// inside the cell — the trace can only ever report a cell centre. Split
    /// between its neighbours, a sample halfway between two cells lights both
    /// equally, and the sweep therefore shows both answers. Measured: whole-cell
    /// gives 1 at all five steps; splitting gives 2, 1, 1, 1, 2.
    @Test func theTraceCanSitBetweenTwoCellsAndNotOnlyOnOne() throws {
        var counts: [Int] = []
        for step in 0...4 {
            counts.append(cellsSharingTheMaximum(
                try analyzed(cb: V210Fixtures.chromaZero + step)))
        }
        #expect(counts.contains(2),
                "the trace never sits between two cells: \(counts)")
        #expect(counts.contains(1),
                "the trace never sits on a cell at all: \(counts)")
    }

    /// The same on the other axis. Cr also carries the sign — positive Cr is UP
    /// — so a split mirrored in y would pass the test above while putting every
    /// trace on the wrong side of the graticule.
    @Test func theVerticalAxisIsJustAsFineAndStillPointsUp() throws {
        var counts: [Int] = []
        for step in 0...4 {
            counts.append(cellsSharingTheMaximum(
                try analyzed(cb: V210Fixtures.chromaZero,
                             cr: V210Fixtures.chromaZero + step),
                vertical: true))
        }
        #expect(counts.contains(2),
                "the vertical trace cannot sit between two cells: \(counts)")

        let low = centre(try analyzed(cb: V210Fixtures.chromaZero,
                                      cr: V210Fixtures.chromaZero))
        let high = centre(try analyzed(cb: V210Fixtures.chromaZero,
                                       cr: V210Fixtures.chromaZero + 40))
        #expect(high.y < low.y, "more Cr must move the trace UP")
    }

    /// A neutral frame sits at the exact centre of the map, and the centre of
    /// the map is a cell BOUNDARY rather than a cell — so this is the one
    /// position a whole-cell deposit gets wrong by half a cell in both axes.
    @Test func aNeutralFrameSitsOnTheCentreItself() throws {
        let data = try analyzed(cb: V210Fixtures.chromaZero)
        let middle = Double(Self.size) / 2 - 0.5
        let centre = centre(data)
        #expect(abs(centre.x - middle) < 0.1, "neutral is off centre in x")
        #expect(abs(centre.y - middle) < 0.1, "neutral is off centre in y")
    }
}
