import CaptureCore
import CoreGraphics
import SwiftUI

/// Scopes window content: enables analysis while the window is on screen.
struct ScopesWindowView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        ScopesPanel(live: controller.live)
            .onAppear { controller.showScopes = true }
            .onDisappear { controller.showScopes = false }
            .ignoresSafeArea(.container, edges: .top)
    }
}

/// Scopes overlay: waveform, RGB parade, histogram and vectorscope computed
/// from the visible frame (live or playback — whichever mode is active).
/// Each scope toggles individually; waveform/histogram have a channel picker.
struct ScopesPanel: View {
    @EnvironmentObject private var controller: CaptureController
    // scope data updates ~8/s — observed separately from the controller
    @ObservedObject var live: LiveSignal

    @AppStorage("scopeWaveformOn") private var waveformOn = true
    @AppStorage("scopeParadeOn") private var paradeOn = false
    @AppStorage("scopeHistogramOn") private var histogramOn = false
    @AppStorage("scopeVectorOn") private var vectorOn = false
    @AppStorage("scopeWaveformChannel") private var waveformChannel = "y"
    @AppStorage("scopeHistogramChannel") private var histogramChannel = "rgb"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                scopeToggle(L("scope_waveform"), isOn: $waveformOn)
                scopeToggle(L("scope_parade"), isOn: $paradeOn)
                scopeToggle(L("scope_histogram"), isOn: $histogramOn)
                scopeToggle(L("scope_vector"), isOn: $vectorOn)
            }
            if let data = live.scopeData {
                HStack(alignment: .top, spacing: 12) {
                    if waveformOn {
                        ScopeBox(title: L("scope_waveform"),
                                 channel: channelBinding($waveformChannel,
                                                         options: ["y", "rgb", "r", "g", "b"])) {
                            WaveformView(data: data, channel: waveformChannel)
                        } scale: {
                            percentScale
                        }
                    }
                    if paradeOn {
                        ScopeBox(title: L("scope_parade"), channel: nil) {
                            ParadeView(data: data)
                        } scale: {
                            percentScale
                        }
                    }
                    if histogramOn {
                        ScopeBox(title: L("scope_histogram"),
                                 channel: channelBinding($histogramChannel,
                                                         options: ["rgb", "y", "r", "g", "b"])) {
                            HistogramView(data: data, channel: histogramChannel)
                        } scale: {
                            EmptyView()
                        }
                    }
                    if vectorOn {
                        ScopeBox(title: L("scope_vector"), channel: nil) {
                            VectorscopeView(data: data)
                        } scale: {
                            EmptyView()
                        }
                    }
                    if !waveformOn && !paradeOn && !histogramOn && !vectorOn {
                        Text(L("scope_none_hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(L("scope_waiting"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(minWidth: 480, minHeight: 240)
        .background(.black.opacity(0.92))
    }

    private func scopeToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { isOn.wrappedValue.toggle() }
        } label: {
            Text(title)
                .font(.caption2)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(isOn.wrappedValue
                            ? AnyShapeStyle(controller.accentColor.opacity(0.35))
                            : AnyShapeStyle(.white.opacity(0.08)),
                            in: Capsule())
                .foregroundStyle(isOn.wrappedValue ? .white : .white.opacity(0.55))
        }
        .buttonStyle(.plain)
    }

    private func channelBinding(_ storage: Binding<String>,
                                options: [String]) -> ChannelPicker {
        ChannelPicker(selection: storage, options: options)
    }

    /// 0–100% marks for waveform/parade.
    private var percentScale: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([100, 75, 50, 25, 0], id: \.self) { mark in
                Text("\(mark)")
                    .font(.system(size: 7).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxHeight: .infinity,
                           alignment: mark == 100 ? .top : (mark == 0 ? .bottom : .center))
            }
        }
        .frame(width: 16)
        .frame(maxHeight: .infinity)
    }
}

/// Small channel selector shown in a scope's header (Y/RGB/R/G/B).
struct ChannelPicker: View {
    @Binding var selection: String
    let options: [String]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(option.uppercased())
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(selection == option
                                    ? AnyShapeStyle(.white.opacity(0.25))
                                    : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(selection == option
                                         ? .white : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Titled container for a single scope with an optional channel picker and scale.
private struct ScopeBox<Content: View, Scale: View>: View {
    let title: String
    let channel: ChannelPicker?
    @ViewBuilder let content: Content
    @ViewBuilder let scale: Scale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 6)
                if let channel {
                    channel
                }
            }
            HStack(spacing: 2) {
                content
                    .frame(minWidth: 220, maxWidth: .infinity,
                           minHeight: 140, maxHeight: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                scale
            }
        }
    }
}

/// Waveform of the selected channel (or all three in screen blend for "rgb").
private struct WaveformView: View {
    let data: ScopeData
    let channel: String

    var body: some View {
        ZStack {
            switch channel {
            case "r":
                channelImage(data.waveformR, tint: Color(red: 1, green: 0.28, blue: 0.28))
            case "g":
                channelImage(data.waveformG, tint: Color(red: 0.3, green: 1, blue: 0.35))
            case "b":
                channelImage(data.waveformB, tint: Color(red: 0.35, green: 0.55, blue: 1))
            case "rgb":
                channelImage(data.waveformR, tint: Color(red: 1, green: 0.28, blue: 0.28))
                    .blendMode(.screen)
                channelImage(data.waveformG, tint: Color(red: 0.3, green: 1, blue: 0.35))
                    .blendMode(.screen)
                channelImage(data.waveformB, tint: Color(red: 0.35, green: 0.55, blue: 1))
                    .blendMode(.screen)
            default: // "y" — neutral luma trace
                channelImage(data.waveformY, tint: Color(white: 0.95))
            }
            referenceLines(fractions: [0.0, 0.25, 0.5, 0.75, 1.0])
        }
    }

    @ViewBuilder
    private func channelImage(_ bytes: [UInt8], tint: Color) -> some View {
        if let image = grayscaleImage(from: bytes) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.low)
                .colorMultiply(tint)
        }
    }
}

/// RGB parade: three channel waveforms side by side.
private struct ParadeView: View {
    let data: ScopeData

    var body: some View {
        ZStack {
            HStack(spacing: 1) {
                paradeChannel(data.waveformR, tint: Color(red: 1, green: 0.28, blue: 0.28))
                paradeChannel(data.waveformG, tint: Color(red: 0.3, green: 1, blue: 0.35))
                paradeChannel(data.waveformB, tint: Color(red: 0.35, green: 0.55, blue: 1))
            }
            referenceLines(fractions: [0.0, 0.25, 0.5, 0.75, 1.0])
        }
    }

    @ViewBuilder
    private func paradeChannel(_ bytes: [UInt8], tint: Color) -> some View {
        if let image = grayscaleImage(from: bytes) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.low)
                .colorMultiply(tint)
        }
    }
}

/// Histogram of the selected channel(s), rendered in 2-code bins: level
/// remaps leave single-code gaps that would show as a vertical comb.
private struct HistogramView: View {
    let data: ScopeData
    let channel: String

    var body: some View {
        GeometryReader { geo in
            let series = selectedSeries
            ZStack {
                // each channel normalized to its own peak — the composite view
                // matches the single-channel views instead of rescaling them
                ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                    channelPath(item.bins, peak: max(1, item.bins.max() ?? 1),
                                in: geo.size)
                        .fill(item.color.opacity(0.7))
                        .blendMode(.screen)
                }
                // value marks: 0 / 128 / 255
                HStack {
                    Text("0")
                    Spacer()
                    Text("128")
                    Spacer()
                    Text("255")
                }
                .font(.system(size: 7).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
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

    /// 2-code bins (128 bars) — kills the comb from level-remap code gaps.
    private func smoothed(_ bins: [Int]) -> [Int] {
        stride(from: 0, to: bins.count - 1, by: 2).map { bins[$0] + bins[$0 + 1] }
    }

    private func channelPath(_ bins: [Int], peak: Int, in size: CGSize) -> Path {
        Path { p in
            let step = size.width / CGFloat(bins.count)
            p.move(to: CGPoint(x: 0, y: size.height))
            for (i, count) in bins.enumerated() {
                let h = size.height * CGFloat(count) / CGFloat(peak)
                p.addLine(to: CGPoint(x: CGFloat(i) * step, y: size.height - h))
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
        }
    }
}

/// Vectorscope: Cb/Cr density with a graticule (center cross + 75% ring).
private struct VectorscopeView: View {
    let data: ScopeData

    var body: some View {
        ZStack {
            if let image = grayscaleImage(from: data.vector) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.low)
                    .colorMultiply(Color(white: 0.95))
                    .aspectRatio(1, contentMode: .fit)
            }
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let cx = geo.size.width / 2, cy = geo.size.height / 2
                Path { p in
                    p.move(to: CGPoint(x: cx - side / 2, y: cy))
                    p.addLine(to: CGPoint(x: cx + side / 2, y: cy))
                    p.move(to: CGPoint(x: cx, y: cy - side / 2))
                    p.addLine(to: CGPoint(x: cx, y: cy + side / 2))
                }
                .stroke(.white.opacity(0.2), lineWidth: 0.5)
                Circle()
                    .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                    .frame(width: side * 0.75, height: side * 0.75)
                    .position(x: cx, y: cy)
            }
        }
    }
}

/// Horizontal reference lines at the given fractions of the height.
private func referenceLines(fractions: [Double]) -> some View {
    GeometryReader { geo in
        Path { p in
            for fraction in fractions {
                let y = geo.size.height * fraction
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: geo.size.width, y: y))
            }
        }
        .stroke(.white.opacity(0.16), lineWidth: 0.5)
    }
}

/// 256×256 grayscale CGImage from an analyzer density map.
private func grayscaleImage(from bytes: [UInt8]) -> CGImage? {
    let size = ScopeData.size
    guard bytes.count == size * size,
          let provider = CGDataProvider(data: Data(bytes) as CFData) else {
        return nil
    }
    return CGImage(width: size, height: size, bitsPerComponent: 8,
                   bitsPerPixel: 8, bytesPerRow: size,
                   space: CGColorSpaceCreateDeviceGray(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: provider, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)
}
