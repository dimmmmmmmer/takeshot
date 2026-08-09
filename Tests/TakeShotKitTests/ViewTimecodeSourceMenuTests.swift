import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// What the timecode-source menu offers, which is a question about the SIGNAL
/// rather than about the badge it hangs off.
///
/// Its own suite because it arrived from a different direction than the rest of
/// the player chrome — the picker used to offer a hard-coded eight channels
/// while a board embeds up to sixteen — and because putting it beside the
/// chrome tests pushed that type past the length ceiling the moment two waves
/// landed together.
@Suite @MainActor struct ViewTimecodeSourceMenuTests {
    /// The channel list follows the SIGNAL. It used to be `ForEach(1...8)`,
    /// hard-coded, on a board that embeds up to 16 — so an operator whose LTC
    /// was on channel 13 could not select it at all.
    ///
    /// A row here is a promise that the decoder can be pointed at that channel,
    /// which is why the fix is not "8 becomes 16": offering channels the signal
    /// does not carry is the same bug facing the other way.
    @Test func theChannelMenuOffersExactlyWhatTheSignalCarries() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.capture.timecodeSource = "ltc"
            controller.settings.capture.ltcChannel = 12 // ch 13, 0-based
            controller.audioChannelCount = 16
            #expect(PlayerTimecodeBadge.isChannelLive(12, channels: 16),
                    "channel 13 of a 16-channel signal was not offered")
            #expect(PlayerTimecodeBadge.selectionTag(
                isLTC: true, stored: 12, channels: 16) == 13)
            // …and the eight-channel rig the old list assumed still works
            #expect(!PlayerTimecodeBadge.isChannelLive(12, channels: 8))
            #expect(PlayerTimecodeBadge.isChannelLive(7, channels: 8))
        }
    }

    /// No signal: no channel rows, and RP188 is still the selection when that is
    /// what is stored. The menu says why rather than looking as if LTC was
    /// removed (`tc_source_ltc_no_signal`).
    @Test func theChannelMenuWithNoSignalOffersNoChannels() {
        #expect(!PlayerTimecodeBadge.isChannelLive(0, channels: 0))
        #expect(PlayerTimecodeBadge.selectionTag(
            isLTC: false, stored: 0, channels: 0) == 0)
    }

    /// A stored channel the signal cannot provide keeps its own row rather than
    /// being silently re-pointed.
    ///
    /// Both directions of silence are wrong: showing "Ch 1" claims a choice the
    /// operator never made, and showing "Ch 13" among the live rows claims a
    /// channel that is not there. The stale tag is negative, and negative tags
    /// are labels rather than choices — selecting one must not overwrite the
    /// channel an operator is waiting for a signal on.
    @Test func aStoredChannelAboveTheLiveCountIsShownAsUnavailable() {
        // the rig was swapped for a two-channel one
        #expect(PlayerTimecodeBadge.selectionTag(
            isLTC: true, stored: 12, channels: 2) == -1)
        // …and while the signal is down entirely
        #expect(PlayerTimecodeBadge.selectionTag(
            isLTC: true, stored: 12, channels: 0) == -1)
        // a channel that IS there is itself, not the stale row
        #expect(PlayerTimecodeBadge.selectionTag(
            isLTC: true, stored: 1, channels: 2) == 2)
    }

    /// The stale row is a DISPLAY decision and nothing more: the decoder still
    /// clamps to the last channel that exists, so timecode keeps arriving while
    /// the menu says the chosen source is not there.
    @Test func aStaleStoredChannelIsNotRewritten() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.capture.timecodeSource = "ltc"
            controller.settings.capture.ltcChannel = 12
            controller.audioChannelCount = 2
            #expect(PlayerTimecodeBadge.selectionTag(
                isLTC: true, stored: 12, channels: 2) == -1)
            // the signal comes back and the operator's choice is intact
            controller.audioChannelCount = 16
            #expect(controller.settings.capture.ltcChannel == 12,
                    "the picker overwrote the stored channel")
            #expect(PlayerTimecodeBadge.selectionTag(
                isLTC: true, stored: 12, channels: 16) == 13)
        }
    }
}
