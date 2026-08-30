import Foundation

/// How long SRT's delivery buffer has to be, as a function of the link rather
/// than of an operator's guess.
///
/// SRT recovers a lost packet by asking for it again, so the buffer has to hold
/// the picture for at least as long as that round trip takes — several times
/// over, because the re-request can itself be lost. Too small and the picture
/// breaks up on the first loss; too large and everything downstream is late by
/// the difference.
///
/// **It is not a preference** (owner: "пусть это не на пользователе будет а
/// автоматом считается"). The round-trip time is something the link MEASURES
/// and reports — asking an operator on set to know it, in milliseconds, about a
/// network they did not build, is asking them to guess at a number the app is
/// holding. That is the same rule the bit depth and the audio channel mask
/// already follow: where the signal answers, there is no setting.
///
/// The multiplier is SRT's own recommendation (Haivision's tuning guide): four
/// round trips for an ordinary link, which covers a re-request and a retry of
/// it. The floor is what a link inside one building needs regardless — an RTT
/// of a fraction of a millisecond still wants room for a burst — and the
/// ceiling is libsrt's own.
public enum SRTLatency {
    /// Haivision's multiplier for a link with ordinary loss.
    public static let roundTrips = 4.0
    /// Below this, the buffer is too small to absorb a burst whatever the RTT
    /// says. 120 ms is what SRT's own documentation calls the minimum for a
    /// clean local link.
    public static let floorMs = 120
    /// libsrt refuses more than this.
    public static let ceilingMs = 8000

    /// The buffer this link wants, from the round trip it just reported.
    ///
    /// `nil` RTT — no link yet, so no measurement: the floor is the honest
    /// answer, and it is also what a link inside one building settles on.
    public static func recommended(forRTT milliseconds: Double?) -> Int {
        guard let milliseconds, milliseconds.isFinite, milliseconds > 0 else {
            return floorMs
        }
        let wanted = Int((milliseconds * roundTrips).rounded())
        return min(ceilingMs, max(floorMs, wanted))
    }

    /// Whether a measured link wants a BIGGER buffer than the one it is
    /// running with, by enough to be worth reconnecting for.
    ///
    /// The buffer is fixed when the connection is made — libsrt negotiates it
    /// in the handshake — so acting on a new measurement means dropping the
    /// link and remaking it, which costs the far end a gap. A 20 % band keeps
    /// a link whose RTT wanders by a few milliseconds from reconnecting on its
    /// own every time somebody microwaves lunch.
    public static func wantsReconnect(current: Int, forRTT rtt: Double?) -> Bool {
        recommended(forRTT: rtt) > Int(Double(current) * 1.2)
    }
}
