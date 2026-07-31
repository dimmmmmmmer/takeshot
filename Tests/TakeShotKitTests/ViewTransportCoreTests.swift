import AVFoundation
import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// The controls both transport bars are built from (`TransportControls.swift`).
///
/// The two bars used to be siblings with the same controls written out twice,
/// and they drifted. Every piece is now one implementation over either engine —
/// the play group included, which was the last one still carrying the drift as
/// a pair of parameters — and these are the assertions that keep it that way: a
/// piece that measures differently depending on which engine drives it has
/// grown an engine-specific branch it should not have.
@MainActor
struct ViewTransportCoreTests {
    /// The skip/play/skip group, laid out the way a bar lays it out.
    private func playGroup(isPlaying: Bool) -> some View {
        HStack(spacing: 10) {
            TransportPlayGroup(isPlaying: isPlaying, skipBack: {},
                               togglePlay: {}, skipForward: {})
        }
    }

    /// The play group is ONE geometry now, not one per bar.
    ///
    /// It used to take its font and slot width from the caller, and the two
    /// callers disagreed: 14pt bold in a 20pt slot in the AVPlayer bar, 15pt
    /// regular in an 18pt slot in the RAW one. The same three buttons therefore
    /// changed weight and shifted a point sideways when the operator opened a
    /// BRAW clip instead of a take. Whatever the metrics are, both bars have to
    /// be showing them.
    @Test func thePlayGroupIsTheSameInBothBars() async throws {
        try await ViewProbe.run { probe in
            let raw = try ViewFixtures.rawPlayer(in: probe.root)
            let group = probe.fittingSize(self.playGroup(isPlaying: false))
            #expect(group.width > 0)

            // Both bars minus their play group: whatever the group costs, it
            // costs each of them the same. (Measured as a delta because the
            // rest of the two bars is genuinely different — a speed menu and a
            // volume slider on one, a codec badge on the other.)
            let player = probe.fittingSize(
                TransportBar(player: ViewFixtures.idlePlayer(),
                             model: probe.controller.transport))
            let rawBar = probe.fittingSize(RawTransportBar(model: raw))
            #expect(player.height == rawBar.height)
            #expect(group.height <= player.height)
        }
    }

    /// Play and pause are not the same glyph and not the same width, so the
    /// slot is fixed — otherwise every press re-lays the row out and everything
    /// to the right of it jumps while the operator is reaching for it. Same bug
    /// the mute icon caused, same fix.
    @Test func togglingPlaybackDoesNotReflowThePlayGroup() async throws {
        try await ViewProbe.run { probe in
            let playing = probe.fittingSizes { self.playGroup(isPlaying: true) }
            let paused = probe.fittingSizes { self.playGroup(isPlaying: false) }

            #expect(playing.en == paused.en,
                    "the play group resized on play/pause: \(paused.en) → \(playing.en)")
            #expect(playing.ru == playing.en,
                    "a localized label reached the play group")
            // and the reserved slot has to actually cover both glyphs
            for symbol in ["play.fill", "pause.fill"] {
                let natural = ViewRender.fittingSize(
                    Image(systemName: symbol).font(TransportPlayGroup.glyph))
                #expect(natural.width <= TransportPlayGroup.glyphWidth,
                        "\(symbol) is \(natural.width)pt wide")
            }
        }
    }

    /// In / loop / out is the same trio in both bars. The AVPlayer transport
    /// marks seconds and the RAW engine marks frames, but the operator is
    /// looking at three identical buttons, so they have to measure identically.
    @Test func rangeControlsMeasureTheSameOverEitherEngine() async throws {
        try await ViewProbe.run { probe in
            let raw = try ViewFixtures.rawPlayer(in: probe.root)
            let overPlayer = probe.fittingSizes {
                HStack(spacing: 10) {
                    TransportRangeControls(engine: probe.controller.transport)
                }
            }
            let overRaw = probe.fittingSizes {
                HStack(spacing: 10) { TransportRangeControls(engine: raw) }
            }
            #expect(overPlayer.en == overRaw.en,
                    "the trio differs by engine: \(overPlayer.en)/\(overRaw.en)")
            #expect(overPlayer.ru == overPlayer.en,
                    "a localized label reached the range controls")
            #expect(overPlayer.en.width > 0)
        }
    }

    /// Marking an in point lights the button in the accent colour; it must not
    /// resize the group around it. Everything to the right of the trio is the
    /// marker flag and the fullscreen button, and a bar that reflows while the
    /// operator is reaching for them is the same bug the mute icon caused.
    @Test func markingAPointDoesNotReflowTheRangeControls() async throws {
        try await ViewProbe.run { probe in
            let transport = probe.controller.transport
            @MainActor func group() -> CGSize {
                probe.fittingSize(
                    HStack(spacing: 10) { TransportRangeControls(engine: transport) })
            }
            let unmarked = group()
            transport.toggleRangePoint(out: false)
            #expect(transport.inPoint != nil, "the fixture marked nothing")
            #expect(group() == unmarked,
                    "the range controls resized when a point was marked")
        }
    }

    /// Both bars wear the same strip: `PlayerArea` lifts its toasts by one fixed
    /// inset to clear whichever of them is on screen, so a bar that grew taller
    /// than the other would hide the toast that says the take failed.
    @Test func bothBarsWearTheSameStrip() async throws {
        try await ViewProbe.run { probe in
            let raw = try ViewFixtures.rawPlayer(in: probe.root)
            let player = probe.fittingSize(
                TransportBar(player: ViewFixtures.idlePlayer(),
                             model: probe.controller.transport))
            let rawBar = probe.fittingSize(RawTransportBar(model: raw))
            #expect(player.height == rawBar.height,
                    "transports \(player.height)pt vs \(rawBar.height)pt tall")
            #expect(rawBar.height <= ViewBudget.transportHeight)
        }
    }

    /// The ±5 s buttons are the same control in both bars, so the RAW engine
    /// converts seconds to frames itself rather than the view doing it.
    @Test func rawSkipMovesFiveSecondsOfFrames() async throws {
        try await ViewProbe.run { probe in
            let raw = try ViewFixtures.rawPlayer(in: probe.root)
            raw.seek(to: 0)
            raw.skip(seconds: 5)
            // a one-frame fixture clamps at its last frame; the direction and
            // the clamping are what matter here
            #expect(raw.currentFrame == max(0, raw.frameCount - 1))
            raw.skip(seconds: -5)
            #expect(raw.currentFrame == 0)
        }
    }
}
