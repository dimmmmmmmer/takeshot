import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing

@testable import CaptureCore

/// Reading a burned-in legend back off a frame: the frame it is drawn on, and
/// the two questions every test here asks — how many different colours are in
/// this row, and is one of them the colour the palette paints with.
///
/// Distinct COLOURS rather than a level, which is what the rest of the assist
/// suites read: over a flat frame every exposure tool paints one colour
/// everywhere, so a row carrying nine of them is the legend and nothing else
/// could be.
enum LegendProbe {
    /// A solid opaque BGRA frame at an arbitrary size.
    static func frame(_ level: UInt8, width: Int, height: Int) -> CVPixelBuffer {
        let buffer = TestMedia.pixelBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return buffer }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = bytes + y * rowBytes
            for x in 0..<width {
                row[x * 4] = level
                row[x * 4 + 1] = level
                row[x * 4 + 2] = level
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    /// Every pixel of a frame as (r, g, b), read top-down.
    static func pixels(of buffer: CVPixelBuffer) -> [[ChromaProbe.Pixel]] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        return (0..<height).map { y in
            let row = bytes + y * rowBytes
            return (0..<width).map { x in
                ChromaProbe.Pixel(r: Int(row[x * 4 + 2]), g: Int(row[x * 4 + 1]),
                                  b: Int(row[x * 4]))
            }
        }
    }

    /// How many distinct colours a line of pixels holds, quantized so that the
    /// antialiasing along a swatch edge is not counted as another band.
    static func distinctColors(_ line: [ChromaProbe.Pixel]) -> Int {
        Set(line.map { ($0.r / 16) << 16 | ($0.g / 16) << 8 | ($0.b / 16) }).count
    }

    /// The row holding the most colours, and how many — the legend's row on a
    /// frame where everything else is flat.
    static func busiestRow(of buffer: CVPixelBuffer) -> (index: Int, colors: Int) {
        let rows = pixels(of: buffer).map { distinctColors($0) }
        let best = rows.indices.max { rows[$0] < rows[$1] } ?? 0
        return (best, rows.isEmpty ? 0 : rows[best])
    }

    /// The same question down the columns, for a vertical strip.
    static func busiestColumn(of buffer: CVPixelBuffer)
        -> (index: Int, colors: Int) {
        let grid = pixels(of: buffer)
        guard let width = grid.first?.count else { return (0, 0) }
        let columns = (0..<width).map { x in
            distinctColors(grid.map { $0[x] })
        }
        let best = columns.indices.max { columns[$0] < columns[$1] } ?? 0
        return (best, columns[best])
    }

    /// Whether a palette colour is somewhere on the frame, within a code or two
    /// of exact — the strip is composited unmanaged, so a swatch that IS the
    /// paint comes back as the paint.
    ///
    /// The whole frame rather than one row: a swatch's edge is antialiased
    /// against the panel behind it, so only its interior carries the colour
    /// exactly, and where that interior falls is the layout's business.
    static func contains(_ color: AssistFilters.BandColor,
                         in grid: [[ChromaProbe.Pixel]]) -> Bool {
        let target = ChromaProbe.Pixel(r: ChromaProbe.byteValue(color.red),
                                       g: ChromaProbe.byteValue(color.green),
                                       b: ChromaProbe.byteValue(color.blue))
        return grid.contains { line in
            line.contains { pixel in
                abs(pixel.r - target.r) <= 2 && abs(pixel.g - target.g) <= 2
                    && abs(pixel.b - target.b) <= 2
            }
        }
    }

    /// How far a channel may sit from its neighbours and still be grey. Above
    /// a ProRes 4:2:2 round trip on a flat frame (a code or two), far below
    /// every band of every exposure palette.
    static let colorful = 8

    /// The first pixel anywhere on the frame that is not grey, or nil.
    ///
    /// What `AssistIntegrityTests` reads a take and a grab for: the legend is a
    /// strip against one edge, so the middle row those suites already sample
    /// would never touch it, and neutrality is the reading that survives an
    /// encode — a swatch is a hue, and a flat grey does not become one.
    static func firstColoredPixel(of buffer: CVPixelBuffer) -> ChromaProbe.Pixel? {
        pixels(of: buffer).lazy.flatMap { $0 }.first(where: isColored)
    }

    /// The same question of a PNG grab. nil — the still could not be decoded,
    /// which is a different failure from a clean one.
    static func coloredPixels(inPNG data: Data) -> [ChromaProbe.Pixel]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0 else { return nil }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = bytes.withUnsafeMutableBytes({ raw in
            CGContext(data: raw.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: width * height * 4, by: 4).compactMap { at in
            let pixel = ChromaProbe.Pixel(r: Int(bytes[at]), g: Int(bytes[at + 1]),
                                          b: Int(bytes[at + 2]))
            return isColored(pixel) ? pixel : nil
        }
    }

    static func isColored(_ pixel: ChromaProbe.Pixel) -> Bool {
        abs(pixel.r - pixel.g) > colorful || abs(pixel.g - pixel.b) > colorful
    }

    /// One flat frame through a display stage with `assist` on it.
    static func rendered(_ assist: ViewAssist, level: UInt8 = 140,
                         width: Int = 640, height: Int = 360) -> CVPixelBuffer? {
        let stage = AssistStage()
        stage.setAssist(assist)
        return stage.rendered(frame(level, width: width, height: height))
    }

    /// A false colour with the legend at `placement`.
    static func assist(_ placement: AssistLegendPlacement,
                       size: AssistLegendSize = .medium) -> ViewAssist {
        var assist = ViewAssist()
        assist.colorTool = .falseColor
        assist.legend = AssistLegend(size: size, placement: placement)
        return assist
    }
}

/// The exposure legend's own geometry: what it says, how big it is on a given
/// signal, and which edge it lands against.
///
/// It is drawn into the frame now rather than laid over the player (the owner
/// overruled the overlay — see `AssistLegend`), so every measurement here is
/// against the SIGNAL. That is what makes the legend on the hardware monitor
/// and the legend in the viewer the same object.
struct AssistLegendTests {
    private static let hd = CGSize(width: 1920, height: 1080)
    private static let uhd = CGSize(width: 3840, height: 2160)

    // MARK: - what it says

    /// The swatches ARE the paint: each band's colour is read out of the same
    /// palette the picture is remapped through, sampled in the middle of the
    /// range that band covers. A legend with its own copy of the colours is a
    /// legend that can lie.
    @Test func theSwatchesAreTheColoursThePictureIsPaintedWith() {
        let falseColor = AssistLegend.entries(for: .falseColor)
        #expect(falseColor.count == AssistFilters.falseColorBands.count)
        #expect(falseColor.count == AssistLegend.falseColorLabels.count,
                "a band has no label, or a label has no band")
        // the ends are the two readings that matter on set: crushed and clipped
        #expect(falseColor.first?.color == AssistFilters.band(0.01))
        #expect(falseColor.last?.color == AssistFilters.band(1))
        #expect(falseColor.last?.label == "clip")
        // …and a gray-ramp gap shows the gray the picture would be there
        #expect(falseColor[2].color == AssistFilters.band(0.22))
        #expect(falseColor[2].label.isEmpty)

        let elZone = AssistLegend.entries(for: .elZone)
        #expect(elZone.count == AssistFilters.elZoneRamp.count)
        #expect(elZone.map(\.color) == AssistFilters.elZoneRamp)
        #expect(elZone.map(\.label).first == "-6")
        #expect(elZone.map(\.label).last == "+6")
        #expect(elZone[6].label == "0", "18% gray is not the middle band")

        #expect(AssistLegend.entries(for: .off).isEmpty)
    }

    /// Stop marks, not words: the labels are the same in every language, which
    /// is why nothing here goes through `L()`.
    @Test func theLabelsAreStopMarksRatherThanTranslatedWords() {
        let labels = AssistLegend.entries(for: .falseColor).map(\.label)
        #expect(labels == ["<2", "2-8", "", "18%", "", "skin", "", "92-97",
                           "clip"])
    }

    // MARK: - how big it is

    /// The whole point of drawing at signal resolution: a legend sized for a
    /// 1080p viewer must not be a postage stamp on a UHD output. Every metric
    /// rides one scale factor, so the strip covers the same FRACTION of the
    /// picture on both.
    @Test func theStripKeepsItsSizeRelativeToTheFrame() throws {
        for size in AssistLegendSize.allCases {
            let legend = AssistLegend(size: size)
            let hd = try #require(legend.layout(for: .falseColor, in: Self.hd))
            let uhd = try #require(legend.layout(for: .falseColor, in: Self.uhd))
            #expect(abs(uhd.rect.width - hd.rect.width * 2) <= 1,
                    "\(size): \(hd.rect.width) on HD, \(uhd.rect.width) on UHD")
            #expect(abs(uhd.rect.height - hd.rect.height * 2) <= 1)
            #expect(uhd.scale == hd.scale * 2)
        }
    }

    /// …and the other end of it: it may not cover the picture either. A quarter
    /// of the frame was the owner's line; the widest strip there is (thirteen
    /// EL Zone bands at the large size) is nowhere near it.
    @Test func theStripNeverCoversAQuarterOfThePicture() throws {
        for size in AssistLegendSize.allCases {
            for placement in AssistLegendPlacement.allCases {
                for tool in [ViewAssist.ColorTool.falseColor, .elZone] {
                    let legend = AssistLegend(size: size, placement: placement)
                    for frame in [Self.hd, CGSize(width: 1280, height: 720)] {
                        let layout = try #require(legend.layout(for: tool,
                                                                in: frame))
                        let share = layout.rect.width * layout.rect.height
                            / (frame.width * frame.height)
                        #expect(share < 0.25,
                                "\(size)/\(placement)/\(tool) takes \(share) of \(frame)")
                        #expect(CGRect(origin: .zero, size: frame)
                            .contains(layout.rect),
                                "\(size)/\(placement)/\(tool) hangs off \(frame)")
                    }
                }
            }
        }
    }

    /// A signal too narrow for the strip at its natural size shrinks it to fit
    /// rather than running it off the side of the picture — and a frame too
    /// small to hold a legend at all gets none instead of a smudge.
    @Test func aSmallFrameShrinksTheStripAndATinyOneDropsIt() throws {
        let legend = AssistLegend(size: .large)
        // a 9:16 signal: tall enough for a big scale, too narrow to spend it on
        // thirteen bands at that size
        let narrow = CGSize(width: 1080, height: 1920)
        let layout = try #require(legend.layout(for: .elZone, in: narrow))
        #expect(CGRect(origin: .zero, size: narrow).contains(layout.rect))
        #expect(layout.scale < narrow.height / AssistLegend.referenceHeight,
                "the strip did not shrink past the height scale to fit")

        // and on a small signal the swatches keep going after the labels stop:
        // sub-pixel glyphs are grey mush, a colour key is still a colour key
        let small = try #require(legend.layout(for: .elZone,
                                               in: CGSize(width: 320,
                                                          height: 180)))
        #expect(!small.showsLabels)
        #expect(small.rect.height >= AssistLegend.minimumPanel.height)

        #expect(legend.layout(for: .elZone,
                              in: CGSize(width: 64, height: 32)) == nil)
        #expect(legend.layout(for: .off, in: Self.hd) == nil,
                "a legend with no exposure tool has nothing to be a key to")
    }

    /// Four placements, four edges. Measured as a box against the frame rather
    /// than as an alignment against a view — that difference is the item.
    @Test func eachPlacementPutsTheStripAgainstItsOwnEdge() throws {
        let frame = Self.hd
        func layout(_ placement: AssistLegendPlacement) throws
            -> AssistLegend.Layout {
            try #require(AssistLegend(placement: placement)
                .layout(for: .falseColor, in: frame))
        }
        // y is UP here: this is the space the display stage composites in
        let bottom = try layout(.bottom)
        #expect(bottom.rect.minY < frame.height * 0.1)
        #expect(abs(bottom.rect.midX - frame.width / 2) <= 1, "not centered")
        let top = try layout(.top)
        #expect(top.rect.maxY > frame.height * 0.9)
        #expect(abs(top.rect.midX - frame.width / 2) <= 1)
        let left = try layout(.left)
        #expect(left.rect.minX < frame.width * 0.1)
        #expect(abs(left.rect.midY - frame.height / 2) <= 1)
        #expect(left.rect.height > left.rect.width, "a left strip is a column")
        let right = try layout(.right)
        #expect(right.rect.maxX > frame.width * 0.9)
        #expect(right.rect.height > right.rect.width)
        // the two columns are the same strip in two places
        #expect(left.rect.size == right.rect.size)
        #expect(bottom.rect.width > bottom.rect.height, "a bottom strip is a row")
    }

    /// The legend comes out of the settings intact, defaults included — one
    /// conversion, so the drawn strip and the popover's pickers cannot mean
    /// different things by "medium" or "bottom".
    @Test func theLegendComesOutOfTheSettingsIntact() {
        var settings = CaptureSettings()
        #expect(AssistLegend(settings: settings) == AssistLegend())
        #expect(AssistLegend().size == .medium)
        #expect(AssistLegend().placement == .bottom)
        #expect(AssistLegendPlacement.standard == .bottom)
        #expect(AssistLegendPlacement.left.isVertical)
        #expect(AssistLegendPlacement.right.isVertical)
        #expect(!AssistLegendPlacement.top.isVertical)
        #expect(!AssistLegendPlacement.bottom.isVertical)

        settings.legendSize = "l"
        settings.legendPlacement = "right"
        #expect(AssistLegend(settings: settings)
            == AssistLegend(size: .large, placement: .right))
        // a hand-edited blob falls back rather than crashing a picker
        settings.legendSize = "enormous"
        settings.legendPlacement = "diagonal"
        #expect(AssistLegend(settings: settings) == AssistLegend())
    }

    // MARK: - on the frame

    /// The strip is really drawn, and it is drawn where the placement says: on
    /// a flat frame every other row is one colour, so the row (or the column)
    /// carrying nine of them is the legend.
    @Test func eachPlacementDrawsTheStripWhereItSaysOnTheFrame() throws {
        let height = 360
        let width = 640
        for placement in [AssistLegendPlacement.bottom, .top] {
            let shown = try #require(LegendProbe.rendered(
                LegendProbe.assist(placement), width: width, height: height))
            let busiest = LegendProbe.busiestRow(of: shown)
            #expect(busiest.colors >= 5,
                    "\(placement): the busiest row holds \(busiest.colors) colours")
            let fraction = Double(busiest.index) / Double(height)
            #expect(placement == .bottom ? fraction > 0.7 : fraction < 0.3,
                    "\(placement): the strip landed at \(fraction) down the frame")
        }
        for placement in [AssistLegendPlacement.left, .right] {
            let shown = try #require(LegendProbe.rendered(
                LegendProbe.assist(placement), width: width, height: height))
            let busiest = LegendProbe.busiestColumn(of: shown)
            #expect(busiest.colors >= 5,
                    "\(placement): the busiest column holds \(busiest.colors)")
            let fraction = Double(busiest.index) / Double(width)
            #expect(placement == .left ? fraction < 0.3 : fraction > 0.7,
                    "\(placement): the strip landed at \(fraction) across")
        }
    }

    /// …and what it draws there is the palette. Purple for crushed, red for
    /// clipped: if the strip were painted from a second copy of the colours,
    /// this is where the two would part.
    @Test func theStripOnTheFrameCarriesThePalettesOwnColours() throws {
        let shown = try #require(LegendProbe.rendered(
            LegendProbe.assist(.bottom)))
        let grid = LegendProbe.pixels(of: shown)
        for band in [AssistFilters.band(0.01), AssistFilters.band(1),
                     AssistFilters.band(0.4)] {
            #expect(LegendProbe.contains(band, in: grid),
                    "the strip is missing \(band)")
        }
        // the picture itself is still one flat colour — the strip is a strip
        let middle = grid[180]
        #expect(LegendProbe.distinctColors(middle) == 1,
                "the legend bled into the picture")
    }

    /// The guides alone draw no legend: it is a key to an exposure tool, and
    /// with no tool on there is nothing to be a key to.
    @Test func framelinesAloneDrawNoLegend() throws {
        var assist = ViewAssist()
        assist.guides = AssistGuides(ratio: 2.39, safeAreas: true)
        assist.legend = AssistLegend(placement: .bottom)
        let shown = try #require(LegendProbe.rendered(assist))
        // the guides paint in white and black over a grey frame, so the whole
        // picture is still neutral; every band of every legend is a colour
        let colored = LegendProbe.pixels(of: shown).flatMap { $0 }.first {
            abs($0.r - $0.g) > 3 || abs($0.g - $0.b) > 3
        }
        #expect(colored == nil,
                "a legend was drawn with no tool on: \(String(describing: colored))")
    }
}
