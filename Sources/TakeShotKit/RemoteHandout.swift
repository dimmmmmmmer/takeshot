import AppKit
import Foundation

/// Handing a remote address to somebody who is not standing at the cart.
///
/// Three ways off the Mac, and only one of them is on the Mac. The QR code in
/// Settings is for a phone that is in the room; this is for the other two —
/// the clipboard, so the address can be pasted into whatever the unit talks on,
/// and the browser, so the operator can see the page the phone will get without
/// asking anyone to try it.
///
/// **Why a seam and not just two calls**, exactly as `FinderOpen` states it:
/// `NSPasteboard.general` is the pasteboard of whoever is running the suite,
/// and a test that clobbered it would be reaching outside its own scratch
/// directory in the most user-visible way there is. `NSWorkspace.open` would
/// put a real browser window on that machine. So the tests replace the two
/// handlers and read back what was handed over. Main-actor state, and the suite
/// is serial, so a substitution cannot leak sideways.
@MainActor
enum RemoteHandout {
    /// What actually reaches the pasteboard. Replaced by the suite; never by
    /// the app.
    static var copyHandler: (String) -> Void = { text in
        // Cleared first: `setString` alone leaves any other representation of
        // the previous item in place, and the paste that follows can pick one
        // of those instead.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// What actually opens the page. Replaced by the suite; never by the app.
    static var openHandler: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Put one address on the pasteboard.
    static func copy(_ address: String) {
        copyHandler(address)
    }

    /// Open one address in the default browser.
    ///
    /// Gated on being an http(s) URL with a host, and that is narrower than it
    /// looks: `URL(string:)` accepts almost anything, percent-encoding its way
    /// past spaces, and answers nil for so little that "it parsed" is not a
    /// test of anything. What the gate actually says is that this call can only
    /// ever reach a web page — never a `file:` path and never some other app's
    /// custom scheme. Every address here is built by `RemoteAddress.urls` and
    /// is already `http://`, so nothing legitimate is turned away; anything
    /// that fails it is a bug in this app rather than a condition an operator
    /// can act on from the set, so it is silently nothing.
    static func open(_ address: String) {
        guard let url = URL(string: address), url.host?.isEmpty == false,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        openHandler(url)
    }
}
