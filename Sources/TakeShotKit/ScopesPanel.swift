import AppKit
import CaptureCore
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

/// Scopes window content: enables analysis while the window is on screen, and
/// remembers where the operator put the window.
struct ScopesWindowView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        // `topInset` is the strip the window buttons live over: with the app's
        // own chrome the content runs to the top of the window, and without it
        // the traffic lights sit on top of the first scope toggle. Same
        // measured value the main window reserves.
        ScopesPanel(scopes: controller.scopes,
                    topInset: controller.windowTopInset)
            .ignoresSafeArea(.container, edges: .top)
            .background(ScopesWindowFrameKeeper(controller: controller))
            // The window's own chrome, styled like the main window's and the
            // VANC monitor's — buttons over the content, no title strip.
            .monolithicWindowChrome()
            .onAppear { controller.scopesWindowOpen = true }
            .onDisappear { controller.scopesWindowOpen = false }
    }
}

/// The scope kinds, in user-configurable order.
enum ScopeKind: String, CaseIterable, Identifiable {
    case waveform, parade, histogram, vector, cie
    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .waveform: return "scope_waveform"
        case .parade: return "scope_parade"
        case .histogram: return "scope_histogram"
        case .vector: return "scope_vector"
        case .cie: return "scope_cie"
        }
    }

    /// How dim the trace-brightness slider is allowed to make this scope.
    ///
    /// The waveform and the parade are a spray of individual points and stay
    /// legible all the way down. The histogram, the vectorscope and the
    /// chromaticity chart are filled shapes: below about 0.6 they stop reading
    /// as anything at all, so they keep a floor the slider cannot go under.
    var minimumTraceOpacity: Double {
        switch self {
        case .waveform, .parade: return 0
        case .histogram, .vector, .cie: return 0.6
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
    /// Scope data updates 12-15/s and NOTHING else does — observed separately
    /// from both the controller and `LiveSignal`, whose timecode and audio
    /// meters would otherwise re-run this body two to eight times per analysis.
    @ObservedObject var scopes: ScopeFeed
    /// The in-player overlay: one scope, its own selection, no reordering.
    var singleScope = false
    /// Room reserved above the toolbar for the window buttons (window only).
    var topInset: CGFloat = 0

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
    @AppStorage("scopeCIEOn") private var cieOn = false
    /// The overlay's own choice — one `ScopeKind` raw value, "" for none.
    @AppStorage("scopeOverlayKind") var overlayKind = ScopeKind.waveform.rawValue
    @AppStorage("scopeWaveformChannel") var waveformChannel = "y"
    @AppStorage("scopeHistogramChannel") var histogramChannel = "rgb"
    @AppStorage("scopeOrder") var orderRaw = "waveform,parade,histogram,vector,cie"
    /// Value scale for waveform/parade labels: "100" (%) or "1023" (10-bit).
    @AppStorage("scopeScale") var scaleMode = "100"
    /// Graticule and trace brightness (0.2…1).
    @AppStorage("scopeGridBrightness") var gridBrightness = 0.5
    @AppStorage("scopeTraceBrightness") var traceBrightness = 1.0
    /// Skin-tone line on the vectorscope. On by default — it is why most
    /// operators look at a vectorscope at all — but a chart or a colour-bar
    /// check does not want a line across it.
    @AppStorage("scopeSkinTone") var skinToneOn = true
    /// The chromaticity chart's second gamut triangle — the one the signal is
    /// NOT in. On by default: "does this Rec.2020 source leave Rec.709" is the
    /// question the chart answers that no other scope can, and it has no answer
    /// at all unless both triangles are on it. Off for a chart being read on
    /// its own terms, where the second triangle is a line through the trace.
    @AppStorage("scopeCIEGamuts") var cieOtherGamutOn = true
    @State private var dragged: ScopeKind?
    /// The order while a box is being dragged, before it is committed.
    ///
    /// The reorder used to write `orderRaw` — an `@AppStorage` — from
    /// `dropEntered`, and `dropEntered` fires again every time the boxes move
    /// under the pointer, which is exactly what the write causes. Each tick was
    /// a synchronous `UserDefaults` write plus a full republish of the panel:
    /// the grid relaid out, every box rebuilt, every trace image re-read from
    /// the cache — during a drag, at pointer rate. It is `@State` now and the
    /// defaults are written once, on drop.
    @State private var dragOrder: [ScopeKind]?

    var order: [ScopeKind] {
        if let dragOrder { return dragOrder }
        return storedOrder
    }

    /// The persisted order, which is what a drop commits back to.
    var storedOrder: [ScopeKind] {
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
        case .cie: return $cieOn
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
            if let data = scopes.data {
                let visible = visibleScopes
                if visible.isEmpty {
                    Text(L("scope_none_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { geo in
                        let columns = ScopeGridLayout.columns(
                            for: visible.count, in: geo.size)
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
        .padding(.top, topInset)
        .frame(minWidth: 420, minHeight: 260)
        .background(background)
        // Esc and a click on the picture also close the overlay (see
        // PlayerOverlayDismiss); the button in the toolbar is the visible one.
        // The WINDOW has no button of its own — it has a real title bar with a
        // real close button, and a second X inside the content was one close
        // control too many.
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
                .environment(\.scopeScaleMode, ScopeScaleMode(setting: scaleMode))
        }
        .modifier(ScopeReorderDrag(kind: kind, enabled: reorderable,
                                   dragged: $dragged, live: $dragOrder,
                                   commit: commitDragOrder, order: order))
    }

    /// End of a drag: the order the operator arranged becomes the stored one.
    /// The only `UserDefaults` write the whole gesture makes.
    private func commitDragOrder() {
        if let dragOrder, dragOrder != storedOrder {
            orderRaw = dragOrder.map(\.rawValue).joined(separator: ",")
        }
        dragOrder = nil
        dragged = nil
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
        case .cie:
            CIEChartView(data: data, showsOtherGamut: cieOtherGamutOn)
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
    /// The arrangement being dragged, held in view state until the drop.
    @Binding var live: [ScopeKind]?
    let commit: () -> Void
    let order: [ScopeKind]

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    // A drag released outside every box never reaches
                    // `performDrop`, so the arrangement it left behind is
                    // banked here rather than lost at the next launch.
                    commit()
                    dragged = kind
                    return NSItemProvider(object: kind.rawValue as NSString)
                }
                .onDrop(of: [UTType.plainText], delegate: ScopeDropDelegate(
                    target: kind, dragged: $dragged, live: $live,
                    commit: commit, order: order))
        } else {
            content
        }
    }
}
