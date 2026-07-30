import AVFoundation
import AppKit
import SwiftUI
import Testing

@testable import TakeShotKit

/// Guards both transport bars and the marker controls in them. The transport is
/// a translucent strip laid over the bottom of the player, and `PlayerArea`
/// lifts its toasts by a fixed 52pt to clear it: a bar that grows a second row
/// in one language hides the toast that says the take failed.
@MainActor
struct ViewTransportTests {
    /// Nothing in the AVPlayer transport is a localized string — every control
    /// is an SF Symbol, a monospaced timecode or a rate number, and the
    /// localization is all in `.help()` tooltips. So it must measure identically
    /// in both languages.
    @Test func transportMeasuresTheSameInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes {
                TransportBar(player: ViewFixtures.idlePlayer(),
                             model: probe.controller.transport)
            }
            #expect(ideal.ru == ideal.en,
                    "a localized label reached the transport bar: \(ideal)")
            #expect(ideal.ru.width > 0 && ideal.ru.height > 0)
        }
    }

    /// The bar has to fit under the player at the narrowest window, and stay
    /// inside the 52pt PlayerArea reserves for it.
    @Test func transportFitsThePlayerStrip() async throws {
        try await ViewProbe.run { probe in
            let laid = probe.sizes(proposedWidth: ViewBudget.transportWidth) {
                TransportBar(player: ViewFixtures.idlePlayer(),
                             model: probe.controller.transport)
            }
            let inset = ViewBudget.transportHeight
            #expect(laid.ru.height <= inset,
                    "transport is \(laid.ru.height)pt tall, toast inset \(inset)")
            #expect(laid.ru.width == ViewBudget.transportWidth)

            let ideal = probe.fittingSizes {
                TransportBar(player: ViewFixtures.idlePlayer(),
                             model: probe.controller.transport)
            }
            let strip = ViewBudget.transportWidth
            #expect(ideal.ru.width <= strip,
                    "transport wants \(ideal.ru.width)pt of \(strip)")
        }
    }

    /// Markers add three more controls to a bar that is already full. With
    /// markers on the clip the bar still has to fit its strip, in both
    /// languages.
    @Test func transportWithMarkersStillFitsTheStrip() async throws {
        try await ViewProbe.run { probe in
            try ViewFixtures.seedPlaybackWithMarkers(probe.controller,
                                                     in: probe.root)
            let ideal = probe.fittingSizes {
                TransportBar(player: ViewFixtures.idlePlayer(),
                             model: probe.controller.transport)
            }
            #expect(ideal.ru == ideal.en)
            #expect(ideal.ru.width <= ViewBudget.transportWidth)
            #expect(ideal.ru.height <= ViewBudget.transportHeight)
        }
    }

    /// The RAW engine gets its own transport with the same job and the same
    /// 52pt of room. It is built on a one-frame CinemaDNG folder, which needs
    /// no SDK and no hardware.
    @Test func rawTransportFitsThePlayerStrip() async throws {
        try await ViewProbe.run { probe in
            let model = try ViewFixtures.rawPlayer(in: probe.root)
            let ideal = probe.fittingSizes { RawTransportBar(model: model) }
            #expect(ideal.ru == ideal.en,
                    "a localized label reached the RAW transport: \(ideal)")
            #expect(ideal.ru.width <= ViewBudget.transportWidth)
            #expect(ideal.ru.height <= ViewBudget.transportHeight)
        }
    }

    /// The marker flag, the prev/next arrows and the count sit inline in both
    /// transports; all icons, so the group must not change with the language.
    @Test func markerButtonGroupIsLocaleIndependent() async throws {
        try await ViewProbe.run { probe in
            try ViewFixtures.seedPlaybackWithMarkers(probe.controller,
                                                     in: probe.root)
            let ideal = probe.fittingSizes { HStack { MarkerButton() } }
            #expect(ideal.ru == ideal.en)
            #expect(ideal.ru.width > 0)
        }
    }

    /// The speaker icon in the transport has two variants and they are neither
    /// the same width nor the same height. Without a reserved frame the bar
    /// re-laid itself out around the icon and every control to the right of it
    /// jumped a couple of points on each mute — owner item 25.
    @Test func mutingDoesNotReflowTheTransportBar() async throws {
        try await ViewProbe.run { probe in
            @MainActor func bar() -> (en: CGSize, ru: CGSize) {
                probe.fittingSizes {
                    TransportBar(player: ViewFixtures.idlePlayer(),
                                 model: probe.controller.transport)
                }
            }
            probe.controller.live.volume = 0.5
            let loud = bar()
            let loudVolume = probe.fittingSizes {
                TransportVolume(live: probe.controller.live)
            }
            probe.controller.live.volume = 0
            let muted = bar()
            let mutedVolume = probe.fittingSizes {
                TransportVolume(live: probe.controller.live)
            }

            #expect(muted.en == loud.en,
                    "the transport bar reflowed on mute: \(loud.en) → \(muted.en)")
            #expect(mutedVolume.en == loudVolume.en,
                    "the volume control resized on mute: \(mutedVolume.en)")
            #expect(muted.ru == muted.en)

            // the reserved frame has to actually cover the wider variant, or the
            // symbol draws outside its own slot
            for symbol in ["speaker.slash.fill", "speaker.wave.2.fill"] {
                let natural = ViewRender.fittingSize(
                    Image(systemName: symbol).font(.system(size: 11)))
                #expect(natural.width <= TransportVolume.iconWidth,
                        "\(symbol) is \(natural.width)pt wide")
                #expect(natural.height <= TransportVolume.iconHeight,
                        "\(symbol) is \(natural.height)pt tall")
            }
        }
    }

    /// The marker editor popover is a grid of fixed columns — a 76pt name, a
    /// swatch, a timecode button, a 180pt note field. Its localized parts are
    /// the header, "Clear all" and the "Marker %d" fallback, none of which may
    /// change the popover's geometry.
    @Test func markerEditorGeometryIsLocaleIndependent() async throws {
        try await ViewProbe.run { probe in
            try ViewFixtures.seedPlaybackWithMarkers(probe.controller,
                                                     in: probe.root)
            let ideal = probe.fittingSizes { MarkerListEditor() }
            #expect(ideal.ru == ideal.en,
                    "the marker editor changed size with the language: \(ideal)")
            // two markers, a header row and a divider
            #expect(ideal.ru.height > 60)
            #expect(ideal.ru.width > 300)
        }
    }
}
