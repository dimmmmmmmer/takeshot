import Foundation

/// The pages the remote serves: the operator remote at `/`, the script
/// supervisor's take log at `/script` and the camera grid at `/multiview`.
///
/// The markup is a bundle resource, not a Swift string literal: it is HTML,
/// CSS and JavaScript, and none of those are readable once they are escaped
/// into Swift. What the app injects is the one thing the files cannot know —
/// the labels in the language the operator has chosen. The pages load nothing
/// from anywhere, so they work on a set network with no internet at all.
enum RemotePage {
    /// The token in `remote.html` that the config object replaces.
    static let configToken = "__TAKESHOT_CONFIG__"

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
        ("connected", "remote_connected"),
        ("connecting", "remote_connecting"),
        ("disconnected", "remote_disconnected"),
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

    /// Where the page fetches the last take's frame. Stated once, here, so the
    /// route the server answers and the URL the page builds cannot drift apart
    /// — a mismatch shows up as a card that is permanently "no frame yet".
    static let posterPath = "/take-poster"

    /// Where the script supervisor's page lives. Stated once for the same
    /// reason: the route, the settings link and the QR all read this.
    static let scriptPath = "/script"

    /// The script page's label → key table. The gate and connection strings
    /// are shared with the operator page — the two describe the same socket.
    static let scriptLabels: [(field: String, key: String)] = [
        ("title", "script_title"),
        ("connected", "remote_connected"),
        ("connecting", "remote_connecting"),
        ("disconnected", "remote_disconnected"),
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

    /// Where the camera grid lives. Stated once, like the script page's path.
    static let multiviewPath = "/multiview"

    /// The multiview page's label → key table. The gate and connection
    /// strings are shared with the other pages — same socket, same PIN.
    static let multiviewLabels: [(field: String, key: String)] = [
        ("title", "multiview_title"),
        ("connected", "remote_connected"),
        ("connecting", "remote_connecting"),
        ("disconnected", "remote_disconnected"),
        ("connect", "remote_connect"),
        ("pinPrompt", "remote_pin_prompt"),
        ("pinBad", "remote_pin_bad"),
        ("noSignal", "remote_no_signal"),
        ("wait", "multiview_wait"),
        ("rec", "multiview_rec"),
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
    static func multiviewHTML() -> Data {
        render(resource: "multiview", labels: multiviewLabels)
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
        return Data(template.replacingOccurrences(
            of: configToken, with: config(labels: labels)).utf8)
    }

    /// `{"lang":"en","watchdogMs":12000,"posterPath":"…","strings":{…}}` — a
    /// JSON object literal spliced straight into the script.
    static func config(labels: [(field: String, key: String)]) -> String {
        let strings = labels
            .map { "\($0.field):\(RemoteJSON.quoted(L($0.key)))" }
            .joined(separator: ",")
        return "{lang:\(RemoteJSON.quoted(L10n.current.pageCode)),"
            + "watchdogMs:\(watchdogMilliseconds),"
            + "posterPath:\(RemoteJSON.quoted(posterPath)),"
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
