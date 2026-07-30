import CaptureCore
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

/// Scopes window content: enables analysis while the window is on screen.
struct ScopesWindowView: View {
    @EnvironmentObject private var controller: CaptureController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScopesPanel(live: controller.live, onCloseWindow: { dismiss() })
            .onAppear { controller.scopesWindowOpen = true }
            .onDisappear { controller.scopesWindowOpen = false }
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
    @Environment(\.openWindow) private var openWindow
    // scope data updates ~8/s — observed separately from the controller
    @ObservedObject var live: LiveSignal
    /// The in-player overlay fits one scope — enabling one disables the rest
    /// (the separate window keeps the free grid).
    var singleScope = false
    /// Close button for the separate window (nil in the overlay).
    var onCloseWindow: (() -> Void)?

    @AppStorage("scopeWaveformOn") private var waveformOn = true
    @AppStorage("scopeParadeOn") private var paradeOn = false
    @AppStorage("scopeHistogramOn") private var histogramOn = false
    @AppStorage("scopeVectorOn") private var vectorOn = false
    @AppStorage("scopeWaveformChannel") private var waveformChannel = "y"
    @AppStorage("scopeHistogramChannel") private var histogramChannel = "rgb"
    @AppStorage("scopeOrder") private var orderRaw = "waveform,parade,histogram,vector"
    /// Value scale for waveform/parade labels: "100" (%) or "1023" (10-bit).
    @AppStorage("scopeScale") private var scaleMode = "100"
    /// Graticule and trace brightness (0.2…1).
    @AppStorage("scopeGridBrightness") private var gridBrightness = 0.5
    @AppStorage("scopeTraceBrightness") private var traceBrightness = 1.0
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

    private func rawIsOn(_ kind: ScopeKind) -> Binding<Bool> {
        switch kind {
        case .waveform: return $waveformOn
        case .parade: return $paradeOn
        case .histogram: return $histogramOn
        case .vector: return $vectorOn
        }
    }

    private func isOn(_ kind: ScopeKind) -> Binding<Bool> {
        Binding(
            get: { rawIsOn(kind).wrappedValue },
            set: { on in
                if on, singleScope {
                    for other in ScopeKind.allCases where other != kind {
                        rawIsOn(other).wrappedValue = false
                    }
                }
                rawIsOn(kind).wrappedValue = on
            })
    }

    /// Overlay mode shows at most one scope: collapse a multi-selection
    /// left over from the window to the first enabled in the order.
    private func collapseToSingle() {
        guard singleScope else { return }
        var found = false
        for kind in order where rawIsOn(kind).wrappedValue {
            if found {
                rawIsOn(kind).wrappedValue = false
            } else {
                found = true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
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
            Group {
                switch kind {
                case .waveform:
                    WaveformView(data: data, channel: waveformChannel)
                        .opacity(traceBrightness)
                case .parade:
                    ParadeView(data: data)
                        .opacity(traceBrightness)
                case .histogram:
                    HistogramView(data: data, channel: histogramChannel)
                        .opacity(max(0.6, traceBrightness))
                case .vector:
                    VectorscopeView(data: data)
                        .opacity(max(0.6, traceBrightness))
                }
            }
            .environment(\.scopeGridBrightness, gridBrightness)
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
}

// MARK: - panel chrome

/// The toolbar above the scope boxes. In an extension of its own because the
/// panel body was the longest type in the app and this half of it is a separate
/// concern: what the operator switches on, versus what gets drawn.
private extension ScopesPanel {
    /// Panel chrome: the scope toggles plus the display controls.
    ///
    /// One row while it fits, two when it doesn't. The single row needs ~690pt
    /// in English and ~740 in Russian, and the panel declares a 420pt minimum
    /// width — shrink the scopes window and the toggles the operator came for
    /// were the first thing to get clipped.
    var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                toggleRow
                Spacer()
                displayControls
                windowButtons
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    toggleRow
                    Spacer()
                    windowButtons
                }
                HStack(spacing: 6) {
                    displayControls
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder var toggleRow: some View {
        ForEach(order) { kind in
            scopeToggle(L(kind.titleKey), isOn: isOn(kind))
        }
        .onAppear { collapseToSingle() }
    }

    /// Value scale, graticule/trace brightness, and the reorder hint.
    @ViewBuilder var displayControls: some View {
        ChannelPicker(selection: $scaleMode, options: ["100", "1023"])
        HStack(spacing: 3) {
            Image(systemName: "grid")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.45))
            Slider(value: $gridBrightness, in: 0.15...1)
                .frame(width: 56)
                .controlSize(.mini)
        }
        .help(L("scope_grid_brightness"))
        HStack(spacing: 3) {
            Image(systemName: "waveform")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.45))
            Slider(value: $traceBrightness, in: 0.3...1)
                .frame(width: 56)
                .controlSize(.mini)
        }
        .help(L("scope_trace_brightness"))
        // decorative: it truncates rather than wrapping the row onto a
        // second line when the translation is long
        Text(L("scope_drag_hint"))
            .font(.caption2)
            .lineLimit(1)
            .foregroundStyle(.white.opacity(0.3))
    }

    @ViewBuilder var windowButtons: some View {
        if let onCloseWindow {
            Button {
                onCloseWindow()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(L("close"))
        }
        if !controller.scopesWindowOpen {
            Button {
                openWindow(id: "scopes")
                controller.showScopesOverlay = false
            } label: {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(L("scope_open_window"))
        }
    }

    func scopeToggle(_ title: String, isOn: Binding<Bool>) -> some View {
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

    /// Value marks for waveform/parade: percent or 10-bit code values.
    var percentScale: some View {
        let marks: [Int] = scaleMode == "1023"
            ? [1023, 896, 768, 640, 512, 384, 256, 128, 0]
            : [100, 90, 80, 70, 60, 50, 40, 30, 20, 10, 0]
        return VStack(alignment: .trailing, spacing: 0) {
            ForEach(marks, id: \.self) { mark in
                Text("\(mark)")
                    .font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35 + gridBrightness * 0.45))
                    .frame(maxHeight: .infinity,
                           alignment: mark == marks.first ? .top
                               : (mark == 0 ? .bottom : .center))
            }
        }
        .frame(width: 26)
        .frame(maxHeight: .infinity)
    }
}
