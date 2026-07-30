import AppKit
import CaptureCore
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

/// Scopes window content: enables analysis while the window is on screen, and
/// remembers where the operator put the window.
struct ScopesWindowView: View {
    @EnvironmentObject private var controller: CaptureController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScopesPanel(live: controller.live, onCloseWindow: { dismiss() })
            .background(ScopesWindowFrameKeeper(controller: controller))
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
/// and vectorscope.
///
/// Two surfaces, one panel: the separate window holds a grid that wraps to its
/// width and whose boxes drag to reorder, and the in-player overlay holds
/// exactly one scope. Each keeps its own persisted selection.
struct ScopesPanel: View {
    @EnvironmentObject private var controller: CaptureController
    @Environment(\.openWindow) private var openWindow
    // scope data updates ~12-15/s — observed separately from the controller
    @ObservedObject var live: LiveSignal
    /// The in-player overlay: one scope, its own selection, no reordering.
    var singleScope = false
    /// Close button for the separate window (nil in the overlay).
    var onCloseWindow: (() -> Void)?

    // The window's grid and the overlay's single scope keep SEPARATE
    // selections. They used to share these four flags, and opening the overlay
    // collapsed the selection to one scope — which is why the window "never
    // remembered" what the operator had enabled: the overlay had switched the
    // rest off behind its back.
    @AppStorage("scopeWaveformOn") private var waveformOn = true
    @AppStorage("scopeParadeOn") private var paradeOn = false
    @AppStorage("scopeHistogramOn") private var histogramOn = false
    @AppStorage("scopeVectorOn") private var vectorOn = false
    /// The overlay's own choice — one `ScopeKind` raw value, "" for none.
    @AppStorage("scopeOverlayKind") private var overlayKind = ScopeKind.waveform.rawValue
    @AppStorage("scopeWaveformChannel") private var waveformChannel = "y"
    @AppStorage("scopeHistogramChannel") private var histogramChannel = "rgb"
    @AppStorage("scopeOrder") private var orderRaw = "waveform,parade,histogram,vector"
    /// Value scale for waveform/parade labels: "100" (%) or "1023" (10-bit).
    @AppStorage("scopeScale") private var scaleMode = "100"
    /// Graticule and trace brightness (0.2…1).
    @AppStorage("scopeGridBrightness") private var gridBrightness = 0.5
    @AppStorage("scopeTraceBrightness") private var traceBrightness = 1.0
    /// Skin-tone line on the vectorscope. On by default — it is why most
    /// operators look at a vectorscope at all — but a chart or a colour-bar
    /// check does not want a line across it.
    @AppStorage("scopeSkinTone") private var skinToneOn = true
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

    private func windowIsOn(_ kind: ScopeKind) -> Binding<Bool> {
        switch kind {
        case .waveform: return $waveformOn
        case .parade: return $paradeOn
        case .histogram: return $histogramOn
        case .vector: return $vectorOn
        }
    }

    /// One switch per scope. In the overlay the switches are exclusive (it fits
    /// one scope) and write the overlay's own key; in the window each scope has
    /// its own flag and the grid holds however many are on.
    private func isOn(_ kind: ScopeKind) -> Binding<Bool> {
        guard singleScope else { return windowIsOn(kind) }
        return Binding(
            get: { overlayKind == kind.rawValue },
            set: { on in overlayKind = on ? kind.rawValue : "" })
    }

    /// The scopes actually drawn, in the operator's order.
    private var visibleScopes: [ScopeKind] {
        singleScope
            ? [ScopeKind(rawValue: overlayKind)].compactMap { $0 }
            : order.filter { windowIsOn($0).wrappedValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            if let data = live.scopeData {
                let visible = visibleScopes
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
                                            scopeBox(visible[index], data: data,
                                                     of: visible.count)
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
        .background(background)
        // Esc closes the overlay — it has no close button (see
        // PlayerOverlayDismiss for the three mechanisms). The window has its
        // own button and the system's Cmd-W.
        .overlay {
            if singleScope {
                EscapeKeyCatcher { controller.showScopesOverlay = false }
            }
        }
        // scope chrome is white-on-dark whatever the app's appearance is: a
        // light material under it would render the labels invisible
        .environment(\.colorScheme, .dark)
    }

    /// Over the player the panel is translucent so the picture reads through:
    /// one step thinner than the audio panel's `.regularMaterial`, because this
    /// one sits over the part of the frame the operator is still watching while
    /// they read the trace. As a window it is a window — opaque.
    @ViewBuilder private var background: some View {
        if singleScope {
            Rectangle().fill(.ultraThinMaterial)
        } else {
            Color.black.opacity(0.92)
        }
    }

    @ViewBuilder
    private func scopeBox(_ kind: ScopeKind, data: ScopeData,
                          of count: Int) -> some View {
        // one scope on screen needs no name and no reorder grip: the toggle
        // above it is the name, and there is nothing to reorder
        let reorderable = !singleScope && count > 1
        let box = ScopeBox(title: count > 1 ? L(kind.titleKey) : "",
                           showsDragHandle: reorderable,
                           canvasOpacity: singleScope ? 0.85 : 1) {
            boxHeader(for: kind)
        } content: {
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
                    VectorscopeView(data: data, skinToneLine: skinToneOn)
                        .opacity(max(0.6, traceBrightness))
                }
            }
            .environment(\.scopeGridBrightness, gridBrightness)
        } scale: {
            if kind == .waveform || kind == .parade {
                percentScale
            }
        }
        // the drag is installed only where it leads somewhere: one box in the
        // overlay used to accept a drag that could not reorder anything, which
        // is the same lie the "drag to reorder" caption told
        if reorderable {
            box
                .onDrag {
                    dragged = kind
                    return NSItemProvider(object: kind.rawValue as NSString)
                }
                .onDrop(of: [UTType.plainText], delegate: ScopeDropDelegate(
                    target: kind, dragged: $dragged, orderRaw: $orderRaw,
                    order: order))
        } else {
            box
        }
    }

    /// The per-scope controls in a box header: channel choice where a scope has
    /// channels, the skin-tone line where it has one.
    @ViewBuilder
    private func boxHeader(for kind: ScopeKind) -> some View {
        switch kind {
        case .waveform:
            ChannelPicker(selection: $waveformChannel,
                          options: ["y", "rgb", "r", "g", "b"])
        case .histogram:
            ChannelPicker(selection: $histogramChannel,
                          options: ["rgb", "y", "r", "g", "b"])
        case .vector:
            ScopeChipToggle(title: L("scope_skin_tone_short"), isOn: $skinToneOn)
                .help(L("scope_skin_tone"))
        case .parade:
            EmptyView()
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
        // Only where dragging actually does something: the boxes reorder in the
        // separate window, and only when there are at least two of them. The
        // in-player overlay showed this hint while holding exactly one scope
        // that cannot be dragged anywhere — the caption promised a feature the
        // surface does not have.
        if !singleScope, visibleScopes.count > 1 {
            // decorative: it truncates rather than wrapping the row onto a
            // second line when the translation is long
            Text(L("scope_drag_hint"))
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.3))
        }
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
