import CaptureCore
import Foundation
import JavaScriptCore
import Testing

@testable import TakeShotKit

/// The script supervisor's page, driven the way a phone drives it: the page
/// over HTTP, the take log over the socket, and edits that land on the same
/// controller methods the takes panel calls — which is the whole point, and
/// why every assertion below goes through controller state or the CSV the
/// panel's own buttons produce.
@Suite @MainActor struct RemoteScriptServerTests {
    /// One seeded take, as the scripty meets it: a name plus whatever marks it
    /// already carries.
    private struct Seed {
        var name: String
        var rating: TakeRating = .none
        var comment: String = ""
    }

    /// Takes seeded whole — the script page is about the LIST, so one is never
    /// enough. Files behind them, or the folder scan retires them mid-test.
    private func seedTakes(_ controller: CaptureController, in root: URL,
                           _ specs: [Seed]) throws {
        controller.takes = try specs.enumerated().map { offset, spec in
            var take = ControllerFixtures.take(
                named: spec.name, in: root, clip: offset + 1,
                recordedAt: Date(timeIntervalSince1970:
                                    1_700_000_000 + Double(offset)))
            take.rating = spec.rating
            take.comment = spec.comment
            try ControllerFixtures.placeholder(for: take)
            return take
        }
    }

    /// Read take-log pushes until one matches. The inner read's budget covers
    /// the statuses interleaved with them; a budget that runs dry hands back
    /// an empty message, which reads as "no more take logs are coming" and
    /// ends the poll — the outcome is polled, never a wall clock.
    private func nextTakes(from client: RemoteTestClient, reads: Int = 8,
                           matching predicate: ([[String: Any]]) -> Bool)
        async throws -> Bool {
        for _ in 0..<reads {
            let message = try await client.next(type: "takes", within: 40)
            guard let takes = message["takes"] as? [[String: Any]] else {
                return false
            }
            if predicate(takes) { return true }
        }
        return false
    }

    /// Same, for statuses — the running-take assertions read the stream.
    private func nextStatus(from client: RemoteTestClient, reads: Int = 12,
                            matching predicate: ([String: Any]) -> Bool)
        async throws -> Bool {
        for _ in 0..<reads {
            let status = try await client.next(type: "status")
            if predicate(status) { return true }
        }
        return false
    }

    /// The CSV is written on a background queue, so every read waits for the
    /// content it is about to assert on rather than for the file to exist.
    private func log(_ root: URL, containing needle: String) async -> String {
        let url = root.appendingPathComponent(TakeLogExporter.fileName)
        func text() -> String? { try? String(contentsOf: url, encoding: .utf8) }
        await ControllerWait.until { text()?.contains(needle) == true }
        return text() ?? ""
    }

    // MARK: - the page

    @Test func theScriptPageIsServedAtItsRoute() async throws {
        try await ControllerHarness.run { controller, _ in
            let (port, _) = try await RemoteHarness.serve(controller)
            let url = try #require(URL(
                string: "http://127.0.0.1:\(port)\(RemotePage.scriptPath)"))
            let (data, response) = try await RemoteHarness.session().data(from: url)
            let http = try #require(response as? HTTPURLResponse)

            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Type")
                == "text/html; charset=utf-8")
            let html = try #require(String(bytes: data, encoding: .utf8))
            #expect(html.contains("<!doctype html>"))
            #expect(html.contains(L("script_recording")))
            #expect(!html.contains(RemotePage.configToken))
        }
    }

    // MARK: - the take log over the socket

    /// The payload behind the PIN: every take, oldest first, each with the
    /// fields a scripty logs. A client that authenticates mid-shift is handed
    /// the day so far without waiting for the next take to land.
    @Test func theTakeLogCarriesEveryTakeWithItsFields() async throws {
        try await ControllerHarness.run { controller, root in
            try seedTakes(controller, in: root,
                          [Seed(name: "A001C01", rating: .good, comment: "keeper"),
                           Seed(name: "A001C02")])
            let (port, pin) = try await RemoteHarness.serve(controller)
            let client = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { client.close() }
            _ = try await client.next(type: "auth")

            let matched = try await nextTakes(from: client) { takes in
                guard takes.count == 2 else { return false }
                return takes[0]["name"] as? String == "A001C01"
                    && takes[0]["tc"] as? String == "10:00:00:00"
                    && takes[0]["rating"] as? String == "good"
                    && takes[0]["comment"] as? String == "keeper"
                    && (takes[0]["dur"] as? Double).map { abs($0 - 4) < 0.05 } == true
                    && takes[1]["name"] as? String == "A001C02"
                    && takes[1]["rating"] as? String == "none"
                    && !((takes[0]["id"] as? String ?? "").isEmpty)
            }
            #expect(matched, "the take log never carried the seeded takes")
        }
    }

    /// The status stream and the log ride the same gate: a wrong code gets
    /// neither, and an edit sent with it never reaches a take.
    @Test func theWrongPINCannotEditATake() async throws {
        try await ControllerHarness.run { controller, root in
            try seedTakes(controller, in: root, [Seed(name: "A001C01")])
            let (port, pin) = try await RemoteHarness.serve(controller)
            let wrong = RemoteHarness.wrongPIN(besides: pin)
            let id = try #require(controller.takes.first?.id.uuidString)

            let client = try await RemoteHarness.connect(
                port: port, pin: wrong, session: RemoteHarness.session())
            defer { client.close() }
            let auth = try await client.next(type: "auth")
            #expect(auth["ok"] as? Bool == false)

            try await client.send(["action": "rate", "id": id,
                                   "rating": "good", "pin": wrong])
            let refused = try await client.next(type: "auth")
            #expect(refused["ok"] as? Bool == false)
            #expect(try #require(controller.takes.first).rating == .none,
                    "an edit with the wrong PIN reached the controller")
        }
    }

    // MARK: - edits land on the controller's own methods

    /// A rating from the page goes through `setRating`, the method the row's
    /// context menu calls — asserted through the CSV rewrite that method owns,
    /// because the sidecar is what survives the day.
    @Test func aRateCommandFlipsTheRatingThroughTheController() async throws {
        try await ControllerHarness.run { controller, root in
            try seedTakes(controller, in: root,
                          [Seed(name: "A001C01"), Seed(name: "A001C02")])
            let (port, pin) = try await RemoteHarness.serve(controller)
            let client = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { client.close() }
            _ = try await client.next(type: "auth")
            let id = try #require(controller.takes.first?.id.uuidString)

            try await client.send(["action": "rate", "id": id,
                                   "rating": "good", "pin": pin])
            let rated = await ControllerWait.until {
                controller.takes.first?.rating == .good
            }
            #expect(rated, "the rating never reached the controller")
            // The FIRST take, not the last: the scripty edits any row, where
            // the operator page's good/bad only ever mark the newest.
            #expect(controller.takes.last?.rating == TakeRating.none)

            // The same side effect the panel's own buttons produce.
            let csv = await log(root, containing: "A001C01.mov,001,1,true,")
            #expect(csv.contains("A001C01.mov,001,1,true,"),
                    "the rating never reached the CSV sidecar")

            // The third state travels by name: an explicit "none" clears it.
            try await client.send(["action": "rate", "id": id,
                                   "rating": "none", "pin": pin])
            let cleared = await ControllerWait.until {
                controller.takes.first?.rating == TakeRating.none
            }
            #expect(cleared, "clearing a rating never reached the controller")
        }
    }

    /// A comment from the page goes through `setComment` — the same CSV
    /// Comments column the popover writes — and comes straight back as pushed
    /// state, which is how the page knows its save landed.
    @Test func aCommentCommandPersistsAndEchoesBack() async throws {
        try await ControllerHarness.run { controller, root in
            try seedTakes(controller, in: root,
                          [Seed(name: "A001C01"), Seed(name: "A001C02")])
            let (port, pin) = try await RemoteHarness.serve(controller)
            let client = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { client.close() }
            _ = try await client.next(type: "auth")
            let id = try #require(controller.takes.first?.id.uuidString)

            try await client.send(["action": "comment", "id": id,
                                   "text": "boom in frame", "pin": pin])
            let stored = await ControllerWait.until {
                controller.takes.first?.comment == "boom in frame"
            }
            #expect(stored, "the comment never reached the controller")
            #expect(controller.takes.last?.comment == "",
                    "the comment landed on the wrong take")

            let csv = await log(root, containing: "boom in frame")
            #expect(csv.contains("A001C01.mov,001,1,,boom in frame"),
                    "the comment never reached the CSV sidecar")

            // The page refreshes its fields from pushed state; the echo is
            // that state, without waiting for the next heartbeat.
            let echoed = try await nextTakes(from: client) { takes in
                takes.first?["comment"] as? String == "boom in frame"
            }
            #expect(echoed, "the edit never came back as pushed state")
        }
    }

    // MARK: - the shift, end to end

    /// A take rolled from the operator page reaches the scripty as it happens:
    /// the status names the take being written while it rolls, and the
    /// finalized take arrives as a pushed log — no refresh anywhere.
    @Test func aRunningTakeIsNamedAndItsLandingIsPushed() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }
            let (port, pin) = try await RemoteHarness.serve(controller)
            let client = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { client.close() }
            _ = try await client.next(type: "auth")

            try await client.send(action: "rec", pin: pin)
            let rolling = await ControllerWait.until { controller.isRecording }
            try #require(rolling, "REC from the remote did not start a take")

            // The header's contract: record mode, recording, and the name of
            // the take being written — what the scripty sees being shot.
            let named = try await nextStatus(from: client) {
                $0["recording"] as? Bool == true
                    && $0["mode"] as? String == "record"
                    && !(($0["take"] as? String ?? "").isEmpty)
            }
            #expect(named, "the running take never reached the status")

            try await client.send(action: "rec", pin: pin)
            await ControllerWait.until { !controller.isRecording }
            await ControllerWait.untilWritten { controller.takes.count == 1 }
            let landed = try await nextTakes(from: client, reads: 12) { takes in
                takes.count == 1 && takes[0]["name"] as? String
                    == controller.takes.first?.displayName
            }
            #expect(landed, "the finalized take was never pushed to the page")
        }
    }
}

/// The script page's wire formats and markup contracts, no socket needed —
/// the same style as `RemoteProtocolTests`, for the same reason: all of this
/// fails silently on a phone.
@Suite @MainActor struct RemoteScriptProtocolTests {
    private func utf8(_ data: Data) throws -> String {
        try #require(String(bytes: data, encoding: .utf8))
    }

    // MARK: - the JSON both ways

    @Test func rateAndCommentMessagesCarryTheirArguments() throws {
        let rate = try #require(RemoteMessage.parse(
            #"{"action":"rate","id":"AB-1","rating":"good","pin":"0417"}"#))
        #expect(rate.command == .rate(takeID: "AB-1", rating: .good))
        #expect(rate.pin == "0417")

        let comment = try #require(RemoteMessage.parse(
            #"{"action":"comment","id":"AB-1","text":"boom in frame","pin":"0417"}"#))
        #expect(comment.command == .comment(takeID: "AB-1", text: "boom in frame"))
        // Clearing a comment is an empty string, carried explicitly.
        #expect(RemoteMessage.parse(
            #"{"action":"comment","id":"AB-1","text":"","pin":"1"}"#)?.command
            == .comment(takeID: "AB-1", text: ""))
    }

    @Test func malformedEditsAreNotCommands() {
        // An unknown rating word must not be read as "clear the rating".
        #expect(RemoteMessage.parse(
            #"{"action":"rate","id":"A","rating":"great","pin":"1"}"#) == nil)
        #expect(RemoteMessage.parse(
            #"{"action":"rate","id":"A","pin":"1"}"#) == nil)
        #expect(RemoteMessage.parse(
            #"{"action":"rate","rating":"good","pin":"1"}"#) == nil)
        #expect(RemoteMessage.parse(
            #"{"action":"rate","id":"","rating":"good","pin":"1"}"#) == nil)
        // A comment without its text is malformed, not "clear it".
        #expect(RemoteMessage.parse(
            #"{"action":"comment","id":"A","pin":"1"}"#) == nil)
        #expect(RemoteMessage.parse(
            #"{"action":"comment","text":"x","pin":"1"}"#) == nil)
    }

    /// Names and comments are typed text; a quote in either used to be enough
    /// to break a page's parser for the rest of the shift.
    @Test func theTakeLogJSONSurvivesTypedText() throws {
        var log = RemoteTakeLog()
        log.entries = [RemoteTakeLog.Entry(
            id: "ID-1", name: #"A"001\C01"#, timecode: "10:00:00:00",
            durationSeconds: 12.44, rating: "bad",
            comment: "boom \"in\" frame\nand a second line")]

        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(log.json.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "takes")
        let takes = try #require(object["takes"] as? [[String: Any]])
        #expect(takes.count == 1)
        #expect(takes[0]["name"] as? String == #"A"001\C01"#)
        #expect(takes[0]["comment"] as? String
            == "boom \"in\" frame\nand a second line")
        #expect(takes[0]["tc"] as? String == "10:00:00:00")
        #expect((takes[0]["dur"] as? Double).map { abs($0 - 12.4) < 0.05 } == true)
    }

    // MARK: - the page

    @Test func theScriptPageCarriesTheAppsLabelsAndNoLeftoverToken() throws {
        for language in [AppLanguage.english, .russian] {
            let served = ViewRender.withLanguage(language) {
                RemotePage.scriptHTML()
            }
            let html = try utf8(served)
            let label = ViewRender.withLanguage(language) { L("script_recording") }
            #expect(!html.contains(RemotePage.configToken),
                    "\(language.rawValue): the config token was not replaced")
            #expect(html.contains(label),
                    "\(language.rawValue): the page is missing its labels")
            #expect(html.contains("lang:\"\(language.rawValue)\""))
            // Self-contained: nothing is fetched from anywhere.
            #expect(!html.contains("src=\"http"))
            #expect(!html.contains("<link "))
        }
    }

    /// The script has to parse, in both languages — it is a bundle resource
    /// with an injected config object, and a stray comma in either half
    /// compiles, ships, and shows the scripty a blank screen.
    @Test func theScriptPagesScriptParses() throws {
        for language in [AppLanguage.english, .russian] {
            let html = try utf8(ViewRender.withLanguage(language) {
                RemotePage.scriptHTML()
            })
            let open = try #require(html.range(of: "<script>"))
            let close = try #require(html.range(of: "</script>"))
            let context = try #require(JSContext())
            context.setObject(String(html[open.upperBound..<close.lowerBound]),
                              forKeyedSubscript: "SOURCE" as NSString)
            context.evaluateScript("new Function(SOURCE)")
            #expect(context.exception == nil,
                    "\(language.rawValue): \(context.exception?.toString() ?? "")")
        }
    }

    /// The behaviours the feature exists for, pinned against the markup the
    /// way `thePageHidesTheMarkerButtonOverPlayback` pins the operator page:
    /// a rename on either side of these contracts would otherwise fail only
    /// on a phone.
    @Test func theScriptPageKeepsItsContracts() throws {
        let html = try utf8(RemotePage.scriptHTML())
        // The running-take header follows the status' recording flag.
        #expect(html.contains("now.hidden = !next.recording"),
                "the header is no longer tied to the recording flag")
        // A field being edited is never clobbered by a push.
        #expect(html.contains("document.activeElement !== row.note"),
                "pushed state would clobber a field being typed in")
        // Comments save on blur/Enter, never per keystroke.
        #expect(html.contains(#"note.addEventListener("blur""#))
        #expect(!html.contains(#"note.addEventListener("input""#))
        // The page reads the watchdog it is handed, like the operator page.
        #expect(html.contains("watchdogMs:\(RemotePage.watchdogMilliseconds)"))
        #expect(html.contains("CFG.watchdogMs"))
    }

    /// Every label the script reads has to exist in both tables, or the page
    /// renders a raw key on a phone.
    @Test func everyScriptLabelIsTranslated() {
        for (field, key) in RemotePage.scriptLabels {
            for language in [AppLanguage.english, AppLanguage.russian] {
                let value = ViewRender.withLanguage(language) { L(key) }
                #expect(value != key,
                        "\(field) renders as its raw key in \(language.rawValue)")
            }
        }
    }
}
