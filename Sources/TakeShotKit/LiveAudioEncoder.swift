import AudioToolbox
import CaptureCore
@preconcurrency import CoreMedia
import Foundation
// `os` rather than `os.log`: nothing here logs — the failure goes through
// `onFailure` — but the sink registry is an `OSAllocatedUnfairLock`.
import os

/// **One AAC encode, for every live consumer taking the same sound.**
///
/// `LiveVideoEncoder`'s shape one media type along, and it exists for the same
/// arithmetic: the encode is the expensive thing and everything downstream of
/// it is byte shuffling, so it happens once and the ACCESS UNIT is what fans
/// out. Today the transport stream is the only consumer; the reason this is a
/// type rather than three lines inside `SRTMirror` is that the second one
/// is already named — see `CaptureController+NDI`.
///
/// **AAC-LC, and it is a choice about the far end rather than about quality.**
/// An MPEG-TS receiver on a set is ffmpeg, VLC, OBS or a hardware decoder, and
/// AAC in ADTS (`stream_type` 0x0F) is the one thing all four take without
/// being told anything. It is also the one the machine can encode with no
/// third-party library at all: AudioToolbox's converter is a system codec, so
/// this leg compiles and RUNS on a build with no vendor drops, which is not
/// true of either of the other two legs off the tap.
///
/// **The clock is the sound's own sample count, anchored once.** An AAC-LC
/// access unit is exactly 1024 samples, which at 48 kHz on the transport
/// stream's 90 kHz clock is exactly 1920 ticks — so the stamps are an integer
/// series with no rounding in it anywhere, against the same shared `LiveClock`
/// origin the picture is stamped from. Stamping each unit at the moment it came
/// out of the converter instead would put the encoder's own scheduling jitter
/// into the timestamps of a stream whose receiver is trying to resample against
/// them.
///
/// **Nothing here can block the capture queue.** The pipeline's tap hands a
/// packet over and returns; the accumulate and the encode run on THIS queue —
/// never on capture, never on main — and the fan-out happens here, with each
/// sink hopping to whatever queue it owns.
///
/// Nothing here exists while nobody is listening: the controller builds one
/// when the first consumer appears and drops it when the last goes, and the
/// pipeline's tap is registered and removed with it.
final class LiveAudioEncoder: @unchecked Sendable {
    /// One encoded access unit, and what a muxer needs to frame it. The rate
    /// and the count ride WITH the payload rather than being read from a
    /// setting, so an ADTS header cannot describe a stream the converter is not
    /// producing.
    struct AccessUnit: Equatable, Sendable {
        /// Raw AAC, no framing. ADTS is the transport stream's business and is
        /// added in `MPEGTSMuxer` — the same seam `MPEGTSMuxer.accessUnit(from:)`
        /// draws for the picture.
        var payload: [UInt8]
        /// Presentation time on the 90 kHz clock the transport stream uses, and
        /// RTP with it.
        var ticks: Int64
        var sampleRate: Int
        var channels: Int
    }

    /// One consumer's handler. Runs on this encoder's queue; hop.
    typealias Sink = @Sendable (AccessUnit) -> Void

    /// Samples in one AAC-LC access unit. Fixed by the format, not by us.
    static let samplesPerAccessUnit = 1024

    /// The one sample rate this app's audio path has: `PCMAudio` builds every
    /// buffer at 48 kHz and the boards deliver it.
    static let sampleRate = 48_000

    /// Ticks one access unit advances the clock by: 1024 / 48000 × 90000, which
    /// is 1920 exactly. Pinned in the tests rather than trusted, because the
    /// whole "no rounding anywhere" claim is this one division coming out whole.
    static let ticksPerAccessUnit = Int64(samplesPerAccessUnit)
        * Int64(MPEGTSMuxer.clockHz) / Int64(sampleRate)

    /// What a stereo monitoring feed is worth on a venue network. 128 kbit/s
    /// AAC-LC is transparent enough for a director to hear a boom fault and is
    /// 3 % of the video's default bitrate, so it never becomes the reason a link
    /// cannot carry the picture.
    static let defaultBitsPerSecond = 128_000

    /// How far the sound's own clock may fall behind the wall clock before the
    /// anchor is taken again.
    ///
    /// A source that goes away and comes back — a device unplugged, the app
    /// switched from the embedded audio to a USB interface — leaves the sample
    /// count permanently behind, and stamps in the past are what a receiver
    /// answers by holding the sound until its own clock catches up. Half a
    /// second is far longer than any packet jitter this path sees (packets are
    /// 40 ms) and far shorter than the gap any of those events leaves.
    static let resyncTolerance = 0.5

    /// The queue everything runs on. Named so a test can assert the encode is
    /// never on the capture queue — which is what the tap hands over on.
    static let queueLabel = "com.takeshot.audio-encode"

    private let queue = DispatchQueue(label: LiveAudioEncoder.queueLabel,
                                      qos: .userInitiated)
    private let clock: LiveClock
    private let bitsPerSecond: Int
    /// What to say when AudioToolbox will not build a converter at all. Goes
    /// where an operator is already looking, like the video encoder's.
    private let onFailure: @Sendable (String) -> Void

    private let sinks = OSAllocatedUnfairLock<[ObjectIdentifier: Sink]>(
        initialState: [:])

    // MARK: - queue-confined state

    private var converter: AACConverter?
    /// Interleaved 16-bit samples not yet handed to the converter. Never more
    /// than one access unit's worth is left here — the loop drains it.
    private var pending: [Int16] = []
    private var channels = 0
    private var stopped = false
    /// AudioToolbox refused to open a codec, and it is not going to change its
    /// mind. Latched, because without it a machine with no AAC encoder pays a
    /// failing `AudioConverterNew` and a log line twenty-five times a second
    /// for the rest of the session — the "said it once" shape
    /// `CapturePipeline.reportedAudioStarved` already has.
    private var codecUnavailable = false
    /// The 90 kHz stamp the NEXT produced access unit gets; -1 before the
    /// anchor has been taken.
    private var nextTicks: Int64 = -1

    init(bitsPerSecond: Int = LiveAudioEncoder.defaultBitsPerSecond,
         clock: LiveClock = LiveClock(),
         onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.bitsPerSecond = bitsPerSecond
        self.clock = clock
        self.onFailure = onFailure
    }

    // MARK: - consumers

    func addSink(_ owner: AnyObject, _ sink: @escaping Sink) {
        let key = ObjectIdentifier(owner)
        sinks.withLock { $0[key] = sink }
    }

    func removeSink(_ owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        sinks.withLock { _ = $0.removeValue(forKey: key) }
    }

    /// Whether anything is listening. The controller drops the whole encoder —
    /// and with it the pipeline's tap — on this going false.
    var hasSinks: Bool { sinks.withLock { !$0.isEmpty } }

    /// Whether a converter has actually been built. For the tests, and the
    /// distinction is `LiveVideoEncoder.appliedBitsPerSecond`'s: an encoder that
    /// encoded for nobody and one that never built a codec at all look identical
    /// from outside otherwise.
    var hasConverter: Bool { queue.sync { converter != nil } }

    // MARK: - the packet path

    /// Offer one stereo packet. Called on the PIPELINE queue — the capture
    /// queue — by `CapturePipeline`'s audio tap; returns at once.
    func offer(_ packet: CMSampleBuffer) {
        let now = RemoteServer.monotonicNow()
        queue.async { [self] in accept(packet, at: now) }
    }

    /// Tear the converter down. Asynchronous on purpose: an encode may be in
    /// flight and the MainActor must not park behind it.
    func stop() {
        queue.async { [self] in
            stopped = true
            pending.removeAll()
            converter = nil
        }
        sinks.withLock { $0.removeAll() }
    }

    private func accept(_ packet: CMSampleBuffer, at now: TimeInterval) {
        guard !stopped, hasSinks else { return }
        let arrived = PCMAudio.channelCount(of: packet)
        guard arrived > 0, let samples = PCMAudio.interleavedSamples(of: packet)
        else { return }
        // A source that changes its own channel count gets a new converter and
        // a fresh anchor: an AAC stream's channel configuration is stated in
        // every ADTS header, and feeding two counts through one converter is
        // the mis-interleave `TakeWriter.conformed` exists to stop, one path
        // along. Conforming instead would be this file inventing a channel.
        if arrived != channels {
            channels = arrived
            converter = nil
            pending.removeAll()
            nextTicks = -1
        }
        if nextTicks < 0 {
            nextTicks = ticks(at: now)
        } else if ticks(at: now) - nextTicks
            > Int64(Self.resyncTolerance * Double(MPEGTSMuxer.clockHz)) {
            // The sound's clock has fallen behind the wall clock by more than
            // any jitter explains: the source went away and came back.
            nextTicks = ticks(at: now)
        }
        pending += samples
        drain()
    }

    /// Everything the pending samples can make, one access unit at a time.
    ///
    /// The converter is asked for exactly one packet per call and handed
    /// exactly one packet's worth of input, so nothing about the pacing is left
    /// to AudioToolbox's own buffering. Its first call or two legitimately
    /// produce NOTHING — AAC-LC's transform overlaps two windows, so the
    /// encoder is one unit behind its input for the life of the stream — and
    /// that is a constant delay rather than a dropped unit: the stamps advance
    /// per unit PRODUCED, so the series stays whole.
    ///
    /// What that costs is said out loud: a nil that is NOT priming — a
    /// converter that refused one block — is indistinguishable here and is
    /// treated the same way, so 21.3 ms of sound would go missing with the
    /// stamps continuing as if it had not. Never observed; AAC-LC's only
    /// documented nil is the window it is filling, and the alternative
    /// (advancing the clock over a block that produced nothing) would put a
    /// permanent 21.3 ms error into every stamp after it instead.
    private func drain() {
        // A width of zero would make `stride` zero and the loop below endless,
        // on the encode queue, forever. `accept` cannot let that through today
        // — it refuses a packet with no channels in it — and the guard is here
        // rather than trusted because the cost of being wrong is a hung queue
        // and the cost of the guard is one comparison per packet.
        guard channels > 0 else { return }
        let stride = Self.samplesPerAccessUnit * channels
        while pending.count >= stride {
            let block = Array(pending[0..<stride])
            pending.removeFirst(stride)
            guard let codec = converterOrBuild() else {
                // Nothing can be encoded on this machine. Drop what is held
                // rather than growing it without bound — the failure has
                // already been reported and the operator's answer is a setting,
                // not a retry.
                pending.removeAll()
                return
            }
            guard let unit = codec.encode(block) else { continue }
            let frame = AccessUnit(payload: unit, ticks: nextTicks,
                                   sampleRate: Self.sampleRate,
                                   channels: channels)
            nextTicks += Self.ticksPerAccessUnit
            deliver(frame)
        }
    }

    private func converterOrBuild() -> AACConverter? {
        if let converter { return converter }
        guard !codecUnavailable else { return nil }
        do {
            converter = try AACConverter(channels: channels,
                                         bitsPerSecond: bitsPerSecond)
        } catch {
            codecUnavailable = true
            // Reported through the caller's handler and NOT logged here as
            // well: `LiveVideoEncoder` puts the same kind of failure where the
            // operator is already looking, and two records of one event is how
            // a diagnostics bundle starts double-counting.
            onFailure((error as? SRTStreamError)?.message
                ?? error.localizedDescription)
        }
        return converter
    }

    /// The 90 kHz stamp `now` gets, against the SHARED origin — the same
    /// function `LiveVideoEncoder.ticks(at:)` is, so a receiver reading the two
    /// PIDs is reading one clock.
    private func ticks(at now: TimeInterval) -> Int64 {
        Int64((now - clock.origin(at: now)) * Double(MPEGTSMuxer.clockHz))
    }

    /// One access unit to every consumer. The dictionary is copied out under
    /// the lock and walked outside it: a sink that removes itself from inside
    /// its own callback would otherwise deadlock, and a sink is allowed to.
    private func deliver(_ unit: AccessUnit) {
        for sink in sinks.withLock({ Array($0.values) }) { sink(unit) }
    }
}
