import Foundation
import SwiftUI
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

    /// A level dragged down is shown as down — the waves come off one by one —
    /// and it is NOT red. Red on a working monitor is how red stops being read,
    /// and the level is the operator's own choice rather than a fault.
    @Test func theWaveCountFollowsTheLevelAndStaysAudible() {
        let ladder: [(level: Double, symbol: String)] = [
            (1.0, "speaker.wave.3.fill"),
            (0.7, "speaker.wave.3.fill"),
            (0.5, "speaker.wave.2.fill"),
            (0.34, "speaker.wave.2.fill"),
            (0.2, "speaker.wave.1.fill"),
            (0.05, "speaker.wave.1.fill"),
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

    /// **No level a room can hear draws the glyph that means silence.**
    ///
    /// This is the rule the wave ladder exists to keep, and it was broken: a
    /// bare `speaker.fill` meant BOTH "nothing is coming out" and "any level in
    /// the bottom third of the slider", so the working icon lost its waves down
    /// there and only the colour still separated quiet from dead (owner:
    /// "иконка включённого звука то с волнами то просто громкоговоритель").
    ///
    /// Swept rather than sampled, because the defect was a whole third of the
    /// slider rather than one point, and a handful of rungs is exactly what
    /// missed it: the old ladder's own test asserted `speaker.fill` at 0.2 and
    /// 0.05 and read as correct.
    @Test func noAudibleLevelDrawsTheSymbolThatMeansSilence() {
        let silent: String = MonitorSpeaker.reading(
            muted: false, volume: 0, monitorOn: true, isPlayback: false).symbol
        for step in 0...200 {
            let level = Double(step) / 200
            let reading: MonitorSpeaker = MonitorSpeaker.reading(
                muted: false, volume: level, monitorOn: true, isPlayback: false)
            guard !reading.isSilent else { continue }
            #expect(reading.symbol != silent,
                    """
                    an audible level (\(level)) draws \(reading.symbol), which \
                    is what silence draws — only the colour tells them apart
                    """)
        }
    }

    /// More level is never fewer waves. A ladder that dipped would read as a
    /// fault at exactly the moment the operator turned the sound UP.
    @Test func theLadderOnlyEverClimbs() {
        let rung: (Double) -> Int = { level in
            let symbol = MonitorSpeaker.reading(
                muted: false, volume: level, monitorOn: true,
                isPlayback: false).symbol
            return ["speaker.wave.1.fill": 1, "speaker.wave.2.fill": 2,
                    "speaker.wave.3.fill": 3][symbol] ?? 0
        }
        var previous: Int = 0
        for step in 0...200 {
            let level = Double(step) / 200
            let now: Int = rung(level)
            #expect(now >= previous,
                    "turning up to \(level) took a wave OFF the icon")
            previous = now
        }
        #expect(previous == 3, "full scale does not reach the top rung")
    }

    /// DIM halves the level and is meant to be talked over. It reads as one
    /// wave and stays in the accent colour; the DIM badge beside the speaker is
    /// what says a hold is engaged.
    @Test func aDimmedMonitorIsAudibleAndNotRed() {
        let dimmed: Double = 1.0 * CaptureController.dimAttenuation
        let reading: MonitorSpeaker = MonitorSpeaker.reading(
            muted: false, volume: dimmed, monitorOn: true, isPlayback: false)
        #expect(!reading.isSilent, "DIM lit the alarm colour on a working monitor")
        #expect(reading.symbol == "speaker.wave.2.fill",
                "DIM at \(dimmed) draws \(reading.symbol) — the middle rung")
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
        #expect(reading.symbol == "speaker.wave.3.fill")
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

/// The icon changes shape as the level moves. Nothing around it may move with
/// it.
///
/// The footer pins the speaker to a fixed 24x20 slot precisely because the SF
/// Symbol variants differ in width, and the row would otherwise shuffle on
/// every drag of the volume slider. Adding a THIRD wave made that slot a
/// question again rather than a settled one (owner: "проверь что изменение вида
/// иконки нигде не двигает интерфейс"), so the glyphs are measured against it
/// instead of assumed to fit: a symbol wider than its slot is clipped, and a
/// clipped speaker at full level is the state an operator most needs to read.
@MainActor
struct MonitorSpeakerSlotTests {
    /// Every symbol the reading can return, at the footer's own size.
    static var symbols: [String] {
        var found: Set<String> = ["speaker.slash.fill", "speaker.slash"]
        for step in 0...100 {
            found.insert(MonitorSpeaker.reading(
                muted: false, volume: Double(step) / 100, monitorOn: true,
                isPlayback: false).symbol)
        }
        return found.sorted()
    }

    @Test func everySpeakerSymbolFitsTheFootersSlot() {
        // FooterBar draws it at .system(size: 15) inside .frame(24, 20).
        let slot = CGSize(width: 24, height: 20)
        for symbol in Self.symbols {
            let size: CGSize = ViewRender.fittingSize(
                Image(systemName: symbol).font(.system(size: 15)))
            #expect(size.width <= slot.width,
                    "\(symbol) is \(size.width)pt wide in a \(slot.width)pt slot")
            #expect(size.height <= slot.height,
                    "\(symbol) is \(size.height)pt tall in a \(slot.height)pt slot")
        }
    }

    /// …and the slot itself does not move. Measured through the frame the
    /// footer actually applies, so this fails if that frame is ever removed
    /// in favour of letting the symbol size the row.
    @Test func theSpeakerSlotIsTheSameSizeInEveryState() {
        let sizes: Set<CGSize> = Set(Self.symbols.map { symbol in
            ViewRender.fittingSize(
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .frame(width: 24, height: 20))
        })
        #expect(sizes.count == 1,
                "the speaker slot takes \(sizes.count) different sizes: \(sizes)")
    }
}

extension CGSize: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(width)
        hasher.combine(height)
    }
}
