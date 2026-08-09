import Foundation
import Testing

@testable import TakeShotKit

/// Handing a remote address to somebody who is not at the cart (owner item:
/// "the remote links are not clickable").
///
/// The handlers are substituted throughout, for the reason `RemoteHandout`
/// states: the real ones write the pasteboard of whoever is running the suite
/// and open a browser window on their screen.
@Suite @MainActor struct RemoteHandoutTests {
    /// Restore the app's own handlers whatever the test did — the suite is
    /// serial and main-actor, so a leaked substitution would follow every
    /// later test rather than fail this one.
    private func withCapture(
        _ body: (Recorder) throws -> Void) rethrows {
        let recorder = Recorder()
        let copy = RemoteHandout.copyHandler
        let open = RemoteHandout.openHandler
        defer {
            RemoteHandout.copyHandler = copy
            RemoteHandout.openHandler = open
        }
        RemoteHandout.copyHandler = { recorder.copied.append($0) }
        RemoteHandout.openHandler = { recorder.opened.append($0) }
        try body(recorder)
    }

    @MainActor
    private final class Recorder {
        var copied: [String] = []
        var opened: [URL] = []
    }

    /// The primary action: the address goes on the clipboard exactly as it is
    /// shown, so what is pasted into a message to the director is a link the
    /// phone can open.
    @Test func copyingAnAddressHandsOverTheWholeURL() {
        withCapture { recorder in
            for link in RemoteLink.allCases {
                let url = RemoteAddress.joined(host: "http://192.168.1.42:8765",
                                               path: link.path)
                RemoteHandout.copy(url)
                #expect(recorder.copied.last == url, "\(link.rawValue)")
            }
            #expect(recorder.copied.count == RemoteLink.allCases.count)
            #expect(recorder.opened.isEmpty, "copying opened a browser")
        }
    }

    /// The secondary action opens the page the phone would get, parsed rather
    /// than handed over as a string.
    @Test func openingAnAddressParsesItFirst() {
        withCapture { recorder in
            RemoteHandout.open("http://10.0.5.20:8765/cameras")
            #expect(recorder.opened.map(\.absoluteString)
                == ["http://10.0.5.20:8765/cameras"])
            #expect(recorder.copied.isEmpty, "opening wrote the clipboard")
        }
    }

    /// Only a web page can come out of this, whatever goes in.
    ///
    /// `URL(string:)` is not the gate it looks like — it percent-encodes its
    /// way past a sentence with spaces in it and hands back a URL — so the
    /// scheme and the host are checked instead. `RemoteAddress` cannot produce
    /// any of these; what is pinned is that a call which could reach the
    /// Finder, another app's handler or a local file never does.
    @Test func onlyAnHTTPAddressReachesTheBrowser() {
        withCapture { recorder in
            for address in ["", "not a url at all", "/Users/someone/secret.mov",
                            "file:///etc/passwd", "takeshot://open",
                            "javascript:alert(1)", "http:///cameras"] {
                RemoteHandout.open(address)
                #expect(recorder.opened.isEmpty, "\(address) reached the browser")
            }
            RemoteHandout.open("https://192.168.1.42:8765/script")
            #expect(recorder.opened.count == 1, "a real address was turned away")
        }
    }

    // MARK: - which line the code belongs to

    /// The choice is an index over the machine's interfaces, and it survives a
    /// page switch because the list is the same interfaces in the same order
    /// for all three pages. That is the reason it is an index and not the URL
    /// string — the string carries the old page's path.
    @Test func theSameIndexNamesTheSameHostOnEveryPage() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.startRemoteServer(overridePort: 0)
            await ControllerWait.until { controller.remoteBoundPort > 0 }
            let byPage: [[String]] = RemoteLink.allCases.map {
                controller.remoteURLs(for: $0)
            }
            let counts: Set<Int> = Set(byPage.map(\.count))
            #expect(counts.count == 1,
                    "the pages offer different numbers of addresses: \(counts)")
            guard let first: [String] = byPage.first else { return }
            for index in first.indices {
                // Host and port have to match, which is what makes "line 2"
                // mean the same network whichever page is selected.
                let hosts: Set<String> = Set(byPage.map { (urls: [String]) -> String in
                    let bare: Substring = urls[index].dropFirst("http://".count)
                    let host: Substring = bare.prefix { (c: Character) in c != "/" }
                    return String(host)
                })
                #expect(hosts.count == 1, "line \(index) moved between pages")
            }
        }
    }

    /// The fallback: a dock unplugged mid-shift shortens the list under a
    /// choice already made, and what is offered then is the first address —
    /// the one a phone on the set network would use.
    @Test func aChoiceThatOutlivedItsInterfaceFallsBackToTheFirst() {
        #expect(RemoteSettingsSection.picked(0, of: 3) == 0)
        #expect(RemoteSettingsSection.picked(2, of: 3) == 2)
        #expect(RemoteSettingsSection.picked(2, of: 1) == 0)
        #expect(RemoteSettingsSection.picked(-1, of: 3) == 0)
        #expect(RemoteSettingsSection.picked(0, of: 0) == 0)
    }
}
