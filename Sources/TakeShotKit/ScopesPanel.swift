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

    /// Whether the box draws a labelled value scale down its side. Only the two
    /// scopes whose vertical axis IS a signal level have one — a histogram's
    /// vertical axis is a population count and a vectorscope has no vertical
    /// axis at all, so a percent scale beside either would be a lie.
    var showsValueScale: Bool {
        switch self {
        case .waveform, .parade: return true
        case .histogram, .vector: return false
        }
    }

    /// How dim the trace-brightness slider is allowed to make this scope.
    ///
    /// The waveform and the parade are a spray of individual points and stay
    /// legible all the way down. The histogram and the vectorscope are filled
    /// shapes: below about 0.6 they stop reading as anything at all, so they
    /// keep a floor the slider cannot go under.
    var minimumTraceOpacity: Double {
        switch self {
        case .waveform, .parade: return 0
        case .histogram, .vector: return 0.6
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
    @EnvironmentObject var controller: CaptureController
    @Environment(\.openWindow) var openWindow
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
    //
    // The four grid flags stay private; the settings below them are the ones
    // the toolbar in `ScopesPanelChrome` binds to, so they are module-internal
    // — never wider than the module.
    @AppStorage("scopeWaveformOn") private var waveformOn = true
    @AppStorage("scopeParadeOn") private var paradeOn = false
    @AppStorage("scopeHistogramOn") private var histogramOn = false
    @AppStorage("scopeVectorOn") private var vectorOn = false
    /// The overlay's own choice — one `ScopeKind` raw value, "" for none.
    @AppStorage("scopeOverlayKind") var overlayKind = ScopeKind.waveform.rawValue
    @AppStorage("scopeWaveformChannel") var waveformChannel = "y"
    @AppStorage("scopeHistogramChannel") var histogramChannel = "rgb"
    @AppStorage("scopeOrder") var orderRaw = "waveform,parade,histogram,vector"
    /// Value scale for waveform/parade labels: "100" (%) or "1023" (10-bit).
    @AppStorage("scopeScale") var scaleMode = "100"
    /// Graticule and trace brightness (0.2…1).
    @AppStorage("scopeGridBrightness") var gridBrightness = 0.5
    @AppStorage("scopeTraceBrightness") var traceBrightness = 1.0
    /// Skin-tone line on the vectorscope. On by default — it is why most
    /// operators look at a vectorscope at all — but a chart or a colour-bar
    /// check does not want a line across it.
    @AppStorage("scopeSkinTone") var skinToneOn = true
    @State private var dragged: ScopeKind?

    var order: [ScopeKind] {
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
    func isOn(_ kind: ScopeKind) -> Binding<Bool> {
        guard singleScope else { return windowIsOn(kind) }
        return Binding(
            get: { overlayKind == kind.rawValue },
            set: { on in overlayKind = on ? kind.rawValue : "" })
    }

    /// The scopes actually drawn, in the operator's order.
    var visibleScopes: [ScopeKind] {
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

    /// One box: the chrome, whatever the kind draws inside it, and the drag that
    /// reorders it.
    ///
    /// What varies between the four scopes is a table on `ScopeKind` (the value
    /// scale, the brightness floor) and one factory below (`trace`); what varies
    /// between the two surfaces is `singleScope`. Written out as one expression
    /// this was four `case` arms, three ternaries and two conditions in a single
    /// function, and adding a fifth scope meant editing it in four places.
    private func scopeBox(_ kind: ScopeKind, data: ScopeData,
                          of count: Int) -> some View {
        // one scope on screen needs no name and no reorder grip: the toggle
        // above it is the name, and there is nothing to reorder
        let reorderable = !singleScope && count > 1
        return ScopeBox(title: count > 1 ? L(kind.titleKey) : "",
                        showsDragHandle: reorderable,
                        canvasOpacity: singleScope ? 0.85 : 1) {
            boxHeader(for: kind)
        } content: {
            trace(kind, data: data)
                .opacity(max(kind.minimumTraceOpacity, traceBrightness))
                .environment(\.scopeGridBrightness, gridBrightness)
        } scale: {
            if kind.showsValueScale { percentScale }
        }
        .modifier(ScopeReorderDrag(kind: kind, enabled: reorderable,
                                   dragged: $dragged, orderRaw: $orderRaw,
                                   order: order))
    }

    /// The trace itself, and nothing about how it is framed.
    @ViewBuilder
    private func trace(_ kind: ScopeKind, data: ScopeData) -> some View {
        switch kind {
        case .waveform:
            WaveformView(data: data, channel: waveformChannel)
        case .parade:
            ParadeView(data: data)
        case .histogram:
            HistogramView(data: data, channel: histogramChannel)
        case .vector:
            VectorscopeView(data: data, skinToneLine: skinToneOn)
        }
    }
}

/// Drag-to-reorder, installed only where it leads somewhere.
///
/// One box in the overlay used to accept a drag that could not reorder
/// anything, which is the same lie the "drag to reorder" caption told — so the
/// gesture is attached rather than disabled, and the decision lives here rather
/// than as a branch inside the box builder.
private struct ScopeReorderDrag: ViewModifier {
    let kind: ScopeKind
    let enabled: Bool
    @Binding var dragged: ScopeKind?
    @Binding var orderRaw: String
    let order: [ScopeKind]

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    dragged = kind
                    return NSItemProvider(object: kind.rawValue as NSString)
                }
                .onDrop(of: [UTType.plainText], delegate: ScopeDropDelegate(
                    target: kind, dragged: $dragged, orderRaw: $orderRaw,
                    order: order))
        } else {
            content
        }
    }
}
