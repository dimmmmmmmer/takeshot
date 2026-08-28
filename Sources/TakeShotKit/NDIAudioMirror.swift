import CaptureCore
@preconcurrency import CoreMedia
import Foundation
// `os` rather than `os.log`: the refused-packet line goes through `os_log`,
// and the backlog is an `OSAllocatedUnfairLock`.
import os

/// The sound leg of the NDI source, on a queue of its own.
///
/// **It is a leg off a tap that already exists, and that is the whole shape of
/// this file.** `CapturePipeline.feedStereo` builds ONE stereo mix per packet —
/// after `recordAudio`, so nothing it does can reach the file — and hands the
/// same `CMSampleBuffer` to the cart's speakers and to every registered
/// consumer, whatever `monitorEnabled` says. `LiveAudioEncoder` is the leg SRT
/// takes off it (AAC, a second PID); this is NDI's, and the only thing that
/// differs is what happens to the samples afterwards. There is no second tap,
/// no second mix and no second channel rule here — the channels are the first
/// two ENABLED by the mask in force, decided once in `stereoChannelIndices`, so
/// what goes out is always a prefix of what is being written and a single
/// enabled channel travels MONO rather than doubled.
///
/// **The conversion, which is the one thing this leg really does.** The tap
/// produces interleaved signed 16-bit PCM; `NDIlib_send_send_audio_v3` takes
/// `NDIlib_FourCC_audio_type_FLTP`, which is DE-INTERLEAVED 32-bit float — so
/// each packet is scaled by 1/32768 and split into one contiguous plane per
/// channel. Both halves of that are unavoidable and neither is a choice this
/// app makes: FLTP is the only uncompressed layout the v3 frame carries, and
/// float is what NDI's own codec wants. It happens HERE, on this queue, and not
/// in the bridge and not on the capture queue — the bridge is handed bytes that
/// are already the wire's, and the capture queue pays a bounds test and a
/// `dispatch_async`.
///
/// **Every packet goes, and nothing is coalesced. That is the difference from
/// the picture leg and it is deliberate.** `NDIVideoMirror` keeps only the
/// newest frame, because a monitor wants fewer frames rather than older ones.
/// Sound has no such freedom: NDI synthesizes the audio timecode from the
/// samples it is given, so a dropped packet is 40 ms that never arrives AND a
/// permanent shift of everything after it against the picture. So this queue is
/// a FIFO, and what protects it from a wedged receiver is a ceiling on the
/// backlog rather than a policy of dropping. Past the ceiling the packet is
/// refused and counted — which is a gap in the sound of a monitoring feed, and
/// only ever happens when the receiver has already stopped taking sound at all.
///
/// **Nothing here can reach the file.** The tap runs after `recordAudio` on a
/// packet the writer has already been handed, this object never sees the
/// pipeline, and `NDIAudioRecordIdentityTests` shoots the same take twice — in
/// two channel configurations, one of which hands this leg the writer's very
/// own buffer — to say so in bytes.
///
/// The mirror exists only while the NDI switch is on: `CaptureController` builds
/// it beside the video mirror and drops it with it, and with it gone the
/// pipeline has no NDI consumer on the tap at all.
final class NDIAudioMirror: @unchecked Sendable {
    /// The queue the conversion and the send run on. Named so a test can assert
    /// the send is not on the capture queue — and specifically not on the
    /// picture's, which is the claim the two legs' independence rests on.
    static let queueLabel = "com.takeshot.ndi-audio"

    /// How much sound may be waiting on this queue before a packet is refused.
    ///
    /// One second, counted in SAMPLE FRAMES rather than packets so the ceiling
    /// does not move with the packet size the source happens to deliver. The
    /// number is chosen against the failure it exists for: a receiver taking
    /// sound normally leaves this at one packet's worth, and a send parked for
    /// a whole second is a receiver that has stopped, not one that is behind.
    /// A second of stereo is 384 KB held, which is the memory this bound is
    /// really about.
    static let backlogCeilingFrames = 48_000

    /// How often the refused-packet count is logged.
    ///
    /// Logged and not shown, on `SRTMirror.dropLogInterval`'s reasoning: the
    /// operator has nothing to change — there is no audio dial on this feed —
    /// and a counter ticking in the settings window would re-render it for news
    /// nobody can act on. The diagnostics bundle is where it belongs.
    static let dropLogInterval = 50

    private let queue = DispatchQueue(label: NDIAudioMirror.queueLabel,
                                      qos: .userInitiated)
    private let sender: NDISending

    /// The backlog, and the only state the CAPTURE queue touches.
    ///
    /// An unfair lock rather than the send queue, because the whole point is
    /// that the caller does not wait: the tap adds a packet's frames here and
    /// dispatches, and the send queue takes them off again when the packet has
    /// gone. `LiveVideoEncoder.hasSinks` pays the same primitive per frame at
    /// 60 Hz against this path's 25.
    private let backlog = OSAllocatedUnfairLock(initialState: Backlog())

    private struct Backlog {
        var frames = 0
        var dropped = 0
        var stopped = false
    }

    init(sender: NDISending) {
        self.sender = sender
    }

    /// How many packets the ceiling has refused. For the tests and the log; a
    /// non-zero value means the receiver stopped taking sound.
    var droppedPackets: Int { backlog.withLock { $0.dropped } }

    /// Offer one stereo packet. Called on the PIPELINE queue — the capture
    /// queue — by `CapturePipeline`'s audio tap; returns at once.
    ///
    /// What the capture queue pays is this whole function: a sample count off
    /// the buffer, one uncontended lock, and a `dispatch_async`. The read of
    /// the samples, the conversion and the send are all on the other side of
    /// that hop, which is what keeps an NDI receiver off the queue that owns
    /// the file.
    func offer(_ packet: CMSampleBuffer) {
        let frames = CMSampleBufferGetNumSamples(packet)
        guard frames > 0 else { return }
        // One lock acquisition on the capture queue, and it answers both
        // questions: admitted, and — when it was not — how many have been
        // refused, so the log below needs no second read of the same state.
        //
        // `stopped` is deliberately NOT tested here as well. It would be a
        // second guard with no observable of its own — the packets it would
        // turn away are the ones `send` already refuses — and a line no test
        // can fail is a line that quietly stops being true. Nothing arrives
        // after a stop in any case: `stopNDIAudio` removes the tap FIRST.
        let refused: Int? = backlog.withLock { state in
            guard state.frames + frames <= Self.backlogCeilingFrames else {
                state.dropped += 1
                return state.dropped
            }
            state.frames += frames
            return nil
        }
        if let refused {
            if refused > 0, refused % Self.dropLogInterval == 0 {
                os_log("NDI audio: %d packets refused, backlog ceiling %d frames",
                       refused, Self.backlogCeilingFrames)
            }
            return
        }
        queue.async { [self] in
            send(packet, frames: frames)
        }
    }

    /// Stop sending, and deliberately do NOT take the source off the network:
    /// one sender is one source, and the leg that announced it is the leg that
    /// ends it (`NDIVideoMirror.stop`). A second teardown here would be this
    /// queue destroying an instance the picture's queue may be inside.
    ///
    /// The flag is set synchronously under the lock rather than on the send
    /// queue, which is what makes it reach a send that is already QUEUED
    /// behind a wedged one: an `async` teardown would be ordered after those
    /// and every one of them would go out first.
    func stop() {
        backlog.withLock { $0.stopped = true }
    }

    // MARK: - the send queue

    private func send(_ packet: CMSampleBuffer, frames: Int) {
        defer { backlog.withLock { $0.frames -= frames } }
        guard !backlog.withLock({ $0.stopped }),
              let converted = Self.planarFloat(from: packet) else { return }
        sender.send(audio: converted.planes,
                    framesPerChannel: converted.framesPerChannel,
                    channels: converted.channels,
                    sampleRate: converted.sampleRate)
    }

    /// One packet in the shape NDI's FLTP frame describes: `channels`
    /// contiguous planes of `framesPerChannel` samples, one after another.
    ///
    /// A type rather than a tuple because it is the conversion's whole answer
    /// and every field of it reaches the wire — a four-member tuple would put
    /// the channel count and the rate one position apart from each other at
    /// every call site, and both are `Int`.
    struct PlanarPacket: Equatable, Sendable {
        var planes: [Float]
        var framesPerChannel: Int
        var channels: Int
        var sampleRate: Int
    }

    // MARK: - the conversion

    /// One packet as NDI wants it: planes of 32-bit float, one after another.
    ///
    /// A pure static function of the packet, which is what makes the one piece
    /// of real arithmetic on this leg testable with no sender, no SDK and no
    /// network — the same reason `NDIFrameRate` is a value type.
    ///
    /// nil for anything that is not interleaved 16-bit PCM with samples in it.
    /// Refused rather than reinterpreted, for `sendFrame:`'s reason one media
    /// type along: a float read of 16-bit samples is not quiet sound, it is a
    /// read of twice the bytes that are there.
    static func planarFloat(from packet: CMSampleBuffer) -> PlanarPacket? {
        guard let format = CMSampleBufferGetFormatDescription(packet),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                  format)?.pointee,
              asbd.mBitsPerChannel == 16 else { return nil }
        let channels = Int(asbd.mChannelsPerFrame)
        // The rate is read off the packet rather than assumed to be 48 kHz.
        // `PCMAudio` builds every buffer at that today, and an NDI frame
        // DECLARES its rate — so a hard-coded number is a lie waiting for the
        // day the pipeline's is not the number written here.
        let sampleRate = Int(asbd.mSampleRate.rounded())
        guard channels > 0, sampleRate > 0,
              let samples = PCMAudio.interleavedSamples(of: packet)
        else { return nil }
        let frames = samples.count / channels
        guard frames > 0 else { return nil }

        // Signed 16-bit full scale is 32768, which puts −32768 on exactly −1.0
        // and 32767 a half-LSB inside +1.0. The asymmetric alternative
        // (dividing by 32767) makes a full-scale negative sample clip at the
        // one code a limiter is most likely to have put there.
        let scale = Float(1.0 / 32768.0)
        let planes = [Float](
            unsafeUninitializedCapacity: frames * channels) { buffer, count in
            samples.withUnsafeBufferPointer { source in
                for channel in 0..<channels {
                    let plane = channel * frames
                    for frame in 0..<frames {
                        buffer[plane + frame] =
                            Float(source[frame * channels + channel]) * scale
                    }
                }
            }
            count = frames * channels
        }
        return PlanarPacket(planes: planes, framesPerChannel: frames,
                            channels: channels, sampleRate: sampleRate)
    }
}
