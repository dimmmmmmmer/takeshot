import AppKit
import CaptureCore
import CoreVideo
import SwiftUI
import Testing

@testable import TakeShotKit

/// The scopes panel with actual traces in it, in both languages.
///
/// The existing chrome tests render the panel with no data, so only the toolbar
/// ever laid out. Everything below the toolbar — the boxes, the box headers, the
/// value scale, the vectorscope — first appears when `live.scopeData` does, and
/// that is where the labels the operator complained about live.
@MainActor
struct ViewScopesTests {
    /// Real analyzer output: a gradient frame put through `ScopeAnalyzer`, so
    /// the traces, the histogram and the vectorscope all have content.
    private static func scopeData() throws -> ScopeData {
        let width = 320, height = 180
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base + y * rowBytes
            for x in 0..<width {
                row[x * 4] = UInt8(x * 255 / (width - 1))          // B
                row[x * 4 + 1] = UInt8(y * 255 / (height - 1))     // G
                row[x * 4 + 2] = 96                                // R
                row[x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return try #require(ScopeAnalyzer.analyze(buffer))
    }

    /// Turn on exactly these scopes in the window's persisted selection.
    private func window(_ probe: ViewProbe, scopes: [ScopeKind]) {
        for (kind, key) in [(ScopeKind.waveform, "scopeWaveformOn"),
                            (.parade, "scopeParadeOn"),
                            (.histogram, "scopeHistogramOn"),
                            (.vector, "scopeVectorOn")] {
            probe.store.set(scopes.contains(kind), forKey: key)
        }
    }

    /// The overlay, traces and all, still has to fit the 860pt the player gives
    /// it — in Russian too.
    @Test func theOverlayWithTracesFitsThePlayer() async throws {
        let data = try Self.scopeData()
        try await ViewProbe.run { probe in
            probe.controller.live.scopeData = data
            let laid = probe.sizes(proposedWidth: ViewBudget.scopesOverlayWidth,
                                   proposedHeight: 320) {
                ScopesPanel(live: probe.controller.live, singleScope: true)
            }
            #expect(laid.ru.width <= ViewBudget.scopesOverlayWidth,
                    "the overlay overflowed: \(laid)")
            #expect(laid.ru == laid.en, "overlay with traces: \(laid)")
            #expect(laid.ru.height > 0)
        }
    }

    /// Every scope kind renders on its own in the overlay, in both languages —
    /// the box header differs per kind (channel picker, skin-tone chip, nothing).
    @Test func everyScopeKindRendersAlone() async throws {
        let data = try Self.scopeData()
        try await ViewProbe.run { probe in
            probe.controller.live.scopeData = data
            for kind in ScopeKind.allCases {
                probe.store.set(kind.rawValue, forKey: "scopeOverlayKind")
                let laid = probe.sizes(proposedWidth: 600, proposedHeight: 300) {
                    ScopesPanel(live: probe.controller.live, singleScope: true)
                }
                #expect(laid.ru == laid.en, "\(kind.rawValue) overlay: \(laid)")
                #expect(laid.ru.width == 600)
            }
        }
    }

    /// The reorder hint belongs to the window with several boxes in it. The
    /// overlay holds one scope and cannot reorder anything, so its chrome is the
    /// window's minus that caption — which is what this measures.
    @Test func onlyTheReorderableGridAdvertisesDragging() async throws {
        let data = try Self.scopeData()
        try await ViewProbe.run { probe in
            probe.controller.live.scopeData = data
            window(probe, scopes: [.waveform, .parade])
            let grid = probe.fittingSizes {
                ScopesPanel(live: probe.controller.live)
            }
            let overlay = probe.fittingSizes {
                ScopesPanel(live: probe.controller.live, singleScope: true)
            }
            // the overlay should be narrower by exactly the drag hint
            #expect(overlay.en.width < grid.en.width,
                    "overlay chrome \(overlay.en.width), grid \(grid.en.width)")
            #expect(overlay.ru.width < grid.ru.width)

            // one box in the window: nothing to reorder there either
            window(probe, scopes: [.waveform])
            let single = probe.fittingSizes {
                ScopesPanel(live: probe.controller.live)
            }
            #expect(single.en.width < grid.en.width)
        }
    }

    /// The separate window's grid: two scopes side by side inside its default
    /// 980pt, in both languages.
    @Test func theWindowGridFitsItsDefaultSize() async throws {
        let data = try Self.scopeData()
        try await ViewProbe.run { probe in
            probe.controller.live.scopeData = data
            probe.controller.scopesWindowOpen = true
            window(probe, scopes: [.waveform, .vector])
            let laid = probe.sizes(proposedWidth: 980, proposedHeight: 380) {
                ScopesPanel(live: probe.controller.live, onCloseWindow: {})
            }
            #expect(laid.ru.width == 980, "the window grid overflowed: \(laid)")
            #expect(laid.ru == laid.en, "window grid: \(laid)")
        }
    }

    /// Opening the in-player overlay must not touch the window's selection —
    /// the two used to share one set of switches, and the overlay switched the
    /// others off as it appeared.
    @Test func theOverlayDoesNotDisturbTheWindowSelection() async throws {
        let data = try Self.scopeData()
        try await ViewProbe.run { probe in
            probe.controller.live.scopeData = data
            window(probe, scopes: [.waveform, .parade, .vector])
            _ = probe.size(ScopesPanel(live: probe.controller.live,
                                       singleScope: true),
                           proposedWidth: 860, proposedHeight: 320)
            #expect(probe.store.bool(forKey: "scopeWaveformOn"))
            #expect(probe.store.bool(forKey: "scopeParadeOn"))
            #expect(probe.store.bool(forKey: "scopeVectorOn"))
        }
    }

    /// The skin-tone line is graticule, not layout: switching it off may not
    /// move anything.
    @Test func theSkinToneLineDoesNotChangeTheLayout() async throws {
        let data = try Self.scopeData()
        try await ViewProbe.run { probe in
            let on = probe.size(VectorscopeView(data: data, skinToneLine: true),
                                proposedWidth: 300, proposedHeight: 300)
            let off = probe.size(VectorscopeView(data: data, skinToneLine: false),
                                 proposedWidth: 300, proposedHeight: 300)
            #expect(on == off, "vectorscope geometry changed: \(on) vs \(off)")
        }
    }

    /// Esc closes the in-player overlay, which deliberately has no close button.
    ///
    /// The key equivalent is delivered the way AppKit delivers it — through
    /// `performKeyEquivalent` on the hosting view — so this covers the actual
    /// mechanism (an invisible `Button`), not just the flag it sets.
    @Test func escapeClosesTheOverlay() async throws {
        let data = try Self.scopeData()
        try await ViewProbe.run { probe in
            probe.controller.live.scopeData = data
            probe.controller.showScopesOverlay = true

            let host = NSHostingView(rootView: AnyView(probe.hosted(
                ScopesPanel(live: probe.controller.live, singleScope: true))))
            host.frame = CGRect(x: 0, y: 0, width: 700, height: 300)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            let escape = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false, keyCode: 53))
            #expect(host.performKeyEquivalent(with: escape),
                    "nothing in the overlay claimed Esc")
            #expect(!probe.controller.showScopesOverlay)
        }
    }

    /// A single scope carries no name and no reorder grip, so its box has no
    /// header row at all — that row is what the operator saw as a caption
    /// repeating the name of the only scope on screen.
    @Test func aScopeBoxWithNothingToSayDropsItsHeader() async throws {
        try await ViewProbe.run { probe in
            func box(title: String, handle: Bool) -> some View {
                ScopeBox(title: title, showsDragHandle: handle) {
                    EmptyView()
                } content: {
                    Color.black
                } scale: {
                    EmptyView()
                }
            }
            // the ideal size, not a proposed one: the canvas stretches to fill
            // whatever height it is offered, so only the ideal shows the row
            let bare = probe.fittingSize(box(title: "", handle: false))
            let named = probe.fittingSize(box(title: "Waveform", handle: true))
            #expect(bare.height < named.height,
                    "the header row is still there: \(bare) vs \(named)")
        }
    }
}
