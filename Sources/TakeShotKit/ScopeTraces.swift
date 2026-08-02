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
                if let image = ScopeImageCache.image(.lumaColor, from: data) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                }
            }
            ScopeLevelGraticule(nominal: data.nominal)
        }
    }

    @ViewBuilder
    private func channelImage(_ map: ScopeImageCache.Map,
                              tint: Color) -> some View {
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
    let tint: Color

    var body: some View {
        if let image = ScopeImageCache.image(map, from: data) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.medium)
                .colorMultiply(tint)
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

/// RGB parade: three channel waveforms side by side.
struct ParadeView: View {
    let data: ScopeData

    var body: some View {
        ZStack {
            HStack(spacing: 1) {
                paradeChannel(.red, tint: ScopeTint.red)
                paradeChannel(.green, tint: ScopeTint.green)
                paradeChannel(.blue, tint: ScopeTint.blue)
            }
            // one set of numbers across all three columns: the axis is shared,
            // and three copies of it is three chances to read the wrong one
            ScopeLevelGraticule(nominal: data.nominal)
        }
    }

    @ViewBuilder
    private func paradeChannel(_ map: ScopeImageCache.Map,
                               tint: Color) -> some View {
        ScopeChannelImage(map: map, data: data, tint: tint)
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
            VStack(spacing: 1) {
                // channels stacked in rows — each normalized to its own peak,
                // all three readable at once (nothing blended away)
                ForEach(Array(selectedSeries.enumerated()),
                        id: \.offset) { _, item in
                    channelRow(item.bins, color: item.color)
                }
            }
            // the graticule and its numbers come from the same ScopeAxis the
            // traces are drawn through, so the brightness slider reaches them
            // like everything else
            ScopeCodeAxisMarks(nominal: data.nominal)
        }
    }

    private func channelRow(_ bins: [Int], color: Color) -> some View {
        GeometryReader { geo in
            let peak = max(1, bins.max() ?? 1)
            ZStack {
                channelPath(bins, peak: peak, in: geo.size)
                    .fill(LinearGradient(
                        colors: [color.opacity(0.85), color.opacity(0.35)],
                        startPoint: .top, endPoint: .bottom))
                channelPath(bins, peak: peak, in: geo.size)
                    .stroke(color, lineWidth: 1)
            }
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
        // log heights, like the traces: a linear scale turns a histogram with
        // one dominant tone into a lone spike over a flat line
        let logPeak = Foundation.log(Double(peak) + 1)
        return Path { p in
            let step = size.width / CGFloat(bins.count - 1)
            p.move(to: CGPoint(x: 0, y: size.height))
            for (i, count) in bins.enumerated() {
                let h = count == 0 ? 0
                    : size.height * Foundation.log(Double(count) + 1) / logPeak
                p.addLine(to: CGPoint(x: CGFloat(i) * step,
                                      y: size.height - CGFloat(h)))
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
        }
    }
}
