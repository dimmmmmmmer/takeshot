import CaptureCore
import Foundation

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
/// the connection it produced, changing what it is watching, and giving the
/// slot back when it ends.
///
/// **What a browser watches is the browser's choice, and this is where it is
/// honoured.** The offer names a `LivePicture`; the answer carries the id the
/// page sends back to change it. Nothing here decides between the pictures —
/// what each of them IS is stated once at `LivePicture`, and what a choice
/// COSTS is the encoder pool's rule (`CaptureController+LivePictures`): one
/// session per distinct picture somebody is actually watching, so a DP on the
/// decorated frame and a script supervisor on the clean one cost two, and two
/// people on either cost the same as one.
///
/// **The other live outputs are not offered the choice, and the reasons
/// differ.** SRT has no way to ask — there is no page at the far end, only a
/// receiver — so it takes the picture named at `CaptureController.srtPicture`.
/// NDI is not a consumer of an encoder here at all: its SDK compresses frames
/// itself, so it hangs off the display buffer beside the hardware feeder and
/// could take the clean picture for the price of no second encode whatsoever.
/// It takes the decorated one anyway, on the merits stated at the top of
/// `CaptureController+NDI` — which is independent evidence for the same answer
/// rather than a cost anybody is avoiding.
///
/// **Picture only, and the seam is where the connection is, not where the codec
/// is.** The stereo feed exists now and is independent of the cart's speakers
/// (`CapturePipeline.addAudioTap`), and SRT came off it — but a browser cannot
/// be handed what SRT is handed: AAC is not a WebRTC codec, and the payload
/// types a browser offers are Opus and G.711.
///
/// **Opus is the half that turned out NOT to be missing, and that is written
/// down because it was assumed the other way first.** Measured on this machine
/// rather than looked up: AudioToolbox opens a converter to `kAudioFormatOpus`
/// and really encodes — 960 frames of 48 kHz stereo in, 469 then 418 then 390
/// bytes out over three consecutive frames — so an Opus leg would need no
/// third-party library at all, the way the AAC one needs none.
/// `kAudioFormatOpus` is declared in the macOS 15.4 SDK's headers as well as
/// macOS 26's; whether the ENCODER is present on the runtime at this app's
/// deployment floor has NOT been measured, and this machine is macOS 26 — the
/// same shape as the `mdcv`/`clli` caveat the HDR wave left.
///
/// What is missing is everything after the codec, and none of it can be RUN
/// here. `CDataChannel` is a stub with no libdatachannel on any search path in
/// this tree and `WebRTCPeering` is a fake in every test, so no peer connection
/// here has ever carried a byte. An audio track needs an `m=audio` section
/// negotiated against a real browser's offer — `WebRTCOffer` parses video and
/// says so at the line that skips the rest — and an RFC 7587 Opus packetizer
/// beside `RTPH264Packetizer`. An SDP negotiation and a wire format are both
/// things only the far end can prove, and writing them on the strength of
/// having read the RFCs is what this project does not do.
///
/// The seam is the same one NDI's is, and the tap is on the correct side of it:
/// an Opus encoder is a second consumer registered exactly as
/// `ensureLiveAudioEncoder` registers the AAC one, and a second term in
/// `releaseIdleLiveAudio`'s `wanted`. Nothing in `CapturePipeline+Audio`
/// changes.
extension CaptureController {
    // MARK: - signalling

    /// Answer one POSTed offer. Called on the MainActor; `reply` is called from
    /// wherever the answer finishes, which is deliberately not here.
    func answerWebRTCOffer(_ offer: String, picture: LivePicture,
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
        // What the app decides about the picture's FORMAT, out of the browser's
        // own offer — which is a different question from which picture it is.
        // nil is every refusal at once — not SDP, no video, video the browser
        // will not receive, H.264 that cannot be fragmented — and they share one
        // response because they share one fix: offer something else.
        guard let plan = WebRTCOffer.videoPlan(in: offer) else {
            reply(.rejected)
            return
        }
        open(plan, picture: picture, answering: offer, reply: reply)
    }

    private func open(_ plan: WebRTCOffer.VideoPlan, picture: LivePicture,
                      answering offer: String,
                      reply: @escaping @Sendable (RemoteWebRTC.Answer) -> Void) {
        let encoder = ensureLiveEncoder(for: picture)
        let ssrc = UInt32.random(in: 1...UInt32.max)
        let factory = mirrors.webrtcPeerFactory ?? { WebRTCPeer.make($0, ssrc: $1) }
        let id = UUID()
        let viewer = WebRTCViewer(
            peer: factory(plan, ssrc), plan: plan, ssrc: ssrc,
            picture: picture, encoder: encoder
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
                reply(.answered(sdp: try viewer.answer(offer: offer),
                                viewer: id.uuidString))
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

    // MARK: - the choice, changed

    /// **One viewer moves to a different picture, on the connection it already
    /// has.**
    ///
    /// The two halves of "the second picture is paid for only while somebody is
    /// watching it" happen here in this order, and the order is the point: the
    /// session for the new picture is built first so the viewer never has
    /// nothing to watch, and only then is whatever it left released if it was
    /// the last one on it. Doing it the other way round would tear the old
    /// session down and rebuild it for a page that changed its mind twice.
    ///
    /// `false` when there is no such viewer — a page whose connection ended
    /// while its tap was in flight. The page answers that by offering again
    /// with the picture it wanted, so the feature degrades to the re-offer this
    /// call exists to avoid rather than to nothing.
    @discardableResult
    func changeWebRTCPicture(viewer id: String, to picture: LivePicture) -> Bool {
        guard let uuid = UUID(uuidString: id),
              let viewer = mirrors.webrtcViewers[uuid] else { return false }
        guard viewer.picture != picture else { return true }
        viewer.watch(picture, on: ensureLiveEncoder(for: picture))
        releaseIdleLivePictures()
        return true
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

    /// One viewer, gone: stopped, forgotten, and any session it was the last
    /// thing on released with it.
    func dropWebRTCViewer(_ id: UUID) {
        guard let viewer = mirrors.webrtcViewers.removeValue(forKey: id) else {
            return
        }
        viewer.stop()
        releaseIdleLivePictures()
    }

    /// Every viewer, gone. The remote server going down takes them with it:
    /// there is no way to reach the app without it, so a connection left up
    /// would be a picture going to a page with no signalling behind it.
    func stopWebRTCViewers() {
        for viewer in mirrors.webrtcViewers.values { viewer.stop() }
        mirrors.webrtcViewers.removeAll()
        releaseIdleLivePictures()
    }
}
