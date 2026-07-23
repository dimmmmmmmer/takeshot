import CaptureCore
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

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

/// The scope kinds, in user-configurable order.
enum ScopeKind: String, CaseIterable, Identifiable {
    case waveform, parade, histogram, vector
    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .waveform: return "scope_waveform"
        case .parade: return "scope_parade"
        case .histogram: return "scope_histogram"
        case .vector: return "scope_vector"
        }
    }
}

/// Scopes: waveform (image-colored luma or per-channel), RGB parade, histogram
/// and vectorscope. Toggle each on/off, drag boxes to reorder; the grid wraps
/// to the window width.
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
    @AppStorage("scopeOrder") private var orderRaw = "waveform,parade,histogram,vector"
    @State private var dragged: ScopeKind?

    private var order: [ScopeKind] {
        var kinds = orderRaw.split(separator: ",").compactMap {
            ScopeKind(rawValue: String($0))
        }
        for kind in ScopeKind.allCases where !kinds.contains(kind) {
            kinds.append(kind)
        }
        return kinds
    }

    private func isOn(_ kind: ScopeKind) -> Binding<Bool> {
        switch kind {
        case .waveform: return $waveformOn
        case .parade: return $paradeOn
        case .histogram: return $histogramOn
        case .vector: return $vectorOn
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(order) { kind in
                    scopeToggle(L(kind.titleKey), isOn: isOn(kind))
                }
                Spacer()
                Text(L("scope_drag_hint"))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.3))
            }
            if let data = live.scopeData {
                let visible = order.filter { isOn($0).wrappedValue }
                if visible.isEmpty {
                    Text(L("scope_none_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { geo in
                        let columns = max(1, min(visible.count,
                                                 Int(geo.size.width / 360)))
                        let rows = (visible.count + columns - 1) / columns
                        Grid(horizontalSpacing: 12, verticalSpacing: 10) {
                            ForEach(0..<rows, id: \.self) { row in
                                GridRow {
                                    ForEach(0..<columns, id: \.self) { col in
                                        let index = row * columns + col
                                        if index < visible.count {
                                            scopeBox(visible[index], data: data)
                                        } else {
                                            Color.clear
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                Text(L("scope_waiting"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(minWidth: 420, minHeight: 260)
        .background(.black.opacity(0.92))
    }

    @ViewBuilder
    private func scopeBox(_ kind: ScopeKind, data: ScopeData) -> some View {
        ScopeBox(title: L(kind.titleKey), channel: channelPicker(for: kind)) {
            switch kind {
            case .waveform:
                WaveformView(data: data, channel: waveformChannel)
            case .parade:
                ParadeView(data: data)
            case .histogram:
                HistogramView(data: data, channel: histogramChannel)
            case .vector:
                VectorscopeView(data: data)
            }
        } scale: {
            if kind == .waveform || kind == .parade {
                percentScale
            }
        }
        .onDrag {
            dragged = kind
            return NSItemProvider(object: kind.rawValue as NSString)
        }
        .onDrop(of: [UTType.plainText], delegate: ScopeDropDelegate(
            target: kind, dragged: $dragged, orderRaw: $orderRaw, order: order))
    }

    private func channelPicker(for kind: ScopeKind) -> ChannelPicker? {
        switch kind {
        case .waveform:
            return ChannelPicker(selection: $waveformChannel,
                                 options: ["y", "rgb", "r", "g", "b"])
        case .histogram:
            return ChannelPicker(selection: $histogramChannel,
                                 options: ["rgb", "y", "r", "g", "b"])
        default:
            return nil
        }
    }

    private func scopeToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { isOn.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isOn.wrappedValue
                      ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 8))
                Text(title)
            }
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

    /// 0–100% marks for waveform/parade.
    private var percentScale: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([100, 75, 50, 25, 0], id: \.self) { mark in
                Text("\(mark)")
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxHeight: .infinity,
                           alignment: mark == 100 ? .top : (mark == 0 ? .bottom : .center))
            }
        }
        .frame(width: 18)
        .frame(maxHeight: .infinity)
    }
}

/// Drag-to-reorder for scope boxes.
private struct ScopeDropDelegate: DropDelegate {
    let target: ScopeKind
    @Binding var dragged: ScopeKind?
    @Binding var orderRaw: String
    let order: [ScopeKind]

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target,
              let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: target) else { return }
        var kinds = order
        kinds.move(fromOffsets: IndexSet(integer: from),
                   toOffset: to > from ? to + 1 : to)
        orderRaw = kinds.map(\.rawValue).joined(separator: ",")
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
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
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.3))
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
                    .frame(minWidth: 260, maxWidth: .infinity,
                           minHeight: 150, maxHeight: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                scale
            }
        }
    }
}

/// Waveform of the selected channel: "y" is the luma trace colored by the
/// image itself; single channels and the RGB composite are channel-tinted.
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
            default: // "y" — luma trace carrying the image's color
                if let image = rgbaImage(from: data.waveformYColor) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                }
            }
            waveformGraticule
        }
    }

    @ViewBuilder
    private func channelImage(_ bytes: [UInt8], tint: Color) -> some View {
        if let image = grayscaleImage(from: bytes) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.medium)
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
            waveformGraticule
        }
    }

    @ViewBuilder
    private func paradeChannel(_ bytes: [UInt8], tint: Color) -> some View {
        if let image = grayscaleImage(from: bytes) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.medium)
                .colorMultiply(tint)
        }
    }
}

/// Dense waveform graticule: a line every 10%, stronger at 0/50/100.
private var waveformGraticule: some View {
    GeometryReader { geo in
        Path { p in
            for i in stride(from: 0.0, through: 1.0, by: 0.1) {
                let y = geo.size.height * i
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: geo.size.width, y: y))
            }
        }
        .stroke(.white.opacity(0.12), lineWidth: 0.5)
        Path { p in
            for i in [0.0, 0.5, 1.0] {
                let y = geo.size.height * i
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: geo.size.width, y: y))
            }
        }
        .stroke(.white.opacity(0.28), lineWidth: 0.5)
    }
}

/// Histogram of the selected channel(s), 2-code bins (single-code gaps from
/// level remaps would show as a comb), vertical marks at 0/64/128/192/255.
private struct HistogramView: View {
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
                        channelPath(item.bins, peak: max(1, item.bins.max() ?? 1),
                                    in: geo.size)
                            .fill(item.color.opacity(0.75))
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

/// Vectorscope: chroma density colored by its own hue, rings at 25/50/75%,
/// 75% primary/secondary targets and the skin-tone line.
private struct VectorscopeView: View {
    let data: ScopeData
    // rebuilding the colored map is a 65k-cell loop — cache it per frame so a
    // window resize doesn't recompute it on every layout pass
    @State private var cached: (sequence: Int, image: CGImage)?

    /// Hue for every (Cb, Cr) cell — computed once. Saturation follows the
    /// radius, so near-neutral chroma reads near-white instead of screaming.
    private static let hueLUT: [UInt8] = {
        let size = ScopeData.vectorSize
        var lut = [UInt8](repeating: 0, count: size * size * 3)
        for row in 0..<size {
            let cr = (Double(size) / 2 - Double(row)) * 255 / Double(size)
            for col in 0..<size {
                let cb = (Double(col) - Double(size) / 2) * 255 / Double(size)
                var r = 1.5748 * cr
                var g = -0.1873 * cb - 0.4681 * cr
                var b = 1.8556 * cb
                let peak = max(abs(r), abs(g), abs(b), 1)
                let saturation = min(1.0, (cb * cb + cr * cr).squareRoot() / 60)
                r = 255 * (1 - saturation) + (r / peak * 127 + 128) * saturation
                g = 255 * (1 - saturation) + (g / peak * 127 + 128) * saturation
                b = 255 * (1 - saturation) + (b / peak * 127 + 128) * saturation
                let i = (row * size + col) * 3
                lut[i] = UInt8(max(0, min(255, r)))
                lut[i + 1] = UInt8(max(0, min(255, g)))
                lut[i + 2] = UInt8(max(0, min(255, b)))
            }
        }
        return lut
    }()

    /// 75% color-bar targets — positioned by the exact same chroma math the
    /// analyzer plots with, so bars land on their boxes.
    private static let targets: [(String, CGFloat, CGFloat)] = {
        func point(_ r: Int, _ g: Int, _ b: Int) -> (CGFloat, CGFloat) {
            let (cb, cr) = ScopeAnalyzer.chroma(r: Double(r), g: Double(g),
                                                b: Double(b))
            return (CGFloat(0.5 + cb / 255), CGFloat(0.5 - cr / 255))
        }
        let v = 191 // 75%
        let r = point(v, 0, 0), g = point(0, v, 0), b = point(0, 0, v)
        let cy = point(0, v, v), mg = point(v, 0, v), yl = point(v, v, 0)
        return [("R", r.0, r.1), ("G", g.0, g.1), ("B", b.0, b.1),
                ("Cy", cy.0, cy.1), ("Mg", mg.0, mg.1), ("Yl", yl.0, yl.1)]
    }()

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let cx = geo.size.width / 2, cy = geo.size.height / 2
            ZStack {
                if let image = cachedVector() {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: side, height: side)
                        .position(x: cx, y: cy)
                }
                // rings + cross + skin-tone line
                ForEach([0.25, 0.5, 0.75], id: \.self) { ring in
                    Circle()
                        .strokeBorder(.white.opacity(ring == 0.75 ? 0.3 : 0.15),
                                      lineWidth: 0.5)
                        .frame(width: side * ring, height: side * ring)
                        .position(x: cx, y: cy)
                }
                Path { p in
                    p.move(to: CGPoint(x: cx - side / 2, y: cy))
                    p.addLine(to: CGPoint(x: cx + side / 2, y: cy))
                    p.move(to: CGPoint(x: cx, y: cy - side / 2))
                    p.addLine(to: CGPoint(x: cx, y: cy + side / 2))
                    // skin-tone line (~33° up-left of the +Cr axis)
                    p.move(to: CGPoint(x: cx, y: cy))
                    p.addLine(to: CGPoint(x: cx - side * 0.26, y: cy - side * 0.40))
                }
                .stroke(.white.opacity(0.22), lineWidth: 0.5)
                ForEach(Self.targets, id: \.0) { name, tx, ty in
                    let px = cx - side / 2 + tx * side
                    let py = cy - side / 2 + ty * side
                    Rectangle()
                        .strokeBorder(.white.opacity(0.5), lineWidth: 0.7)
                        .frame(width: 7, height: 7)
                        .position(x: px, y: py)
                    Text(name)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .position(x: px + 9, y: py - 7)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cachedVector() -> CGImage? {
        if let cached, cached.sequence == data.sequence { return cached.image }
        guard let image = coloredVector() else { return nil }
        // @State mutation during body is deferred by SwiftUI; this is a cache
        DispatchQueue.main.async { cached = (data.sequence, image) }
        return image
    }

    /// Density map × hue LUT → RGBA image.
    private func coloredVector() -> CGImage? {
        let size = ScopeData.vectorSize
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        let lut = Self.hueLUT
        for i in 0..<(size * size) {
            let density = Int(data.vector[i])
            guard density > 0 else { continue }
            rgba[i * 4] = UInt8(Int(lut[i * 3]) * density / 255)
            rgba[i * 4 + 1] = UInt8(Int(lut[i * 3 + 1]) * density / 255)
            rgba[i * 4 + 2] = UInt8(Int(lut[i * 3 + 2]) * density / 255)
            rgba[i * 4 + 3] = 255
        }
        return rgbaImage(from: rgba, width: size, height: size)
    }
}

/// Grayscale CGImage from an analyzer density map.
private func grayscaleImage(from bytes: [UInt8],
                            width: Int = ScopeData.waveWidth,
                            height: Int = ScopeData.waveHeight) -> CGImage? {
    guard bytes.count == width * height,
          let provider = CGDataProvider(data: Data(bytes) as CFData) else {
        return nil
    }
    return CGImage(width: width, height: height, bitsPerComponent: 8,
                   bitsPerPixel: 8, bytesPerRow: width,
                   space: CGColorSpaceCreateDeviceGray(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: provider, decode: nil,
                   shouldInterpolate: true, intent: .defaultIntent)
}

/// RGBA CGImage from analyzer bytes.
private func rgbaImage(from bytes: [UInt8],
                       width: Int = ScopeData.waveWidth,
                       height: Int = ScopeData.waveHeight) -> CGImage? {
    guard bytes.count == width * height * 4,
          let provider = CGDataProvider(data: Data(bytes) as CFData) else {
        return nil
    }
    return CGImage(width: width, height: height, bitsPerComponent: 8,
                   bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(
                       rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil,
                   shouldInterpolate: true, intent: .defaultIntent)
}
