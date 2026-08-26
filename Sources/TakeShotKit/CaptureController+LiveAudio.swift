import CaptureCore
import Foundation
import os.log

/// **The sound half of "one encoder, several transports".**
///
/// `CaptureController+LivePictures` is the picture's version of this file and
/// the rule is the same one, with the pool collapsed to a single instance
/// because there is only ever one sound to encode (see
/// `DisplayMirrors.liveAudioEncoder`):
///
/// - Nothing listening costs nothing worth measuring. No AAC encoder exists, no
///   tap is registered on the pipeline, and `CapturePipeline.feedStereo`
///   returns before it builds a mix — measured in release at 17.4 µs for the
///   whole audio path against 21.4 with a transport on it, on a packet that
///   arrives every 40 ms.
/// - A second transport taking sound costs no second encode — one more sink on
///   a converter that was going to run anyway.
/// - The tap and the encoder are created and dropped TOGETHER, in this file and
///   nowhere else, so a tap left registered over a dead encoder is not a state
///   the app can reach.
///
/// **The tap is what makes this independent of the cart's speakers**, which is
/// the whole reason it exists: `pipeline.addAudioTap` delivers whatever
/// `monitorEnabled` says, and `setAudioMonitorEnabled` reaches only the
/// speakers. An operator who turns the monitor off to take a phone call does
/// not take the sound off a director's laptop with it, and nobody has to turn
/// the cart's speakers up to give them any.
extension CaptureController {
    /// The AAC session, built on demand and registered on the pipeline's tap.
    ///
    /// Its bitrate is a constant rather than a setting, and deliberately: it is
    /// 3 % of the video's default, so it is never the reason a link cannot
    /// carry the picture, and an operator cannot hear the far end to judge a
    /// number against it. The one dial the app has for a live feed stays the
    /// one the SRT row already shows.
    @discardableResult
    func ensureLiveAudioEncoder() -> LiveAudioEncoder {
        if let existing = mirrors.liveAudioEncoder { return existing }
        let encoder = LiveAudioEncoder(
            // Shared with every picture session, so the two elementary streams
            // of one transport stream are stamped against one origin. See
            // `LiveClock`.
            clock: mirrors.liveClock,
            onFailure: { reason in
                // AudioToolbox would not open a codec. Logged and not shown:
                // the picture is unaffected, the operator has nothing to change
                // — there is no audio switch to flick — and the transport
                // stream simply never declares a second stream, because the
                // program map follows the bytes (`SRTMirror.deliver`).
                os_log("live audio encoder unavailable: %{public}s", reason)
            })
        mirrors.liveAudioEncoder = encoder
        // Weak, like the grid composer's sink on its encoder: this closure is
        // held by the PIPELINE and runs on the capture queue, and it must not
        // be what keeps a converter the controller has already dropped alive.
        pipeline.addAudioTap(encoder) { [weak encoder] packet in
            encoder?.offer(packet)
        }
        return encoder
    }

    /// Drop the AAC session if nothing wants sound any more.
    ///
    /// Recomputed from the CONSUMERS rather than counted, for
    /// `releaseIdleLivePictures`' reason: a refcount would have to be
    /// decremented on every path that can be the last one out, and one missed
    /// decrement is a converter and a per-packet tap running for the rest of
    /// the day with nothing on the other end of them.
    ///
    /// **The one line to widen at the seam.** An NDI source or a WebRTC viewer
    /// taking sound is one more term in `wanted` and one more `addSink` where
    /// it is built; nothing else in this file changes, and nothing in
    /// `CapturePipeline+Audio` changes at all.
    func releaseIdleLiveAudio() {
        let wanted = mirrors.srt != nil
        guard !wanted, let encoder = mirrors.liveAudioEncoder else { return }
        pipeline.removeAudioTap(encoder)
        encoder.stop()
        mirrors.liveAudioEncoder = nil
    }
}
