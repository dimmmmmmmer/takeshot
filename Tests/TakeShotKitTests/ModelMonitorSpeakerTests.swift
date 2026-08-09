import Foundation
import Testing

@testable import TakeShotKit

/// The footer speaker's reading, asserted as the state function it is.
///
/// No window and no controller: `MonitorSpeaker.reading` is a pure function of
/// four facts, which is the whole reason it was extracted. Three controls draw
/// this icon — the footer, the audio channel panel and the playback transport —
/// and each used to carry its own copy of the rule; what the copies disagreed
/// about is pinned here so they cannot drift again.
///
/// Main-actor only because two assertions read `CaptureController`'s DIM
/// constant, which belongs to the actor the controller does; the function under
/// test needs no actor at all.
@MainActor
struct MonitorSpeakerTests {
    /// The complaint that produced the rule: the slider taken to the bottom
    /// drew the SLASHED symbol in the accent colour, i.e. the colour that means
    /// "on and working" everywhere else in the footer. Silence is red now,
    /// whichever of the three ways the operator got there.
    @Test func silenceIsRedHoweverItWasReached() {
        let muted: MonitorSpeaker = MonitorSpeaker.reading(
            muted: true, volume: 0.8, monitorOn: true, isPlayback: false)
        let atZero: MonitorSpeaker = MonitorSpeaker.reading(
            muted: false, volume: 0, monitorOn: true, isPlayback: false)
        let monitorOff: MonitorSpeaker = MonitorSpeaker.reading(
            muted: false, volume: 0.8, monitorOn: false, isPlayback: false)

        #expect(muted.isSilent, "the mute hold is not red")
        #expect(atZero.isSilent, "a slider parked at zero is not red")
        #expect(monitorOff.isSilent, "the live monitor switched off is not red")
    }

    /// …and the three are still told APART, by the symbol. That is what the
    /// colour used to be doing, and it is the weaker of the two channels: a
    /// mute is a hold with a restore point, a slider at zero is a level the
    /// operator chose, and `LiveSignal.muted` exists to keep them separate.
    @Test func theSymbolSaysWhichKindOfSilenceItIs() {
        let muted: MonitorSpeaker = MonitorSpeaker.reading(
            muted: true, volume: 0.8, monitorOn: true, isPlayback: false)
        let atZero: MonitorSpeaker = MonitorSpeaker.reading(
            muted: false, volume: 0, monitorOn: true, isPlayback: false)
        let monitorOff: MonitorSpeaker = MonitorSpeaker.reading(
            muted: false, volume: 0.8, monitorOn: false, isPlayback: false)

        #expect(muted.symbol == "speaker.slash.fill",
                "the mute hold draws \(muted.symbol)")
        #expect(atZero.symbol == "speaker.fill",
                "a slider at zero draws \(atZero.symbol) — the mute's own symbol")
        #expect(monitorOff.symbol == "speaker.slash",
                "the switched-off monitor draws \(monitorOff.symbol)")
        let symbols: Set<String> = [muted.symbol, atZero.symbol, monitorOff.symbol]
        #expect(symbols.count == 3, "two silences render identically")
    }

    /// A level dragged down is shown as down — the waves come off — and it is
    /// NOT red. Red on a working monitor is how red stops being read, and the
    /// level is the operator's own choice rather than a fault.
    @Test func theWaveCountFollowsTheLevelAndStaysAudible() {
        let ladder: [(level: Double, symbol: String)] = [
            (1.0, "speaker.wave.2.fill"),
            (0.7, "speaker.wave.2.fill"),
            (0.5, "speaker.wave.1.fill"),
            (0.34, "speaker.wave.1.fill"),
            (0.2, "speaker.fill"),
            (0.05, "speaker.fill"),
        ]
        for rung in ladder {
            let reading: MonitorSpeaker = MonitorSpeaker.reading(
                muted: false, volume: rung.level, monitorOn: true,
                isPlayback: false)
            #expect(reading.symbol == rung.symbol,
                    "level \(rung.level) draws \(reading.symbol)")
            #expect(!reading.isSilent,
                    "level \(rung.level) is audible and must not be red")
        }
    }

    /// DIM halves the level and is meant to be talked over. It reads as one
    /// wave and stays in the accent colour; the DIM badge beside the speaker is
    /// what says a hold is engaged.
    @Test func aDimmedMonitorIsAudibleAndNotRed() {
        let dimmed: Double = 1.0 * CaptureController.dimAttenuation
        let reading: MonitorSpeaker = MonitorSpeaker.reading(
            muted: false, volume: dimmed, monitorOn: true, isPlayback: false)
        #expect(!reading.isSilent, "DIM lit the alarm colour on a working monitor")
        #expect(reading.symbol == "speaker.wave.1.fill",
                "DIM at \(dimmed) draws \(reading.symbol)")
    }

    /// A slider dragged to the bottom does not always land on exactly zero, and
    /// -40 dB is not a level a room hears. The icon calls it silence rather
    /// than claiming a wave the operator cannot hear.
    @Test func anInaudibleLevelCountsAsSilence() {
        let barelyOn: MonitorSpeaker = MonitorSpeaker.reading(
            muted: false, volume: MonitorSpeaker.silenceLevel, monitorOn: true,
            isPlayback: false)
        let justAbove: MonitorSpeaker = MonitorSpeaker.reading(
            muted: false, volume: MonitorSpeaker.silenceLevel * 2,
            monitorOn: true, isPlayback: false)
        #expect(barelyOn.isSilent,
                "\(MonitorSpeaker.silenceLevel) of full scale is not called silence")
        #expect(!justAbove.isSilent)
        #expect(MonitorSpeaker.silenceLevel < CaptureController.dimAttenuation,
                "the silence threshold has climbed above DIM's own level")
    }

    /// In playback there is no live monitor path, so `monitorOn` says nothing
    /// about what the operator hears — the player's volume does.
    @Test func playbackIgnoresTheLiveMonitorSwitch() {
        let reading: MonitorSpeaker = MonitorSpeaker.reading(
            muted: false, volume: 0.9, monitorOn: false, isPlayback: true)
        #expect(!reading.isSilent,
                "playback went red on a switch that only applies to the live feed")
        #expect(reading.symbol == "speaker.wave.2.fill")
    }

    /// The mute is answered first: one click undoes it, so it is the useful
    /// answer even when the level under it is also zero.
    @Test func theMuteHoldIsReportedAheadOfWhatIsUnderIt() {
        let reading: MonitorSpeaker = MonitorSpeaker.reading(
            muted: true, volume: 0, monitorOn: false, isPlayback: false)
        #expect(reading.symbol == "speaker.slash.fill",
                "a mute over a dead path drew \(reading.symbol)")
        #expect(reading.isSilent)
    }
}
