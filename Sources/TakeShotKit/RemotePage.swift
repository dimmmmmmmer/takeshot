import Foundation

/// The single page the remote serves.
///
/// The markup is a bundle resource, not a Swift string literal: it is HTML,
/// CSS and JavaScript, and none of those are readable once they are escaped
/// into Swift. What the app injects is the one thing the file cannot know —
/// the labels in the language the operator has chosen. The page loads nothing
/// from anywhere, so it works on a set network with no internet at all.
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
    ]

    /// The page with the current language's labels baked in.
    ///
    /// Called on the MainActor whenever the language changes; the server holds
    /// the bytes behind its own lock and serves them from its queue.
    static func html() -> Data {
        guard let url = Bundle.module.url(forResource: "remote",
                                          withExtension: "html"),
              let template = try? String(contentsOf: url, encoding: .utf8)
        else {
            // A build without the resource must say so rather than serve a
            // blank page that looks like a network fault.
            return Data("<!doctype html><title>TakeShot</title>\(L("help_unavailable"))".utf8)
        }
        return Data(template.replacingOccurrences(of: configToken,
                                                  with: config()).utf8)
    }

    /// `{"lang":"en","watchdogMs":12000,"strings":{…}}` — a JSON object literal
    /// spliced straight into the script.
    static func config() -> String {
        let strings = labels
            .map { "\($0.field):\(RemoteJSON.quoted(L($0.key)))" }
            .joined(separator: ",")
        return "{lang:\(RemoteJSON.quoted(L10n.current.pageCode)),"
            + "watchdogMs:\(watchdogMilliseconds),"
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
