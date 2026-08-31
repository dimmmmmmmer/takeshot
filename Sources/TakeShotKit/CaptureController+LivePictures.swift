import CaptureCore
import Foundation
import os.log

/// **The encoder pool: one H.264 session per distinct picture somebody is
/// actually watching, and nothing else.**
///
/// The rule, and it is the whole of this file:
///
/// - Nobody watching costs nothing. No session exists, no display slot is
///   installed, and `CapturePipeline.publishDisplayFrame` returns before it
///   even pairs the two pictures up.
/// - A second viewer of a picture that is already going costs no encode at all
///   — one more sink on a session that was going to compress that frame
///   anyway, and a packetize and a send on that viewer's own queue.
/// - A viewer who wants a DIFFERENT picture costs a whole encode, and it is
///   paid for only while they are there. Two pictures is two encodes and two
///   bitrates' worth of bits; that is what "the second one is paid for" means,
///   and it is why the pool is keyed on the picture rather than on the viewer.
///
/// **Which picture each consumer wants is asked, never assumed.** The SRT link
/// has no choice and its rule is stated once below; a browser states its choice
/// in its offer and may change it later without the connection being torn down.
/// Everything downstream turns a `LivePicture` into a buffer through
/// `LiveFrame`'s subscript and nowhere else.
extension CaptureController {
    /// **The picture the SRT link carries.**
    ///
    /// Stated here as a constant rather than spelled at the call site, because
    /// it is the same kind of fact as a browser's choice and belongs in the
    /// same file as the pool that acts on it. The value has not changed and the
    /// reason has not either: an SRT feed replaces a cable to a director's
    /// monitor, and whoever watches it is watching over the operator's
    /// shoulder. There is deliberately no setting — an operator cannot see what
    /// the far end is getting, so a switch that changed it could only ever be
    /// wrong somewhere they are not.
    static let srtPicture: LivePicture = .decorated

    // MARK: - the pool

    /// The session for one picture, built on demand.
    ///
    /// Its bitrate is the SRT setting's, which is the only dial the operator has
    /// for a live feed — one number, and every session inherits it. A dial per
    /// picture would be a second number for the same wire, and the operator has
    /// no way to see which picture a given phone chose.
    @discardableResult
    func ensureLiveEncoder(for picture: LivePicture) -> LiveVideoEncoder {
        if let existing = mirrors.liveEncoders[picture] { return existing }
        let encoder = LiveVideoEncoder(
            bitsPerSecond: settings.srt.bitsPerSecondEffective,
            // Shared, so a viewer changing picture is not handed a timestamp
            // from a clock that started later. See `LiveClock`.
            clock: mirrors.liveClock,
            onFailure: { [weak self] reason in
                os_log("live encoder unavailable: %{public}s", reason)
                Task { @MainActor in
                    self?.reportLiveEncoderFailure(reason, for: picture)
                }
            })
        mirrors.liveEncoders[picture] = encoder
        wireLivePictures()
        return encoder
    }

    /// VideoToolbox would not build a session at all — said somewhere the
    /// operator is looking.
    ///
    /// **The session is SHARED, and that is why this is not simply an SRT
    /// event.** It used to be: the SRT row is the one surface an operator
    /// already watches for this feed, and with the switch off the event was
    /// inert — "the log is the record". But a browser on `/live`, the NDI
    /// source and the hardware playout all ride the same encoder, and with SRT
    /// off none of them had anywhere to say this. The phone sat on a black page
    /// and the only explanation was in a log nobody opens on a set.
    ///
    /// So: SRT's row when SRT is on, in SRT's own words, and the app's error
    /// line otherwise. Never both — one failure said twice reads as two.
    ///
    /// **Which PICTURE failed decides that, not which switches are on.** The
    /// sessions are keyed per `LivePicture`, and this used to report ANY of
    /// them into the SRT row: a phone asking for the grid and failing to get an
    /// encoder painted a healthy SRT link `.failed`, toasted "SRT: …", lit the
    /// trouble triangle — and `SRTMirror` dedupes against its last reported
    /// event, so nothing cleared it until the link really dropped. The browser
    /// that actually lost its picture was told nothing at all.
    func reportLiveEncoderFailure(_ reason: String, for picture: LivePicture) {
        if picture == Self.srtPicture, mirrors.srt != nil {
            applySRTEvent(.refused(reason))
        } else {
            lastError = L("live_video_failed", reason)
        }
    }

    /// Drop every session nothing is watching any more.
    ///
    /// The whole promise of the design, and it is recomputed from the WATCHERS
    /// rather than counted: a refcount per picture would have to be incremented
    /// and decremented at six call sites — an offer, a picture change, a viewer
    /// that went, a deadline that fired, the SRT switch, the server going down
    /// — and one missed decrement is a 1080p encode nobody can see running for
    /// the rest of the day. Asking who is watching cannot drift.
    ///
    /// Called from every side that can be the last one out.
    func releaseIdleLivePictures() {
        var watched: Set<LivePicture> = []
        if mirrors.srt != nil { watched.insert(Self.srtPicture) }
        for viewer in mirrors.webrtcViewers.values {
            watched.insert(viewer.picture)
        }
        for (picture, encoder) in mirrors.liveEncoders
        where !watched.contains(picture) {
            encoder.stop()
            mirrors.liveEncoders.removeValue(forKey: picture)
        }
        wireLivePictures()
    }

    /// Install the taps every picture in the pool needs, and none it does not.
    ///
    /// The two halves are the two `LiveFrameSource`s, and calling both here is
    /// what stops a picture from being routed in one place and released in
    /// another: `.viewer` pictures come off the surface the operator is looking
    /// at, `.cameras` pictures off every live board at once.
    func wireLivePictures() {
        refreshGridComposer()
        wireDisplayMirrors()
        refreshMonitorTaps()
    }

    // MARK: - the grid picture

    /// Build or drop the composer that turns every camera's clean frame into
    /// the one buffer `liveEncoders[.grid]` compresses.
    ///
    /// Tied to the encoder's existence rather than to a count of its own: the
    /// pool already knows whether the grid is being watched, and a second
    /// answer to that question is a second thing to get wrong.
    private func refreshGridComposer() {
        guard let encoder = mirrors.liveEncoders[.grid] else {
            mirrors.gridComposer?.stop()
            mirrors.gridComposer = nil
            return
        }
        if mirrors.gridComposer == nil {
            // Weak, like the multiview encoder's sink on the server: this runs
            // on the composer's queue and must not keep a session the pool has
            // already dropped alive by holding it.
            mirrors.gridComposer = MultiviewComposer { [weak encoder] buffer, rate in
                encoder?.offer(buffer, framesPerSecond: rate)
            }
        }
        mirrors.gridComposer?.setCameraCount(extraChannels.count + 1)
    }
}
