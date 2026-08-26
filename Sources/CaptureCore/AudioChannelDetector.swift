import Foundation

/// Which embedded audio channels are carrying a stream, measured while the app
/// stands by — so a take does not open sixteen tracks for a camera that embeds
/// two.
///
/// **The problem.** The DeckLink API takes 2, 8 or 16 and offers no way to ask
/// how many are really there, so `CDLCapture.embeddedAudioChannels` declares 16
/// and every take used to get a 16-channel track with fourteen channels of
/// nothing in it. The app already sees every one of those channels — the meters
/// read them — so this follows the rule the rest of the project follows: the
/// app does not ask an operator about something it can measure.
///
/// **What is measured, and what deliberately is not.** Two different tests hide
/// under "carried signal", and only one of them can be made honestly here:
///
/// - *Is this channel carrying SOUND?* — a peak above some dBFS floor. This
///   cannot be measured during standby and no choice of floor rescues it.
///   Standby is exactly when a set is quiet: "quiet on set" is called BEFORE
///   the take, so a floor high enough to reject a room reads a working boom as
///   dead. And a floor low enough to accept a quiet room accepts the noise
///   floor of a preamp on a channel nobody has patched — an analogue-fed input
///   that carries nothing still carries its own hiss at around -50 to -60 dBFS,
///   which is where a quiet room sits too. The two are not separable by level.
/// - *Is this channel carrying a STREAM?* — is any sample of it non-zero. This
///   is a fact about the transport rather than about the content, and it is
///   exact: an embedded channel with no source assigned to it is bit-exact zero
///   on every sample (which is what a board fills the declared-but-absent
///   channels of a stereo embed with), while a channel carrying any live
///   converter at all carries its dither.
///
/// So the floor here is not a preference with a number attached: it is
/// `PCMAudio.silenceLevel`, the level the meters already pin exact digital
/// silence at, and the smallest thing that clears it is a single sample of
/// ±1 LSB (-90.3 dBFS). There is nothing to tune, which is the point.
///
/// **The window is about the NEGATIVE half of the answer.** Seeing a channel
/// carry takes one packet. Concluding that a channel is NOT carrying takes long
/// enough that the conclusion means something, and
/// `minimumObservation` = 1.0 s is that: 48 000 consecutive sample frames in
/// which the channel was bit-exact zero. A live stream that is bit-exact zero
/// for a full second is digitally muted, not merely quiet, and there is no
/// sound in it for anyone downstream to recover. One second is also the second
/// the recording-integrity rules already use for the two other audio-shaped
/// timing questions — `TakeWriter.audioStarvationLead` and the frame watchdog's
/// window — and a third number for a third question is how numbers drift.
///
/// **Accumulated, never a sliding window.** "Has this channel ever carried"
/// only becomes more right as standby runs, and it can never drop a channel
/// that carried a minute ago and is between words now. A sliding window would.
///
/// **It answers only with positive evidence.** When nothing has carried at all,
/// this has measured that the SOURCE is silent — not which of its channels are
/// real — and says nothing, so the app records everything exactly as it did
/// before. That is deliberate and it is where the two failure directions are
/// priced: following a signal up costs padded bandwidth, following it down
/// costs footage. It is also what keeps `takeAudioStarved` reachable — the
/// camera muted by mistake delivers no packets at all, which is zero
/// observation, which is no answer, which is the sixteen-channel track the
/// writer's backstop pads and the alarm names.
public struct AudioChannelDetector: Equatable, Sendable {
    /// How much audio must have been observed before the negative half of the
    /// answer is trusted. See the type's note for why one second.
    public static let minimumObservation: Double = 1.0

    /// Bit i set — channel i has carried a non-zero sample since the last
    /// reset. Accumulated, never cleared by a quiet packet.
    public private(set) var carrying: Int = 0
    /// Total duration of the audio this has been shown, in seconds.
    public private(set) var observed: Double = 0
    /// How wide the packets have been. Kept because a change in it is a change
    /// of LAYOUT: channel 3 of an eight-channel embed need not be channel 3 of
    /// the two-channel one that replaced it (the same guess `TakeWriter.conformed`
    /// refuses to make silently), and a mask built from the old width could name
    /// channels the new one does not have — which would be a take with no audio
    /// track where the operator asked for one.
    public private(set) var channelCount: Int = 0

    public init() {}

    /// One packet's per-channel peak levels, as `PCMAudio.peakLevels` reports
    /// them, and how long that packet was.
    ///
    /// The levels are reused rather than re-measured: the audio path already
    /// computes them for the meters on every packet, and a channel that is
    /// bit-exact zero is exactly the one the meters pin at
    /// `PCMAudio.silenceLevel`. So this costs a comparison per channel per
    /// packet and no second pass over the samples.
    public mutating func note(levels: [Float], seconds: Double) {
        guard !levels.isEmpty, seconds > 0 else { return }
        if levels.count != channelCount {
            reset()
            channelCount = levels.count
        }
        for (index, level) in levels.enumerated()
        where index < Int.bitWidth - 1 && level > PCMAudio.silenceLevel {
            carrying |= (1 << index)
        }
        observed += seconds
    }

    /// The channels to record, or nil when this has no answer — too little
    /// observed, or nothing observed carrying. nil means "say nothing", and
    /// the caller then does what it did before this existed.
    public var detectedMask: Int? {
        guard observed >= Self.minimumObservation, carrying != 0 else {
            return nil
        }
        return carrying
    }

    /// A new source is a new layout: the board restarting, the operator
    /// switching between the embed and a USB cart, or a source renegotiating
    /// its own channel count under the app (handled in `note` above).
    ///
    /// `channelCount` is deliberately left alone: it is not evidence, it is
    /// what the evidence is INDEXED by, and `note` sets it in the one place
    /// that knows the new width.
    public mutating func reset() {
        carrying = 0
        observed = 0
    }
}
