import CaptureCore
import Foundation

/// The mirrors of the viewer, and what the operator is told about them.
///
/// The hardware playout output, the NDI source and the SRT stream are the same
/// kind of thing: all three show whatever the viewer shows, all three take the
/// DECORATED frame, and all three ride the one display-mirror handler slot per
/// source that `CaptureController.wireDisplayMirrors` installs. The browsers
/// ride it too and are the exception that proves it — each of them names the
/// picture it wants (`LivePicture`), which is why the slot now carries the
/// whole frame rather than one buffer. Holding them
/// together is what makes that function readable, and it is also what keeps
/// `CaptureController` off its type-body ceiling — the controller is a
/// stored-state inventory that is deliberately capped, and a subsystem that
/// needs a dozen properties takes one, the way `live`, `scopes` and `transport`
/// already do.
///
/// **Riding one slot is not the same as sharing one encoder, and the two facts
/// diverge here.** `srt` and `webrtcViewers` are consumers of `liveEncoders`;
/// `playout` and `ndi` are consumers of the display BUFFER, because a DeckLink
/// output takes pixels and NDI's SDK takes frames it compresses itself. So the
/// slot fans out to the pixel consumers directly plus ONE H.264 session per
/// distinct picture somebody is watching — two at most from this slot, since
/// the third picture is built elsewhere — and what that costs is written at
/// `wireDisplayMirrors`.
///
/// An ObservableObject for two fields: `srtState` and `ndiState` are what the
/// settings rows read, and each row observes this object directly
/// (`SRTStatusRow`, `NDIStatusRow`) rather than the whole controller — the same
/// reason `live` exists.
///
/// MainActor state throughout: every field here is written from the controller.
@MainActor
final class DisplayMirrors: ObservableObject {
    /// Hardware playout: mirrors the viewer to the DeckLink output chosen in
    /// settings. Rebuilt on device/format changes; routed by viewer mode.
    var playout: PlayoutFeeder?

    /// The NDI source; nil — off, which is the default. Built on the setting's
    /// edge and dropped on the other, so with the switch off the display path
    /// has no NDI consumer at all (see `CaptureController+NDI`).
    var ndi: NDIVideoMirror?

    /// What Settings shows about the NDI output. Published because it is the
    /// only honest answer to "is it sending?": the switch is a wish, and a build
    /// with no SDK or a machine with no runtime cannot honour it.
    @Published var ndiState: NDIOutputState = .off

    /// Overridden in tests so a suite never announces a real source on the set
    /// network; nil — the real sender. `ControllerHarness` fills it in for every
    /// controller it builds, so reaching the real one by omission is not
    /// possible from a test.
    var ndiSenderFactory: ((String) throws -> NDIVideoSending)?

    /// Debounces the re-announce a name change causes (see `applyNDIChange`).
    var ndiRenameTask: Task<Void, Never>?

    /// The SRT output; nil — off, which is the default. Built on the setting's
    /// edge and dropped on the other, so with the switch off the display path has
    /// no SRT consumer at all and no encoder exists (see `CaptureController+SRT`).
    var srt: SRTVideoMirror?

    /// What Settings shows about the SRT output. Published because it is the only
    /// honest answer to "is it sending?": the switch is a wish, and a build with
    /// no libsrt, a machine with none installed, or a receiver nobody has opened
    /// yet cannot honour it.
    @Published var srtState: SRTOutputState = .off

    /// The endpoint the live mirror was built for, so the status row can show the
    /// `srt://` URL to read out rather than making the operator reassemble it
    /// from four fields. nil whenever `srt` is.
    var srtEndpoint: SRTEndpoint?

    /// Overridden in tests so no suite ever puts UDP on the set network or binds
    /// a port on the machine running them; nil — the real stream.
    /// `ControllerHarness` fills it in for every controller it builds, so reaching
    /// the real one by omission is not possible from a test.
    var srtStreamFactory: (@Sendable (SRTEndpoint) throws -> SRTStreamSending)?

    /// Debounces the rebuild a settings edit causes (see `applySRTChange`).
    var srtRestartTask: Task<Void, Never>?

    /// **One H.264 session per DISTINCT picture somebody is watching**, and
    /// empty while nobody is — which is the default.
    ///
    /// The rule this pool exists to keep, stated once: a session is built when
    /// the first consumer of its picture appears (the SRT switch, or a browser
    /// that offered) and dropped when the last one goes, so a set with nothing
    /// watching encodes nothing at all and a second viewer of a picture that is
    /// already going costs no encode. See `CaptureController+LivePictures` for
    /// the arithmetic, and `LiveVideoEncoder` for why one session cannot carry
    /// two pictures.
    var liveEncoders: [LivePicture: LiveVideoEncoder] = [:]

    /// The 90 kHz origin every one of them stamps against — one per app, so a
    /// browser moved from one picture to another is not handed a timestamp from
    /// a different clock. See `LiveClock`.
    let liveClock = LiveClock()

    /// The grid picture, while somebody is watching it: every camera's clean
    /// frame tiled into one buffer for `liveEncoders[.grid]`. nil otherwise, so
    /// an unwatched grid costs no compose (see `MultiviewComposer`).
    var gridComposer: MultiviewComposer?

    /// Browsers watching over WebRTC, by the id their events carry.
    ///
    /// A dictionary rather than an array because a viewer's own callbacks are
    /// what remove it — a page closed, an ICE agent that gave up — and those
    /// arrive out of order with everything else. The id is also what the page
    /// sends back to change its picture, which is why it leaves the app at all
    /// (`RemoteWebRTC.viewerHeader`).
    var webrtcViewers: [UUID: WebRTCViewer] = [:]

    /// Overridden in tests, for a sharper reason than the SRT factory has: the
    /// real peer generates a DTLS certificate and puts UDP on the set network,
    /// and a suite that reached it would do both once per test.
    /// `ControllerHarness` fills it in for every controller it builds.
    var webrtcPeerFactory:
        (@Sendable (WebRTCOffer.VideoPlan, UInt32) -> WebRTCPeering)?
}
