import CaptureCore
import CoreGraphics
import SwiftUI

/// Waveform of the selected channel: "y" is the luma trace colored by the
/// image itself; single channels and the RGB composite are channel-tinted.
struct WaveformView: View {
    let data: ScopeData
    let channel: String

    var body: some View {
        ZStack {
            switch channel {
            case "r":
                channelImage(.red, tint: ScopeTint.red)
            case "g":
                channelImage(.green, tint: ScopeTint.green)
            case "b":
                channelImage(.blue, tint: ScopeTint.blue)
            case "rgb":
                channelImage(.red, tint: ScopeTint.red)
                    .blendMode(.screen)
                channelImage(.green, tint: ScopeTint.green)
                    .blendMode(.screen)
                channelImage(.blue, tint: ScopeTint.blue)
                    .blendMode(.screen)
            default: // "y" — luma trace carrying the image's color
                channelImage(.lumaColor, tint: nil)
            }
            ScopeLevelGraticule(nominal: data.nominal,
                                transfer: data.transfer)
        }
    }

    @ViewBuilder
    private func channelImage(_ map: ScopeImageCache.Map,
                              tint: Color?) -> some View {
        ScopeChannelImage(map: map, data: data, tint: tint)
    }
}

/// One tinted channel trace, decoded from the analyzer's cache.
///
/// The waveform's per-channel mode and the parade draw exactly this, and each
/// had its own copy — including `.interpolation(.medium)`, which is the
/// difference between a readable trace and a stair-stepped one.
///
/// How much the interpolator has to invent is NOT the same in the two scopes,
/// and that is what the operator was seeing: a parade squeezes the 1024-column
/// map into a third of the box and is always downscaling, a waveform spreads
/// one map across all of it. That is what sets the map's width — see
/// `ScopeData.waveWidth`.
private struct ScopeChannelImage: View {
    let map: ScopeImageCache.Map
    let data: ScopeData
    /// nil for the luma map, which already carries the image's own colours —
    /// multiplying those by anything is a second opinion about a trace that
    /// is deliberately the picture's.
    let tint: Color?

    var body: some View {
        if let image = ScopeImageCache.image(map, from: data) {
            let drawn = Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.medium)
            if let tint {
                drawn.colorMultiply(tint)
            } else {
                drawn
            }
        }
    }
}

/// Channel colors, stated once: the waveform and the parade draw the same three
/// traces and drifted apart by hand-copied literals.
enum ScopeTint {
    static let red = Color(red: 1, green: 0.28, blue: 0.28)
    static let green = Color(red: 0.3, green: 1, blue: 0.35)
    static let blue = Color(red: 0.35, green: 0.55, blue: 1)
}

/// **YRGB parade**: the luma trace and the three channel waveforms side by
/// side (owner: "сделай парады yrgb").
///
/// The Y column is the SAME map the waveform's default view draws — the luma
/// trace carrying the image's own colours — so it costs nothing to add: the
/// analyzer has always produced it, and the cache hands the two scopes one
/// image. What it adds to the parade is the column a colourist reads first:
/// the three channels say where the balance is, and Y says what the picture's
/// exposure is doing while they do.
struct ParadeView: View {
    let data: ScopeData

    /// One column of the parade.
    struct Column: Equatable {
        let map: ScopeImageCache.Map
        /// nil for Y — see `ScopeChannelImage.tint`.
        let tint: Color?
    }

    /// **Left to right: Y, R, G, B.** Named here rather than spelled inline in
    /// the body so the order is a value a test can hold: "the parade lost its
    /// luma column" is otherwise a change nothing in the suite can see.
    static let columns: [Column] = [
        Column(map: .lumaColor, tint: nil),
        Column(map: .red, tint: ScopeTint.red),
        Column(map: .green, tint: ScopeTint.green),
        Column(map: .blue, tint: ScopeTint.blue),
    ]

    var body: some View {
        ZStack {
            HStack(spacing: 1) {
                ForEach(Array(Self.columns.enumerated()), id: \.offset) { pair in
                    ScopeChannelImage(map: pair.element.map, data: data,
                                      tint: pair.element.tint)
                }
            }
            // one set of numbers across all the columns: the axis is shared,
            // and a copy per column is a copy per chance to read the wrong one
            ScopeLevelGraticule(nominal: data.nominal,
                                transfer: data.transfer)
        }
    }
}

/// Histogram of the selected channel(s): the analyzer's 256 bins drawn as 256
/// points, smoothed rather than paired (single-code gaps from level remaps
/// would otherwise show as a comb), with marks on the same code axis as the
/// waveform's.
///
/// A bin is one 8-bit code off a display buffer and four 10-bit codes off the
/// wire — the analyzer bins on the 10-bit scale either way, and an 8-bit code
/// widened and re-binned comes back to itself.
struct HistogramView: View {
    let data: ScopeData
    let channel: String

    var body: some View {
        // One axis over the whole stack, not one per row. The rows share a
        // single code axis — three copies of it drew the same rules three times
        // and gave the numbers to only one of them, which is how the marks on
        // the other two ended up as lines with nothing naming them.
        ZStack {
            // **One `Canvas` for all three channels**, for the reason
            // `ScopeLevelGraticule` is one. It was a `VStack` of
            // `GeometryReader`s, each holding two 256-point shapes — one filled
            // with a `LinearGradient`, one stroked — so a three-channel
            // histogram was six gradient-shaded shape views and three nested
            // layout passes, rebuilt on every scope publish.
            //
            // Measured before this change (release, one box at 440x300,
            // `ViewScopePanelCostTests`): **8.49 ms** a redraw, the most
            // expensive box on the panel by a factor of three and more than
            // half of a 60 Hz frame on its own, twelve and a half times a
            // second.
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                draw(in: context, size: size)
            }
            // the graticule and its numbers come from the same ScopeAxis the
            // traces are drawn through, so the brightness slider reaches them
            // like everything else
            ScopeCodeAxisMarks(nominal: data.nominal,
                               transfer: data.transfer)
        }
    }

    /// The channels stacked in rows — each normalized to its own peak, all
    /// three readable at once (nothing blended away). The row geometry is the
    /// `VStack(spacing: 1)` this replaced, arithmetic rather than layout.
    private func draw(in context: GraphicsContext, size: CGSize) {
        let series = selectedSeries
        guard !series.isEmpty else { return }
        let spacing: CGFloat = 1
        let rowHeight = (size.height - spacing * CGFloat(series.count - 1))
            / CGFloat(series.count)
        guard rowHeight > 0 else { return }
        for (index, item) in series.enumerated() {
            var row = context
            let top = (rowHeight + spacing) * CGFloat(index)
            row.translateBy(x: 0, y: top)
            let rowSize = CGSize(width: size.width, height: rowHeight)
            let peak = max(1, item.bins.max() ?? 1)
            let path = channelPath(item.bins, peak: peak, in: rowSize)
            row.fill(path, with: .linearGradient(
                Gradient(colors: [item.color.opacity(0.85),
                                  item.color.opacity(0.35)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: rowHeight)))
            row.stroke(path, with: .color(item.color), lineWidth: 1)
        }
    }

    private var selectedSeries: [(bins: [Int], color: Color)] {
        switch channel {
        case "r": return [(smoothed(data.histR), .red)]
        case "g": return [(smoothed(data.histG), .green)]
        case "b": return [(smoothed(data.histB), .blue)]
        case "y": return [(smoothed(data.histY), Color(white: 0.9))]
        default:
            return [(smoothed(data.histR), .red),
                    (smoothed(data.histG), .green),
                    (smoothed(data.histB), .blue)]
        }
    }

    /// Two 1-2-1 passes over all 256 bins.
    ///
    /// It used to PAIR the bins first and smooth the 128 that were left, which
    /// drew a 256-code histogram as 128 points across a box several hundred
    /// points wide — half the detail the analyzer had, thrown away in the view.
    /// The pairing was there to kill the comb a level-remapped source leaves
    /// (16-235 expanded to 0-255 fills only 220 of the bins), and two 1-2-1
    /// passes are a 1-4-6-4-1 binomial: it fills a single-code gap to ~85 % of
    /// its neighbours, which reads as continuous, and it does it without
    /// halving the resolution.
    private func smoothed(_ bins: [Int]) -> [Int] {
        onePass(onePass(bins))
    }

    private func onePass(_ bins: [Int]) -> [Int] {
        bins.indices.map { i in
            let left = i > 0 ? bins[i - 1] : bins[i]
            let right = i < bins.count - 1 ? bins[i + 1] : bins[i]
            return (left + bins[i] * 2 + right) / 4
        }
    }

    private func channelPath(_ bins: [Int], peak: Int, in size: CGSize) -> Path {
        Path { p in
            let step = size.width / CGFloat(bins.count - 1)
            p.move(to: CGPoint(x: 0, y: size.height))
            for (i, count) in bins.enumerated() {
                let h = ScopeHistogramScale.height(count: count, peak: peak,
                                                   rowHeight: size.height)
                p.addLine(to: CGPoint(x: CGFloat(i) * step,
                                      y: size.height - CGFloat(h)))
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
        }
    }
}
