import CaptureCore
import Foundation
import JavaScriptCore
import Testing

@testable import TakeShotKit

/// The slate on a phone: `/slate`.
///
/// The Mac already has a slate window; it is on the cart, and the camera is over
/// there. This page is the same identification on the one device that can be held
/// up in front of a lens, and it is held to three things the desktop one does not
/// have to answer for:
///
///   1. **It sends nothing.** The only action in the shipped markup is `hello`.
///   2. **Its clock is believable.** It counts frames between status pushes, and
///      the arithmetic that does it is checked against CaptureCore's own
///      `Timecode` rather than by eye — including across a drop-frame minute
///      boundary and the midnight wrap.
///   3. **It stops visibly.** Past `RemotePage.slateHoldMilliseconds` the
///      readout freezes on the last confirmed number and is marked; with the
///      socket gone it is struck through as well.
///
/// The page is a bundle resource with an injected config object, so all of that
/// is asserted against the SHIPPED page's own source — the pattern that pins USE
/// rather than a rule with no reader.
@Suite @MainActor struct RemoteSlateTests {
    private func utf8(_ data: Data) throws -> String {
        try #require(String(bytes: data, encoding: .utf8))
    }

    /// The page's arithmetic block, ready to evaluate. It is the first `<script>`
    /// and it touches no DOM and no socket, which is the whole reason it is a
    /// block of its own — see the comment above it in `slate.html`.
    private func clockSource(_ html: String) throws -> String {
        let open = try #require(html.range(of: "<script>"))
        let close = try #require(html.range(of: "</script>"))
        return String(html[open.upperBound..<close.lowerBound])
    }

    /// A JS context with that block evaluated in it.
    private func clock() throws -> JSContext {
        let html = try utf8(RemotePage.slateHTML())
        let context = try #require(JSContext())
        context.evaluateScript(try clockSource(html))
        #expect(context.exception == nil,
                "the clock block threw: \(context.exception?.toString() ?? "")")
        return context
    }

    // MARK: - the way in

    /// **Start from the defaults and require the door.** A page nobody can reach
    /// is a page whose every other test passes for nothing, so this begins at
    /// `CaptureSettings()` — no fixture, no pre-set flag — switches the remote on
    /// the way Settings switches it, and asks the route.
    ///
    /// Both halves are here because either alone is satisfiable without the
    /// other: the route can answer while Settings offers no link to it, and the
    /// link can exist over a 404.
    @Test func theSlateIsOfferedFromTheDefaultsAndAnswers() async throws {
        try await ControllerHarness.run { controller, _ in
            // Nothing about the remote has been pre-set: the group is exactly
            // what a fresh install carries, switch included.
            #expect(controller.settings.remote == RemoteSettings(),
                    "the harness pre-configured the remote — this proves nothing")
            #expect(controller.settings.remote.enabled != true,
                    "the remote is already on and the switch is untested")

            // the way in Settings offers: one segment per page (RemoteLink), and
            // the address row follows whichever is picked
            #expect(RemoteLink.allCases.contains(.slate),
                    "Settings offers no way to hand out the slate")
            let (port, _) = try await RemoteHarness.serve(controller)
            let slateURLs: [String] = controller.remoteURLs(for: .slate)
            #expect(slateURLs.count == controller.remoteURLs(for: .remote).count,
                    "the slate is offered on fewer addresses than the other pages")
            #expect(slateURLs.allSatisfy { $0.hasSuffix(RemotePage.slatePath) },
                    "an address does not point at the slate: \(slateURLs)")

            let url = try #require(URL(
                string: "http://127.0.0.1:\(port)\(RemotePage.slatePath)"))
            let (data, response) = try await RemoteHarness.session().data(from: url)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Type")
                == "text/html; charset=utf-8")
            let html = try #require(String(bytes: data, encoding: .utf8))
            #expect(html.contains("<!doctype html>"))
            #expect(html.contains(L("slate_page_hold")))
            #expect(!html.contains(RemotePage.configToken))
        }
    }

    // MARK: - it changes nothing

    /// The page is a display. The whole of what it may put on the socket is the
    /// PIN handshake, and this reads the shipped markup back to say so: every
    /// `action:` in it names `hello`.
    ///
    /// Asserted on the source rather than by watching a socket, deliberately.
    /// A test that connected and saw no command would pass against a page that
    /// sends one only when a director taps something.
    @Test func theSlateSendsNothingButTheHandshake() throws {
        let html = try utf8(RemotePage.slateHTML())
        let actions: [String] = Self.actions(in: html)
        #expect(actions == ["hello"],
                "the slate page sends more than the handshake: \(actions)")
        // …and the subscription the camera grid uses is not in it either, which
        // `actions` would catch but only if the spelling stayed the same.
        #expect(!html.contains("multiview"),
                "the slate asked for the camera-frame stream")
    }

    /// Every `action: "…"` value in a page's SCRIPTS, in order.
    ///
    /// The scripts and not the whole document: the stylesheet carries
    /// `touch-action: manipulation`, and a scan over the markup would read the
    /// next quoted string in the CSS as a command this page sends.
    private static func actions(in html: String) -> [String] {
        var found: [String] = []
        for block in Self.scripts(in: html) {
            var rest = Substring(block)
            while let mark = rest.range(of: "action: \"") {
                rest = rest[mark.upperBound...]
                guard let close = rest.firstIndex(of: "\"") else { break }
                found.append(String(rest[..<close]))
                rest = rest[close...]
            }
        }
        return found
    }

    // MARK: - the clock

    /// The page's timecode arithmetic is CaptureCore's, transcribed.
    ///
    /// Checked against `Timecode` frame by frame at every rate the app sees,
    /// through the two conversions the page actually performs: a label parsed to
    /// a frame ordinal, and an ordinal advanced and formatted back. The
    /// interesting rows are the drop-frame ones — a minute boundary at 29.97 is
    /// where a hand-written transcription goes wrong — plus one that walks over
    /// midnight, because the page counts forward and a slate at 23:59:59 is a
    /// night shoot rather than a hypothetical.
    @Test func thePagesClockAgreesWithTheAppsTimecode() throws {
        let context = try clock()
        let rates: [(fps: Int, drop: Bool)] = [
            (25, false), (24, false), (30, false), (30, true), (60, true),
        ]
        for rate in rates {
            for start in Self.probeFrames(fps: rate.fps, drop: rate.drop) {
                let expected = Timecode(frameNumber: start, fps: rate.fps,
                                        isDropFrame: rate.drop)
                let label: String = try Self.label(context, frame: start,
                                                   fps: rate.fps,
                                                   drop: rate.drop)
                #expect(label == expected.description,
                        "\(rate.fps) drop=\(rate.drop) frame \(start): \(label) against \(expected.description)")
                let parsed: Int = try Self.parse(context, label: label,
                                                 fps: rate.fps)
                #expect(parsed == expected.frameNumber,
                        "round trip of \(label) at \(rate.fps): page said \(parsed), app said \(expected.frameNumber)")
            }
        }
    }

    /// Frame ordinals worth probing at a rate: the start of the day, the first
    /// drop-frame minute boundary and the tenth (which does NOT drop), a run of
    /// consecutive frames across one, and the last second before midnight.
    private static func probeFrames(fps: Int, drop: Bool) -> [Int] {
        let minute = fps * 60 - (drop && fps % 30 == 0 ? fps / 15 : 0)
        var frames: [Int] = [0, 1, fps - 1, fps, fps * 61 + 3]
        for offset in -3...3 { frames.append(minute + offset) }
        for offset in -3...3 { frames.append(minute * 10 + offset) }
        let day = Timecode.dayFrames(fps: fps, isDropFrame: drop)
        frames.append(contentsOf: [day - fps, day - 1])
        return frames.filter { $0 >= 0 }
    }

    private static func label(_ context: JSContext, frame: Int, fps: Int,
                              drop: Bool) throws -> String {
        let call = "TAKESHOT_TC.label(\(frame), \(fps), \(drop))"
        let value = try #require(context.evaluateScript(call))
        #expect(context.exception == nil,
                "label threw: \(context.exception?.toString() ?? "")")
        return try #require(value.toString())
    }

    private static func parse(_ context: JSContext, label: String,
                              fps: Int) throws -> Int {
        let call = "TAKESHOT_TC.parse(\"\(label)\", \(fps)).frame"
        let value = try #require(context.evaluateScript(call))
        #expect(context.exception == nil,
                "parse threw: \(context.exception?.toString() ?? "")")
        return Int(value.toInt32())
    }

    /// Junk is refused rather than guessed at: a status whose timecode field
    /// arrived malformed must leave the slate with NO clock, which the page shows
    /// as dashes, and not with a number derived from half a string.
    @Test func thePagesClockRefusesJunk() throws {
        let context = try clock()
        for junk in ["", "10:00:00", "aa:bb:cc:dd", "10:00:00:00:00", "10-0-0-0"] {
            let call = "TAKESHOT_TC.parse(\"\(junk)\", 25) === null"
            let value = try #require(context.evaluateScript(call))
            #expect(value.toBool(), "the clock accepted \"\(junk)\"")
        }
        // A drop-frame label is recognised by its own separator, exactly as
        // `Timecode.init(text:fps:)` recognises one.
        let drop = try #require(
            context.evaluateScript("TAKESHOT_TC.parse(\"01:00:00;00\", 30).drop"))
        #expect(drop.toBool(), "the ';' separator was not read as drop-frame")
    }

    // MARK: - and it stops

    /// The two windows the readout's honesty rests on, and they have to sit in
    /// order: the hold window outlasts one status tick (or an ordinary Wi-Fi
    /// hiccup would flicker the number) and is far shorter than the watchdog
    /// (or a socket that died would keep counting until the watchdog noticed).
    ///
    /// Held against `CaptureController.remoteTick` rather than against a written
    /// number, so a change to the push rate cannot leave the page interpolating
    /// past what it is being told.
    @Test func theSlateOutwaitsOneTick() {
        let hold: Duration = .milliseconds(RemotePage.slateHoldMilliseconds)
        let tick: Duration = CaptureController.remoteTick
        #expect(hold > tick * 2,
                "the hold window is under two status ticks and will flicker")
        #expect(RemotePage.slateHoldMilliseconds < RemotePage.watchdogMilliseconds,
                "the readout holds longer than the socket does")
    }

    /// The page reads that window, freezes on the SEED rather than drifting on,
    /// and marks both stopped states apart. Four assertions on the shipped
    /// source, one per decision — the states are CSS classes and a timer, so
    /// nothing else here can see them.
    @Test func theSlateFreezesVisiblyRatherThanDrifting() throws {
        let html = try utf8(RemotePage.slateHTML())
        #expect(html.contains("holdMs:\(RemotePage.slateHoldMilliseconds)"),
                "the hold window never reaches the page")
        #expect(html.contains("elapsed > CFG.holdMs"),
                "the page does not stop advancing on the hold window")
        // HOLD is the socket alive with nothing fresh; OFFLINE is the socket
        // gone, and it carries a strike as well as a colour — a number that is
        // merely recoloured can be read as live on footage.
        #expect(html.contains("body.hold #tc") && html.contains("body.off #tc"),
                "one of the two stopped states has no appearance of its own")
        #expect(html.contains("text-decoration: line-through"),
                "an offline readout is not struck through")
    }

    // MARK: - the payload it lives on

    /// The card arrives on the status the other pages already ride, and it is the
    /// PENDING take's — the values the writer is about to embed, which is what
    /// keeps the phone in front of the lens from disagreeing with the Mac.
    @Test func theStatusCarriesTheSlateCard() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.naming.projectName = "SUNSET"
            controller.roll = "A007"
            controller.scene = "12A"
            controller.shot = "B"
            controller.slateTakeOverride = 3
            let (port, pin) = try await RemoteHarness.serve(controller)
            let client = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { client.close() }
            _ = try await client.next(type: "auth")

            var matched = false
            for _ in 0..<12 {
                let status = try await client.next(type: "status")
                guard status["scene"] as? String == "12A" else { continue }
                matched = status["shot"] as? String == "B"
                    && status["slateTake"] as? String == "3"
                    && status["roll"] as? String == "A007"
                    && status["project"] as? String == "SUNSET"
                break
            }
            #expect(matched, "the status never carried the slate card")
        }
    }

    /// The rate rides with the timecode, because the page cannot count frames
    /// without it — and it is the timecode's own numbering rate, so a 29.97
    /// drop-frame signal reports 30 rather than 29.
    @Test func theStatusCarriesTheTimecodesOwnRate() throws {
        var status = RemoteStatus()
        status.timecode = "10:00:00;00"
        status.timecodeFPS = Timecode(hours: 10, minutes: 0, seconds: 0,
                                      frames: 0, fps: 30,
                                      isDropFrame: true).fps
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(status.json.utf8)) as? [String: Any])
        #expect(object["tcFps"] as? Int == 30)
        #expect(object["tc"] as? String == "10:00:00;00")
        // No signal is no clock, and the page needs to be able to tell: an
        // absent rate is 0, never a guess at 25.
        #expect(RemoteStatus().timecodeFPS == 0)
    }

    // MARK: - the page itself

    @Test func theSlateCarriesTheAppsLabelsAndNoLeftoverToken() throws {
        for language in [AppLanguage.english, .russian] {
            let served = ViewRender.withLanguage(language) {
                RemotePage.slateHTML()
            }
            let html = try utf8(served)
            let label = ViewRender.withLanguage(language) { L("slate_next") }
            #expect(!html.contains(RemotePage.configToken),
                    "\(language.rawValue): the config token was not replaced")
            #expect(html.contains(label),
                    "\(language.rawValue): the page is missing its labels")
            #expect(html.contains("lang:\"\(language.rawValue)\""))
            // Self-contained: a slate on a set network fetches nothing.
            #expect(!html.contains("src=\"http"))
            #expect(!html.contains("<link "))
        }
    }

    /// Both of the page's scripts have to parse — the arithmetic block and the
    /// page. `new Function(source)` parses without running, which is what lets
    /// the second one be checked at all: it reaches for `document` on its first
    /// lines and there is none here.
    @Test func bothOfTheSlatesScriptsParse() throws {
        for language in [AppLanguage.english, .russian] {
            let html = try utf8(ViewRender.withLanguage(language) {
                RemotePage.slateHTML()
            })
            let blocks: [String] = Self.scripts(in: html)
            #expect(blocks.count == 2,
                    "\(language.rawValue): \(blocks.count) script blocks, not 2")
            for block in blocks {
                let context = try #require(JSContext())
                context.setObject(block, forKeyedSubscript: "SOURCE" as NSString)
                context.evaluateScript("new Function(SOURCE)")
                #expect(context.exception == nil,
                        "\(language.rawValue): \(context.exception?.toString() ?? "")")
            }
        }
    }

    private static func scripts(in html: String) -> [String] {
        let afterOpen: [String] = html.components(separatedBy: "<script>")
        return afterOpen.dropFirst().compactMap { part in
            guard let end = part.range(of: "</script>") else { return nil }
            return String(part[part.startIndex..<end.lowerBound])
        }
    }

    /// The served slate follows the app's language switch, with no restart. The
    /// pages are bytes behind the server's lock and each is replaced by its own
    /// setter, so a page left out of that branch is a Russian operator handing a
    /// director an English slate — which nothing but a fetch can see.
    @Test func theServedSlateFollowsTheLanguageSwitch() async throws {
        try await ControllerHarness.run { controller, _ in
            let (port, _) = try await RemoteHarness.serve(controller)
            let url = try #require(URL(
                string: "http://127.0.0.1:\(port)\(RemotePage.slatePath)"))
            controller.appLanguage = .russian

            let (data, _) = try await RemoteHarness.session().data(from: url)
            let html = try #require(String(bytes: data, encoding: .utf8))
            let russian = ViewRender.withLanguage(.russian) { L("slate_page_hold") }
            #expect(html.contains(russian),
                    "the slate was not re-rendered for the language switch")
            #expect(html.contains("lang:\"ru\""))
        }
        L10n.apply(.english) // leave the process on a known language
    }

    @Test func everySlateLabelIsTranslated() {
        for (field, key) in RemotePage.slateLabels {
            for language in [AppLanguage.english, AppLanguage.russian] {
                let value = ViewRender.withLanguage(language) { L(key) }
                #expect(value != key,
                        "\(field) renders as its raw key in \(language.rawValue)")
            }
        }
    }
}
