import AppKit
import CaptureCore
import CoreVideo
import SwiftUI
import Testing

@testable import TakeShotKit

/// The geometry the scopes actually draw, and the chrome around it.
///
/// Separate from `ViewScopesTests`, which measures how the panel LAYS OUT — its
/// widths in both languages, which box appears where. These are the pixels: how
/// much of the trace map reaches the screen, whether the vectorscope stays
/// inside the box it was given, what the shaded bands say, and the two controls
/// and one gesture the operator reported as wrong.
@MainActor
struct ViewScopeGeometryTests {
    /// Analyzer output from a DETAILED frame: a shallow ramp with fine noise on
    /// it, which is what a trace looks like on real footage. A flat gradient
    /// draws a hairline and says nothing about how a dense trace resolves.
    private static func detailedScopeData() throws -> ScopeData {
        let width = 1920, height = 1080
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        for y in 0..<height {
            let row = base + y * rowBytes
            for x in 0..<width {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                let value = x * 128 / (width - 1) + 40 + Int(state % 90)
                let code = UInt8(max(0, min(255, value)))
                row[x * 4] = code
                row[x * 4 + 1] = code
                row[x * 4 + 2] = code
                row[x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return try #require(ScopeAnalyzer.analyze(buffer))
    }

    // MARK: - owner item 31: the waveform beside the parade

    /// The waveform must reach the screen with as much horizontal detail as the
    /// parade does.
    ///
    /// They draw the SAME density map — one accumulator writes all four trace
    /// maps in a single pass, and `ScopeWireTests` pins that they resolve the
    /// same steps. What differed was the geometry: a parade squeezes the map
    /// into a third of the box and is always downscaling, a waveform spreads
    /// one map across all of it, so on a 2x display the waveform was
    /// interpolating each column across two to four device pixels. Measured in
    /// this box before the map was widened and the horizontal blur dropped, the
    /// waveform kept 0.35 of the parade's detail; it keeps about 1.05 now.
    ///
    /// The margin is wide because the number depends on the backing scale (2x
    /// on a Mac, 1x on a headless runner). The failure it exists to catch —
    /// halving the map's width, or putting the horizontal softening back —
    /// costs a factor of two to three, not a few per cent.
    @Test func theWaveformKeepsAsMuchHorizontalDetailAsTheParade() async throws {
        let data = try Self.detailedScopeData()
        try await ViewProbe.run { probe in
            // the scopes window's two-up layout: 980 pt of window, two boxes
            let box = CGSize(width: 472, height: 300)
            @MainActor func detail(_ view: some View) -> Double {
                ViewRender.horizontalDetail(probe.hosted(
                    view.environment(\.scopeGridBrightness, 0.0001)
                        .background(Color.black)), in: box)
            }
            let waveform = detail(WaveformView(data: data, channel: "y"))
            let parade = detail(ParadeView(data: data))
            #expect(parade > 0, "the parade drew nothing to compare against")
            #expect(waveform >= parade * 0.75,
                    "the waveform kept \(waveform) against the parade's \(parade)")
        }
    }

    // MARK: - owner item 32: the vectorscope inside its box

    /// The vectorscope leaves a margin between itself and the box it is in, at
    /// every size the panel offers.
    ///
    /// It used to draw from the first row of its canvas to the last: measured
    /// in a 472x295 box the graticule occupied x 89…383, y 0…294 — the whole
    /// square, edge to edge. Nothing overflowed, but the boundary circle was
    /// hard against the frame, the box's rounded corners cut the square's, and
    /// the G/Mg 100 % marks at 0.954 of the height landed four points from the
    /// bottom.
    @Test func theVectorscopeStaysInsideItsBox() async throws {
        let data = try Self.detailedScopeData()
        try await ViewProbe.run { probe in
            for box in [CGSize(width: 472, height: 295),
                        CGSize(width: 300, height: 300),
                        CGSize(width: 260, height: 150),
                        CGSize(width: 956, height: 620)] {
                let drawn = try #require(ViewRender.drawnBounds(probe.hosted(
                    VectorscopeView(data: data)
                        .environment(\.scopeGridBrightness, 1)
                        .background(Color.black)), in: box),
                                         "nothing drawn in \(box)")
                let side = min(box.width, box.height)
                let margin = side * (1 - VectorscopeView.boxFill) / 2
                let gutter = (box.width - side) / 2 + margin
                // a point of slack each way for the stroke's own antialiasing
                #expect(drawn.minY >= margin - 1,
                        "\(box): drawn from y \(drawn.minY), margin \(margin)")
                #expect(drawn.maxY <= box.height - margin + 1,
                        "\(box): drawn to y \(drawn.maxY), margin \(margin)")
                #expect(drawn.minX >= gutter - 1,
                        "\(box): drawn x starts at \(drawn.minX), gutter \(gutter)")
                #expect(drawn.maxX <= box.width - gutter + 1,
                        "\(box): drawn x ends at \(drawn.maxX)")
                // …and it still uses most of what it was given
                #expect(drawn.height > side * 0.9,
                        "\(box): only \(drawn.height) tall")
            }
        }
    }

    // MARK: - owner item 33: the excursion bands

    /// The shaded band above 100 % and below 0 % is named at the scale.
    ///
    /// It was a strip of tint whose inner edge read as a rule and whose outer
    /// edge was the frame, with nothing saying what lay between them — the
    /// owner's "unexplained limit lines at the top and bottom". A wire frame
    /// carries about 109 % of headroom and 7 % below black, so those two
    /// numbers now sit at the ends of the ladder and the band runs between two
    /// labelled levels.
    @Test func theExcursionBandsAreNamedAtTheScale() async throws {
        let wire = ScopeNominalRange(white: 0.0802, black: 0.9374)
        let axis = ScopeAxis(nominal: wire, mode: .percent)
        let labels = axis.ticks.map(\.label)
        #expect(labels.contains("109"), "no super-white end label: \(labels)")
        #expect(labels.contains("-7"), "no sub-black end label: \(labels)")
        #expect(axis.ticks.contains { $0.unit == 0 })
        #expect(axis.ticks.contains { $0.unit == 1 })
        // …as numbers only. A rule ON the edge of the canvas is exactly the
        // hairline-against-the-frame the labels are here to account for.
        #expect(!axis.ticks.filter(\.drawsRule).contains { $0.unit == 0 })
        #expect(!axis.ticks.filter(\.drawsRule).contains { $0.unit == 1 })
        // a full-range frame has no band, so it gets no extra numbers either
        let full = ScopeAxis(nominal: .full, mode: .percent)
        #expect(full.ticks.count == 11, "\(full.ticks.map(\.label))")
        #expect(full.excursionBands.isEmpty)
        // …and the code scale already names the ends of the map itself
        let codes = ScopeAxis(nominal: wire, mode: .tenBitCode).ticks.map(\.label)
        #expect(codes.filter { $0 == "1023" }.count == 1, "\(codes)")

        try await ViewProbe.run { probe in
            let size = CGSize(width: 300, height: 200)
            let columns = ViewRender.brightColumns(probe.hosted(
                ScopeLevelGraticule(nominal: wire)
                    .environment(\.scopeGridBrightness, 1)
                    .background(Color.black)), in: size, threshold: 200)
            // the end numbers are numbers like the rest — same left gutter
            #expect(columns.max() ?? 999 < 40, "\(columns)")
        }
    }

    /// The histogram carries no excursion shading at all.
    ///
    /// On a code axis the band is a strip 6-8 % of the box WIDE with no room
    /// for a number in it, and the histogram drew one copy per stacked channel
    /// row while giving the numbers to only the bottom one — the owner's
    /// "unexplained limit lines at the left and right of the histogram". The
    /// axis is drawn once over the whole stack now, and the bins either side of
    /// the labelled 0 and 100 marks say what the shading was trying to.
    @Test func theHistogramDrawsNoExcursionShading() async throws {
        let data = try Self.detailedScopeData()
        let wire = ScopeNominalRange(white: 0.0802, black: 0.9374)
        try await ViewProbe.run { probe in
            let size = CGSize(width: 320, height: 210)
            // the axis alone over black: with the bands gone its extreme
            // columns are empty, because no rule sits at either end of the map
            let axisOnly = ViewRender.drawnBounds(probe.hosted(
                ScopeCodeAxisMarks(nominal: wire)
                    .environment(\.scopeGridBrightness, 1)
                    .background(Color.black)), in: size, floor: 0.03)
            let drawn = try #require(axisOnly, "the axis drew nothing")
            #expect(drawn.minX > 2, "something is drawn at the left edge: \(drawn)")
            #expect(drawn.maxX < size.width - 2,
                    "something is drawn at the right edge: \(drawn)")

            // and the stacked histogram lays out the same in both languages
            let laid = probe.sizes(proposedWidth: 320, proposedHeight: 210) {
                HistogramView(data: data, channel: "rgb")
            }
            #expect(laid.en == laid.ru, "histogram: \(laid)")
        }
    }

    // MARK: - owner item 29: the chrome button order

    /// Close is the last control in the chrome row.
    ///
    /// `windowButtons` walks `ScopeChromeButton.allCases`, so this order is the
    /// order drawn. It used to be hand-written with the X first, which put the
    /// only control that takes the scopes away between the operator and the one
    /// that tears them off into a window.
    @Test func theCloseButtonIsTheLastControlInTheChrome() {
        #expect(ScopeChromeButton.allCases == [.openInWindow, .close])
        #expect(ScopeChromeButton.allCases.last == .close)
    }

    // MARK: - owner item 34: the drag

    /// A drag update moves the boxes and writes nothing.
    ///
    /// The reorder used to write the persisted order from `dropEntered`, and
    /// `dropEntered` fires again every time the boxes move under the pointer —
    /// which the write itself causes. Every tick was a synchronous
    /// `UserDefaults` write plus a republish of the whole panel: the grid
    /// relaid out and all four traces rebuilt, at pointer rate, while the
    /// operator was dragging one of them.
    @Test func aDragHoverReordersWithoutCommittingAnything() {
        var live: [ScopeKind]?
        var commits = 0
        let order: [ScopeKind] = [.waveform, .parade, .histogram, .vector]
        let delegate = ScopeDropDelegate(
            target: .waveform, dragged: .constant(.vector),
            live: Binding(get: { live }, set: { live = $0 }),
            commit: { commits += 1 }, order: order)
        for _ in 0..<50 { delegate.hover() }
        #expect(live == [.vector, .waveform, .parade, .histogram],
                "the hover did not reorder: \(String(describing: live))")
        #expect(commits == 0, "a hover committed \(commits) times")
        delegate.drop()
        #expect(commits == 1, "the release committed \(commits) times")
    }

    /// A drag onto the box already being dragged does nothing at all — the
    /// guard that stops the reorder oscillating under its own feedback.
    @Test func aDragOntoItselfChangesNothing() {
        let order: [ScopeKind] = [.waveform, .parade, .histogram, .vector]
        #expect(ScopeDropDelegate.reordered(order, moving: .parade,
                                            onto: .parade) == nil)
        #expect(ScopeDropDelegate.reordered(order, moving: nil,
                                            onto: .parade) == nil)
        #expect(ScopeDropDelegate.reordered(order, moving: .waveform,
                                            onto: .vector)
            == [.parade, .histogram, .vector, .waveform])
    }
}
