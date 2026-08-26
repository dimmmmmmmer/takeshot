import Foundation

/// One of the four pages the remote serves, as a link the operator can hand
/// out: the path it lives at, and the label Settings puts on it.
///
/// A type rather than three loose constants because Settings offers them as
/// one switched row (three rows with three QR codes made the section taller
/// than the window). Anything that adds a page adds a case here and is then
/// unable to forget the switch, the route or the label.
enum RemoteLink: String, CaseIterable, Identifiable, Sendable {
    /// The operator remote: REC, marker, the two rating buttons.
    case remote
    /// The script supervisor's take log.
    case script
    /// The live camera grid.
    ///
    /// Called "cameras" and not "playback": the tiles are the boards' live
    /// signal, and a page named playback would be read as the recorded takes —
    /// which is the one thing it does not show. Not "multiview" either, on the
    /// page or in Settings; that is the name of the frame STREAM behind it
    /// (see `MultiviewEncoder`), and a phone is being offered a link, not a
    /// piece of the architecture.
    case cameras
    /// The viewer itself, as video.
    ///
    /// Not the same thing as `cameras`, and the difference is the point: that
    /// page is one JPEG per board at five a second, of the CLEAN signal,
    /// several tiles at once. This is ONE picture — the decorated viewer, the
    /// frame the SRT output carries — as an H.264 track over WebRTC, at the
    /// signal's own rate.
    ///
    /// The two stand side by side deliberately and not forever. The grid is
    /// what still works on a build with no libdatachannel in it, which is every
    /// build until the library is dropped in; removing it is a separate piece
    /// of work with a decision in it (see `CaptureController+WebRTC` for which
    /// picture the grid would then be showing).
    case live
    /// The digital slate, on a phone held up in front of a lens.
    ///
    /// The Mac already has one (`SlateView`), and it is on the cart. This is the
    /// same identification — timecode plus the creative card — on the device that
    /// can physically be put where the camera is looking. It is the only page
    /// here that sends the app NOTHING: see `slate.html`.
    case slate

    var id: String { rawValue }

    /// Where the server answers. The route, the settings link and the QR all
    /// read this, so they cannot drift into a 404 apart from each other.
    var path: String {
        switch self {
        case .remote: return "/"
        case .script: return "/script"
        case .cameras: return "/cameras"
        case .live: return "/live"
        case .slate: return "/slate"
        }
    }

    /// `Localizable.strings` key for the switch's segment.
    var labelKey: String {
        switch self {
        case .remote: return "remote_link_remote"
        case .script: return "remote_link_script"
        case .cameras: return "remote_link_cameras"
        case .live: return "remote_link_live"
        case .slate: return "remote_link_slate"
        }
    }
}

/// The pages the remote serves: the operator remote at `/`, the script
/// supervisor's take log at `/script`, the camera grid at `/cameras` and the
/// slate at `/slate`.
///
/// The markup is a bundle resource, not a Swift string literal: it is HTML,
/// CSS and JavaScript, and none of those are readable once they are escaped
/// into Swift. What the app injects is what the files cannot know — the labels
/// in the language the operator has chosen, and the web font, whose bytes live
/// in the app bundle next to them. The pages load nothing from anywhere, so
/// they work on a set network with no internet at all; that is exactly why the
/// font travels inside the page rather than as a URL.
enum RemotePage {
    /// The token in `remote.html` that the config object replaces.
    static let configToken = "__TAKESHOT_CONFIG__"

    /// The token in every page's stylesheet that the web font replaces.
    static let fontToken = "__TAKESHOT_FONT__"

    /// The app's own face, as the pages name it.
    static let fontFamily = "Resist Sans Display"

    /// The faces that are shipped, and the weight each answers for.
    ///
    /// TWO of the family's fourteen. These pages are opened on a phone over a
    /// set Wi-Fi network and the bytes travel inside the page, so every weight
    /// is paid for on every load: the pages use 400 for text and 600/700/800
    /// for buttons and labels, and a browser given 400 and 700 snaps 600 and
    /// 800 onto the bold rather than downloading two more faces to tell them
    /// apart at a glance nobody takes. The obliques are used nowhere at all.
    ///
    /// WOFF2 rather than the licensed .otf: same glyphs, 47 % of the bytes
    /// (117 KB → 55 KB per face), and base64 then inflates whatever is left by
    /// a third. Every browser that can open these pages reads it.
    static let fontFaces: [(resource: String, weight: Int)] = [
        ("ResistSansDisplay-Regular", 400),
        ("ResistSansDisplay-Bold", 700),
    ]

    /// The `@font-face` rules with the font in them, built once.
    ///
    /// Once because it is ~145 KB of base64 that never changes: the language
    /// switch re-renders all three pages, and re-encoding the same two files on
    /// every switch is work with no output. Empty when the resource is missing,
    /// which leaves the pages on the system stack behind it rather than on a
    /// broken `src`.
    static let fontCSS: String = buildFontCSS()

    private static func buildFontCSS() -> String {
        fontFaces.compactMap { face in
            guard let url = Bundle.module.url(forResource: face.resource,
                                              withExtension: "woff2"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return "@font-face{font-family:\"\(fontFamily)\";"
                + "font-style:normal;font-weight:\(face.weight);"
                + "font-display:swap;src:url(data:font/woff2;base64,"
                + "\(data.base64EncodedString())) format(\"woff2\")}"
        }.joined(separator: "\n")
    }

    /// How long the page waits for anything from the server before it calls the
    /// socket dead and reconnects.
    ///
    /// This is what the heartbeat is for. A mobile browser that loses the network
    /// is not told: the socket delivers nothing further, with no close event and
    /// no error, so a page that trusts its own connection state shows a timecode
    /// that stopped minutes ago as if it were live — and a REC press against it
    /// goes nowhere. Two of the server's five-second beats plus a margin; the
    /// test `thePageOutwaitsTwoHeartbeats` holds this to
    /// `CaptureController.remoteHeartbeatTicks` so the two cannot drift.
    static let watchdogMilliseconds = 12_000

    /// Page label → `Localizable.strings` key. The JavaScript reads the left
    /// column; the two `.strings` files carry the right one.
    static let labels: [(field: String, key: String)] = [
        ("title", "remote_title"),
        ("rec", "remote_rec"),
        ("stop", "remote_stop"),
        ("marker", "remote_marker"),
        ("good", "remote_good"),
        ("bad", "remote_bad"),
        ("connected", "remote_online"),
        ("connecting", "remote_connecting"),
        ("disconnected", "remote_offline"),
        ("connect", "remote_connect"),
        ("pinPrompt", "remote_pin_prompt"),
        ("pinBad", "remote_pin_bad"),
        ("markers", "remote_markers"),
        ("disk", "remote_disk"),
        ("noSignal", "remote_no_signal"),
        ("idle", "remote_idle"),
        ("lastTake", "remote_last_take"),
        ("posterWait", "remote_poster_wait"),
        ("modePlayback", "remote_mode_playback"),
    ]

    /// Where the pages fetch a take's frame. Stated once, here, so the route
    /// the server answers and the URL the page builds cannot drift apart — a
    /// mismatch shows up as a card that is permanently "no frame yet".
    static let posterPath = "/take-poster"

    /// Query parameter naming the take whose frame is wanted; absent or empty
    /// means the last take that landed, which is what the operator page's card
    /// is about.
    static let posterTakeParameter = "take"

    /// Where the script supervisor's page lives.
    static let scriptPath = RemoteLink.script.path

    /// The script page's label → key table. The gate and connection strings
    /// are shared with the operator page — the two describe the same socket.
    static let scriptLabels: [(field: String, key: String)] = [
        ("title", "script_title"),
        ("connected", "remote_online"),
        ("connecting", "remote_connecting"),
        ("disconnected", "remote_offline"),
        ("connect", "remote_connect"),
        ("pinPrompt", "remote_pin_prompt"),
        ("pinBad", "remote_pin_bad"),
        ("noSignal", "remote_no_signal"),
        ("idle", "remote_idle"),
        ("modePlayback", "remote_mode_playback"),
        ("good", "remote_good"),
        ("bad", "remote_bad"),
        ("recording", "script_recording"),
        ("empty", "script_empty"),
        ("comment", "script_comment"),
        ("takes", "script_takes"),
        ("scene", "scene"),
        ("shot", "slate_shot"),
        ("take", "slate_take"),
    ]

    /// Where the camera grid lives.
    static let camerasPath = RemoteLink.cameras.path

    /// The camera page's label → key table. The gate and connection strings
    /// are shared with the other pages — same socket, same PIN.
    static let camerasLabels: [(field: String, key: String)] = [
        ("title", "cameras_title"),
        ("connected", "remote_online"),
        ("connecting", "remote_connecting"),
        ("disconnected", "remote_offline"),
        ("connect", "remote_connect"),
        ("pinPrompt", "remote_pin_prompt"),
        ("pinBad", "remote_pin_bad"),
        ("noSignal", "remote_no_signal"),
        ("wait", "cameras_wait"),
        ("rec", "cameras_rec"),
    ]

    /// Where the live page lives.
    static let livePath = RemoteLink.live.path

    /// The live page's label table.
    ///
    /// The gate and connection strings are shared with the other pages — same
    /// socket, same PIN — and `wait` is the camera grid's own "no video yet",
    /// because it is the same sentence about the same signal. What is its own
    /// is the pair this page needs and no other does: a title for the state
    /// where the app cannot answer at all, and the button that tries again.
    static let liveLabels: [(field: String, key: String)] = [
        ("title", "live_title"),
        ("connected", "remote_online"),
        ("connecting", "remote_connecting"),
        ("disconnected", "remote_offline"),
        ("connect", "remote_connect"),
        ("pinPrompt", "remote_pin_prompt"),
        ("pinBad", "remote_pin_bad"),
        ("wait", "cameras_wait"),
        ("rec", "cameras_rec"),
        ("unavailable", "live_unavailable"),
        ("retry", "live_retry"),
    ]

    /// Where the slate lives.
    static let slatePath = RemoteLink.slate.path

    /// How long the slate keeps advancing its own clock after the last status
    /// before it freezes the readout and marks it held.
    ///
    /// **This is the whole of the slate's timekeeping honesty.** The status
    /// arrives four times a second (`CaptureController.remoteTick`), so a page
    /// that only showed what it was told would step six frames at a time at 25p,
    /// and an editor reading one frame of the slate off the footage would be up
    /// to a quarter of a second out. So the page interpolates — it counts frames
    /// forward from the last status against its own clock, and every status
    /// re-seeds it, which bounds the drift to what one tick can accumulate
    /// (a fiftieth of a frame at the 1000/1001 rates, which is why the page does
    /// not bother with 1000/1001 at all).
    ///
    /// Past this window it stops. Three ticks: long enough that ordinary Wi-Fi
    /// jitter does not flicker the readout, short enough that a number nobody is
    /// confirming any more is marked before it can be photographed and trusted.
    /// A slate that keeps counting off a stale seed is the worst failure this
    /// page has — it looks exactly like a live one. `theSlateOutwaitsOneTick`
    /// holds this against `CaptureController.remoteTick` so the two cannot drift.
    static let slateHoldMilliseconds = 750

    /// The slate's label → key table.
    ///
    /// The gate and connection strings are shared with the other three pages —
    /// same socket, same PIN. What is its own is the card, and the two words that
    /// say the clock has stopped: HOLD (no fresh status, socket still up) and
    /// OFFLINE (the socket is gone). Two words rather than one because they mean
    /// different things to whoever is holding the phone — one is "wait a beat",
    /// the other is "go and look at the Mac" — and because a single word covering
    /// both would have to be the vaguer of the two.
    static let slateLabels: [(field: String, key: String)] = [
        ("title", "slate_page_title"),
        ("connected", "remote_online"),
        ("connecting", "remote_connecting"),
        ("disconnected", "remote_offline"),
        ("connect", "remote_connect"),
        ("pinPrompt", "remote_pin_prompt"),
        ("pinBad", "remote_pin_bad"),
        ("noSignal", "remote_no_signal"),
        ("rec", "remote_rec"),
        ("next", "slate_next"),
        ("scene", "scene"),
        ("shot", "slate_shot"),
        ("take", "slate_take"),
        ("roll", "roll_label"),
        ("sync", "slate_sync_tag"),
        ("hold", "slate_page_hold"),
        ("offline", "slate_page_offline"),
        ("hint", "slate_page_hint"),
    ]

    /// The operator page with the current language's labels baked in.
    ///
    /// Called on the MainActor whenever the language changes; the server holds
    /// the bytes behind its own lock and serves them from its queue.
    static func html() -> Data {
        render(resource: "remote", labels: labels)
    }

    /// The script supervisor's page, same discipline.
    static func scriptHTML() -> Data {
        render(resource: "script", labels: scriptLabels)
    }

    /// The camera grid, same discipline again.
    static func camerasHTML() -> Data {
        render(resource: "cameras", labels: camerasLabels)
    }

    /// The live page, same discipline again.
    static func liveHTML() -> Data {
        render(resource: "live", labels: liveLabels)
    }

    /// The slate, same discipline again.
    static func slateHTML() -> Data {
        render(resource: "slate", labels: slateLabels)
    }

    private static func render(resource: String,
                               labels: [(field: String, key: String)]) -> Data {
        guard let url = Bundle.module.url(forResource: resource,
                                          withExtension: "html"),
              let template = try? String(contentsOf: url, encoding: .utf8)
        else {
            // A build without the resource must say so rather than serve a
            // blank page that looks like a network fault.
            return Data("<!doctype html><title>TakeShot</title>\(L("help_unavailable"))".utf8)
        }
        return Data(template
            .replacingOccurrences(of: configToken, with: config(labels: labels))
            .replacingOccurrences(of: fontToken, with: fontCSS).utf8)
    }

    /// `{"lang":"en","watchdogMs":12000,"holdMs":750,"posterPath":"…",…}` — a
    /// JSON object literal spliced straight into the script.
    ///
    /// One object for all four pages rather than one per page: every field in it
    /// is a number or a string a page may ignore, and a per-page config would be
    /// four places to forget the language in. `holdMs` is the slate's alone and
    /// costs the other three nine bytes each.
    static func config(labels: [(field: String, key: String)]) -> String {
        let strings = labels
            .map { "\($0.field):\(RemoteJSON.quoted(L($0.key)))" }
            .joined(separator: ",")
        return "{lang:\(RemoteJSON.quoted(L10n.current.pageCode)),"
            + "watchdogMs:\(watchdogMilliseconds),"
            + "holdMs:\(slateHoldMilliseconds),"
            + "posterPath:\(RemoteJSON.quoted(posterPath)),"
            + "offerPath:\(RemoteJSON.quoted(RemoteWebRTC.offerPath)),"
            + "strings:{\(strings)}}"
    }
}

extension AppLanguage {
    /// The BCP 47 tag for the page's `lang` attribute. `system` has no tag of
    /// its own — the page is being served by an app that resolved it already,
    /// and the strings in it are whatever that resolution produced.
    var pageCode: String {
        switch self {
        case .system: return Locale.preferredLanguages.first ?? "en"
        case .english, .russian: return rawValue
        }
    }
}
