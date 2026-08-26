import CaptureCore
import Foundation
import os.log

/// Where the answer is built, and the one queue in this feature that is allowed
/// to park.
///
/// `WebRTCPeering.answer` blocks: it waits for ICE gathering so that one HTTP
/// exchange carries every candidate. Neither the MainActor nor the remote
/// server's queue may be the thread it blocks — the first is the app and the
/// second carries every phone on the set. Serial rather than concurrent because
/// gathering is milliseconds and two offers arriving together is a crew opening
/// a page, not a load.
private let webrtcSignallingQueue =
    DispatchQueue(label: "com.takeshot.webrtc.signalling")

/// The WebRTC viewers, from the controller's side: answering an offer, holding
/// the connection it produced, and giving the slot back when it ends.
///
/// **The frames come off the SAME display-mirror slot the hardware monitor, the
/// NDI source and the SRT stream ride** (see `wireDisplayMirrors`), so a browser
/// watching over WebRTC sees the DECORATED frame — the picture the operator is
/// looking at, aids and chroma key included — through the one shared encoder.
///
/// That is a decision with an open question behind it, and it is written here
/// rather than discovered later: the phone camera GRID deliberately shows the
/// CLEAN frame, because it is a crew monitoring surface where the operator's
/// own tools would lie to it. Those are two different pictures, and one encoder
/// cannot compress both. This seam takes the decorated one, which is the SRT
/// feed's rule and the right one for a surface that stands in for a cable to a
/// director's monitor. Whoever removes the JPEG grid has to settle it: either
/// the grid adopts this picture, or "one encoder" becomes "one encoder per
/// distinct picture" and the second one is paid for.
///
/// **The NDI output narrows that question rather than widening it, which is
/// worth knowing before anyone counts three feeds and assumes three votes.**
/// NDI is not a consumer of this encoder at all — its SDK takes frames and
/// compresses them itself, so it hangs off the display buffer beside the
/// hardware feeder. It could therefore take the clean picture for the price of
/// one more handler slot and no second encode, and it takes the decorated one
/// anyway, on the merits stated at the top of `CaptureController+NDI`. So the
/// "one encoder cannot compress two pictures" argument is still about exactly
/// two consumers, SRT and this one; NDI is independent evidence for the same
/// answer rather than another claim on the same session.
extension CaptureController {
    // MARK: - the shared encoder

    /// The session every live consumer shares, built on demand.
    ///
    /// Its bitrate is the SRT setting's, which is the only dial the operator
    /// has for a live feed — one number for one encoder, and a WebRTC viewer
    /// inherits it. A dial of its own would be a second number for the same
    /// bits.
    @discardableResult
    func ensureLiveEncoder() -> LiveVideoEncoder {
        if let existing = mirrors.liveEncoder { return existing }
        let encoder = LiveVideoEncoder(
            bitsPerSecond: settings.srt.bitsPerSecondEffective,
            onFailure: { [weak self] reason in
                // VideoToolbox would not build a session at all. The SRT row is
                // the one surface an operator already watches for this feed, so
                // that is where it goes; with the switch off the event is inert
                // and the log is the record.
                os_log("live encoder unavailable: %{public}s", reason)
                Task { @MainActor in self?.applySRTEvent(.refused(reason)) }
            })
        mirrors.liveEncoder = encoder
        wireDisplayMirrors()
        return encoder
    }

    /// Drop the shared session once nothing is watching.
    ///
    /// The whole promise of the design: an idle set encodes nothing. Called
    /// from both sides — the SRT switch going off and the last viewer leaving —
    /// because either can be the last one out.
    func releaseLiveEncoderIfIdle() {
        guard mirrors.srt == nil, mirrors.webrtcViewers.isEmpty else { return }
        mirrors.liveEncoder?.stop()
        mirrors.liveEncoder = nil
        wireDisplayMirrors()
    }

    // MARK: - signalling

    /// Answer one POSTed offer. Called on the MainActor; `reply` is called from
    /// wherever the answer finishes, which is deliberately not here.
    func answerWebRTCOffer(_ offer: String,
                           reply: @escaping @Sendable (RemoteWebRTC.Answer) -> Void) {
        // Structural first, exactly as the SRT switch does it. A build compiled
        // without the libdatachannel headers, or a machine with none installed,
        // cannot answer at all — and the page has to be told that rather than
        // left retrying a route that will never work. Checked only for the real
        // peer: an injected one is the test seam and is always available.
        if mirrors.webrtcPeerFactory == nil,
           let reason = WebRTCPeer.unavailableReason {
            reply(.unavailable(reason))
            return
        }
        guard mirrors.webrtcViewers.count < WebRTCViewer.maximumViewers else {
            reply(.unavailable("This Mac is already carrying "
                    + "\(WebRTCViewer.maximumViewers) viewers."))
            return
        }
        // What the app decides about the picture, out of the browser's own
        // offer. nil is every refusal at once — not SDP, no video, video the
        // browser will not receive, H.264 that cannot be fragmented — and they
        // share one response because they share one fix: offer something else.
        guard let plan = WebRTCOffer.videoPlan(in: offer) else {
            reply(.rejected)
            return
        }
        open(plan, answering: offer, reply: reply)
    }

    private func open(_ plan: WebRTCOffer.VideoPlan, answering offer: String,
                      reply: @escaping @Sendable (RemoteWebRTC.Answer) -> Void) {
        let encoder = ensureLiveEncoder()
        let ssrc = UInt32.random(in: 1...UInt32.max)
        let factory = mirrors.webrtcPeerFactory ?? { WebRTCPeer.make($0, ssrc: $1) }
        let id = UUID()
        let viewer = WebRTCViewer(
            peer: factory(plan, ssrc), plan: plan, ssrc: ssrc, encoder: encoder
        ) { [weak self] event in
            // libdatachannel's thread, by way of the viewer's queue. The
            // registry is MainActor state like the rest of the controller.
            Task { @MainActor in self?.applyWebRTCEvent(event, from: id) }
        }
        mirrors.webrtcViewers[id] = viewer
        // The blocking half, off the actor. Everything crossing is a value or a
        // Sendable object, and the registry is only ever touched back here.
        webrtcSignallingQueue.async { [weak self] in
            do {
                reply(.answered(try viewer.answer(offer: offer)))
            } catch {
                let failure = error as? WebRTCError
                    ?? .runtime(error.localizedDescription)
                // The slot goes back at once: a connection that never had an
                // answer has nothing to wait for and no state to reach.
                Task { @MainActor in self?.dropWebRTCViewer(id) }
                reply(Self.refusal(failure))
            }
        }
    }

    /// A failed answer as what the route says back. `.offer` is the browser's
    /// fault and everything else is this machine's.
    nonisolated static func refusal(
        _ failure: WebRTCError) -> RemoteWebRTC.Answer {
        if case .offer = failure { return .rejected }
        return .unavailable(failure.message)
    }

    // MARK: - lifetime

    func applyWebRTCEvent(_ event: WebRTCViewer.Event, from id: UUID) {
        switch event {
        case .connected:
            break
        case .gone:
            dropWebRTCViewer(id)
        }
    }

    /// One viewer, gone: stopped, forgotten, and the shared encoder released if
    /// it was the last thing watching.
    func dropWebRTCViewer(_ id: UUID) {
        guard let viewer = mirrors.webrtcViewers.removeValue(forKey: id) else {
            return
        }
        viewer.stop()
        releaseLiveEncoderIfIdle()
    }

    /// Every viewer, gone. The remote server going down takes them with it:
    /// there is no way to reach the app without it, so a connection left up
    /// would be a picture going to a page with no signalling behind it.
    func stopWebRTCViewers() {
        for viewer in mirrors.webrtcViewers.values { viewer.stop() }
        mirrors.webrtcViewers.removeAll()
        releaseLiveEncoderIfIdle()
    }
}
