import Foundation

/// What the speaker icon says about the monitoring path — which symbol, and
/// whether it is the red one — as one value the three controls that draw it
/// share.
///
/// The footer, the big audio panel and the playback transport each spelled this
/// out for themselves, and they had already drifted: the transport has no "the
/// live monitor is switched off" state at all, and all three painted a slider
/// parked at ZERO in the accent colour — the colour the DIM badge and every
/// other footer control use for "engaged and working" — while drawing the
/// slashed symbol that says the room hears nothing. Lowering the level to the
/// bottom therefore lit the icon in the same colour as a monitor at full
/// (owner item: "lowering the volume does not turn the icon red").
///
/// The rule, stated once:
///
/// - **Red is silence, whatever put it there** — the mute HOLD, a level at the
///   bottom of the slider, or the live monitor switched off in record mode.
///   "Why can't I hear it" is the question the colour answers on a shooting
///   day, so it answers it for all three ways of getting there.
/// - **The symbol says WHICH of the three, and how much level there is.** A
///   slashed speaker is a hold (filled: muted; hollow: the monitor path is
///   off); an unslashed one carries the level as its wave count, down to no
///   waves at all. A mute and a slider at zero are still told apart at a
///   glance — `LiveSignal.muted` exists for exactly that reason — by the
///   symbol rather than by the colour, which is the stronger of the two
///   distinctions and the one macOS's own volume control uses.
/// - **DIM is not red, and neither is a level merely turned down.** DIM halves
///   the monitoring level so the crew can be talked over: it is audible by
///   design, its own badge says it is engaged, and an alarm colour on a working
///   monitor is how an alarm colour stops being read. A hand-set low level is
///   shown as low — one wave, then none — and never as a fault.
struct MonitorSpeaker: Equatable {
    /// At or below this the monitor is not reproducing anything a room can
    /// hear. -40 dB on what is a linear amplitude, and not `== 0` on purpose:
    /// a slider dragged to the bottom does not always land exactly on zero, and
    /// an icon still claiming a wave at 0.4 % is the same lie one code point up.
    static let silenceLevel = 0.01

    /// The SF Symbol to draw.
    let symbol: String
    /// Nothing is reaching the room: the icon is red.
    let isSilent: Bool

    /// Read the monitoring path.
    ///
    /// - Parameters:
    ///   - muted: the mute HOLD (`LiveSignal.muted`) — not "the level is zero".
    ///   - volume: the one shared monitoring level, 0…1.
    ///   - monitorOn: the live monitor path, which exists in record mode only.
    ///   - isPlayback: the viewer is showing a clip, so `monitorOn` says nothing
    ///     about what the operator hears — the player's own volume does.
    static func reading(muted: Bool, volume: Double, monitorOn: Bool,
                        isPlayback: Bool) -> MonitorSpeaker {
        // The hold first: it is the one state a single click undoes, so it is
        // the answer worth giving even when the level under it is also zero.
        if muted { return MonitorSpeaker(symbol: "speaker.slash.fill", isSilent: true) }
        // …then the path, for the same reason in reverse: with nothing routed
        // the level is not what is stopping the sound, and showing it would
        // point the operator at the wrong control.
        if !isPlayback, !monitorOn {
            return MonitorSpeaker(symbol: "speaker.slash", isSilent: true)
        }
        if volume <= silenceLevel {
            return MonitorSpeaker(symbol: "speaker.fill", isSilent: true)
        }
        return MonitorSpeaker(symbol: waveSymbol(for: volume), isSilent: false)
    }

    /// How many waves a level gets. The ladder has three rungs — two waves, one
    /// wave, none — so the scale is split in thirds. DIM's half level lands on
    /// one wave, which is exactly what DIM does to the sound.
    private static func waveSymbol(for volume: Double) -> String {
        if volume > 2.0 / 3.0 { return "speaker.wave.2.fill" }
        if volume > 1.0 / 3.0 { return "speaker.wave.1.fill" }
        return "speaker.fill"
    }
}
