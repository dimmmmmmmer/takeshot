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
            WaveformGraticule()
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
            WaveformGraticule()
        }
    }

    @ViewBuilder
    private func paradeChannel(_ map: ScopeImageCache.Map,
                               tint: Color) -> some View {
        ScopeChannelImage(map: map, data: data, tint: tint)
    }
}

/// Dense waveform graticule: a line every 10%, stronger at 0/25/50/75/100,
/// brightness user-adjustable.
private struct WaveformGraticule: View {
    @Environment(\.scopeGridBrightness) private var brightness

    var body: some View {
        GeometryReader { geo in
            // every 10%, faint; then the quarters over the top of them
            lines(at: Array(stride(from: 0.0, through: 1.0, by: 0.1)),
                  in: geo.size, opacity: 0.24)
            lines(at: [0, 0.25, 0.5, 0.75, 1], in: geo.size, opacity: 0.55)
        }
    }

    /// Horizontal rules at the given fractions of the height. Both passes drew
    /// their own copy of the same loop, differing only in where and how bright.
    private func lines(at fractions: [Double], in size: CGSize,
                       opacity: Double) -> some View {
        Path { path in
            for fraction in fractions {
                let y = size.height * fraction
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(.white.opacity(opacity * brightness), lineWidth: 0.5)
    }
}

/// Histogram of the selected channel(s), 2-code bins (single-code gaps from
/// level remaps would show as a comb), vertical marks at 0/64/128/192/255.
struct HistogramView: View {
    let data: ScopeData
    let channel: String

    var body: some View {
        VStack(spacing: 1) {
            let series = selectedSeries
            // channels stacked in rows — each normalized to its own peak,
            // all three readable at once (nothing blended away)
            ForEach(Array(series.enumerated()), id: \.offset) { index, item in
                GeometryReader { geo in
                    ZStack {
                        let peak = max(1, item.bins.max() ?? 1)
                        channelPath(item.bins, peak: peak, in: geo.size)
                            .fill(LinearGradient(
                                colors: [item.color.opacity(0.85),
                                         item.color.opacity(0.35)],
                                startPoint: .top, endPoint: .bottom))
                        channelPath(item.bins, peak: peak, in: geo.size)
                            .stroke(item.color, lineWidth: 1)
                        Path { p in
                            for mark in [0.0, 0.25, 0.5, 0.75, 1.0] {
                                let x = geo.size.width * mark
                                p.move(to: CGPoint(x: x, y: 0))
                                p.addLine(to: CGPoint(x: x, y: geo.size.height))
                            }
                        }
                        .stroke(.white.opacity(0.14), lineWidth: 0.5)
                        if index == series.count - 1 {
                            HStack {
                                Text("0")
                                Spacer()
                                Text("64")
                                Spacer()
                                Text("128")
                                Spacer()
                                Text("192")
                                Spacer()
                                Text("255")
                            }
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.horizontal, 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
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

    private func smoothed(_ bins: [Int]) -> [Int] {
        // pair bins, then a 1-2-1 pass — kills comb artifacts from quantized
        // sources without washing out the shape
        let paired = stride(from: 0, to: bins.count - 1, by: 2).map {
            bins[$0] + bins[$0 + 1]
        }
        return paired.indices.map { i in
            let left = i > 0 ? paired[i - 1] : paired[i]
            let right = i < paired.count - 1 ? paired[i + 1] : paired[i]
            return (left + paired[i] * 2 + right) / 4
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
