import CaptureCore
import Foundation
import Network
import Testing

@testable import TakeShotKit

/// What a socket that HAS the code may spend.
///
/// The PIN is four digits by decision, so "authenticated" is not the same as
/// "trusted": a phone that changed hands, a page stuck in a retry loop, or a
/// handset in somebody's pocket all arrive here holding a valid code. What they
/// must not be able to do is write unbounded text into the day's paperwork, or
/// turn one message into one rewrite of four sidecar files on the volume a take
/// is being recorded to.
@Suite struct RemoteTextBoundTests {
    /// Where the number comes from, as an assertion rather than a comment.
    ///
    /// A take's comment is written into the EDL as a CMX 3600 comment line and
    /// CMX is an 80-column format — this codebase already treats that as
    /// binding at `EDLExporter.ascLines`. Move the bound without moving the
    /// reason and this is what says so.
    @Test func theBoundIsTheCommentLineItHasToFit() {
        let lead = "* COMMENT: "
        #expect(lead.count + RemoteCommand.maximumTextLength == 80,
                "the text bound no longer fits the CMX comment line it came from")
    }

    /// A note that fits is untouched — the bound must be invisible to the
    /// people it is not for.
    @Test func aRealNoteIsCarriedExactly() throws {
        let note = "soft focus second half, boom dipped, gate check after"
        let message: RemoteMessage = try #require(RemoteMessage.parse(
            #"{"action":"comment","id":"a","text":"\#(note)","pin":"1"}"#))
        guard case .comment(_, let text) = message.command else {
            Issue.record("a comment command did not parse")
            return
        }
        #expect(text == note)
    }

    /// And one that does not fit is cut where the format ends, with a mark the
    /// person who typed it can see: the edit comes straight back down the
    /// socket in the next take-log push, so an ellipsis is the difference
    /// between a scripty knowing their note was shortened and a note in the
    /// CSV that says something they did not write.
    @Test func aNoteTooLongForTheFormatIsCutAndSaysSo() throws {
        let long = String(repeating: "x", count: 5_000)
        let message: RemoteMessage = try #require(RemoteMessage.parse(
            #"{"action":"comment","id":"a","text":"\#(long)","pin":"1"}"#))
        guard case .comment(_, let text) = message.command else {
            Issue.record("a comment command did not parse")
            return
        }
        #expect(text.count == RemoteCommand.maximumTextLength)
        #expect(text.hasSuffix("…"), "a cut note gave no sign it had been cut")
    }

    /// The slate travels the same way and pays the same bound — all three
    /// fields, because a slate commits as a unit.
    ///
    /// The two TEXT fields pay the text bound. The take number pays a different
    /// one and always did: it is a number, so what protects it is the take
    /// field's own ceiling (`SlateTakeField.maximum`) rather than a character
    /// count.
    ///
    /// **This test used to expect 0 here, and the 0 was an accident.** The old
    /// parse was `Int(bounded(text))`, so the answer turned over at the width of
    /// `Int` and nowhere else — measured across lengths: 5 digits gave 99999,
    /// **18 digits gave 999999999999999999**, and 19 gave 0. Five thousand
    /// digits landed on the safe side of that cliff and the unsafe side was one
    /// digit away, with nothing testing it. `slate.take` is written into the
    /// .mov's metadata at `TakeWriter` time and into the Take column of
    /// `takeshot-slate.csv` and the ALE, so an eighteen-digit take number off
    /// the network reached the deliverables.
    ///
    /// Reading it with `SlateTakeField` — the same rule the two TAKE fields on
    /// the desktop use — makes the bound the same at every length, which is
    /// what this now pins.
    @Test func theSlateFieldsAreBoundedToo() throws {
        let long = String(repeating: "9", count: 5_000)
        let json: String = #"{"action":"slate","id":"a","scene":"\#(long)""#
            + #","shot":"\#(long)","take":"\#(long)","pin":"1"}"#
        let message: RemoteMessage = try #require(RemoteMessage.parse(json))
        guard case .slate(_, let slate) = message.command else {
            Issue.record("a slate command did not parse")
            return
        }
        #expect(slate.scene.count == RemoteCommand.maximumTextLength)
        #expect(slate.shot.count == RemoteCommand.maximumTextLength)
        #expect(slate.take == SlateTakeField.maximum)
    }

    /// The take number's bound does not move with the length of what was sent.
    /// Every one of these used to give a different answer, and the two in the
    /// middle reached the sidecars.
    @Test func aTakeNumberOffTheWireIsBoundedAtEveryLength() throws {
        for digits in [5, 18, 19, 60, 5_000] {
            let long = String(repeating: "9", count: digits)
            let json: String = #"{"action":"slate","id":"a","scene":"12""#
                + #","shot":"B","take":"\#(long)","pin":"1"}"#
            let message: RemoteMessage = try #require(RemoteMessage.parse(json))
            guard case .slate(_, let slate) = message.command else {
                Issue.record("a slate command did not parse at \(digits) digits")
                return
            }
            #expect(slate.take == SlateTakeField.maximum,
                    "\(digits) digits logged take \(slate.take)")
        }
    }
}

/// The two bounds that protect the disk a take is being written to.
@Suite @MainActor struct RemoteWriteRateTests {
    /// `exportTakeLog` rewrites four sidecar files on the record volume, and
    /// the remote's `rate` command lands on `setRating`. Without the guard its
    /// two siblings already had, a page repeating a rating the take already has
    /// is one full rewrite per message.
    ///
    /// The absence of a write is the whole claim, so it is watched for
    /// directly: the sidecar is deleted and must not come back.
    @Test func ratingATakeWhatItAlreadyIsRewritesNothing() async throws {
        try await ControllerHarness.run { controller, root in
            let take: Take = try RemoteHarness.seedTake(
                controller, in: root, named: "A001C42", clip: 42)
            let log: URL = root.appendingPathComponent(TakeLogExporter.fileName)

            controller.setRating(.good, for: take)
            await ControllerWait.fileExists(at: log)
            try FileManager.default.removeItem(at: log)

            controller.setRating(.good, for: take)
            let rewritten: Bool = await ControllerWait.until(
                { FileManager.default.fileExists(atPath: log.path) },
                timeout: .seconds(2))
            #expect(!rewritten, "a rating a take already had rewrote the sidecars")

            // And a real change still writes, or the guard has eaten the
            // feature rather than the churn.
            controller.setRating(.bad, for: take)
            let changed: Bool = await ControllerWait.untilWritten {
                FileManager.default.fileExists(atPath: log.path)
            }
            #expect(changed, "a real rating change stopped writing the sidecars")
        }
    }

    /// The ceiling has to be above every burst a real page produces and far
    /// below what a loop does, so both halves are asserted here. The burst a
    /// real page produces is `script.html`'s `flushPending` after the socket
    /// comes back: one comment and one slate per take.
    ///
    /// **The second half is a RATE, and it has to be asserted as one.** This
    /// used to send `commandBurst + 256` commands and require that the last of
    /// them never reached the controller — which is not what a token bucket
    /// promises. `commandBurst` at once and `commandsPerSecond` afterwards
    /// means 768 commands ARE allowed, over sixteen seconds; the old assertion
    /// held only while the send loop outran the refill, and it went red on the
    /// development Mac with three other test batteries running. Giving it more
    /// room would have been worse than the flake: a bound that only holds on
    /// an idle machine is not a bound, and this one exists for a phone
    /// spending the app's time exactly when the app is busiest.
    ///
    /// So the claim is now the bucket's own — over however long this machine
    /// took, no more than `commandBurst + commandsPerSecond × elapsed` were
    /// honoured. That holds at any speed, and it pins the refill RATE, which
    /// the old shape never checked at all. `RemoteClient.commandsHonoured` is
    /// what makes it visible: a refused command is dropped silently, so the
    /// wire cannot say how many got through.
    ///
    /// Each command still carries its own index as the comment text, so the
    /// take reports how far into the flood the socket got — and the pace is
    /// PRINTED, because on a machine too slow to outrun the refill the
    /// guarantee is not violated by anything and a reader should be able to
    /// see that rather than read a green tick as a measurement. Same house
    /// rule as `MultiviewPerformanceTests`: a runner's clock measures the
    /// runner.
    @Test func aSocketCannotSpendMoreCommandsThanAPageEverProduces() async throws {
        try await ControllerHarness.run { controller, root in
            let take: Take = try RemoteHarness.seedTake(
                controller, in: root, named: "A001C43", clip: 43)
            let served = try await RemoteHarness.serve(controller)
            let client = try await RemoteHarness.connect(
                port: served.port, pin: served.pin,
                session: RemoteHarness.session())
            defer { client.close() }
            _ = try await client.next(type: "auth")
            // `URLSessionWebSocketTask` only drains the wire while a receive is
            // pending, and this test pushes hundreds of commands, each of which
            // comes back as a status and a take log. Without a reader the
            // client's own window shuts and the server drops it for the stall
            // — which would look exactly like the ceiling doing its job, and
            // `RemoteDrain` is what tells the two apart: it records an issue
            // the moment its own socket fails, instead of ending a task
            // nothing is awaiting and leaving the ledger below to read low for
            // a reason that has nothing to do with the ceiling.
            let drain = RemoteDrain(client)
            defer { drain.stop() }

            let server: RemoteServer = try #require(controller.remoteServer)
            let identifier: String = take.id.uuidString
            let sent: Int = Int(RemoteClient.commandBurst) + 256
            let started: ContinuousClock.Instant = .now
            for index in 0..<sent {
                try await client.send(["action": "comment",
                                       "id": identifier,
                                       "text": "\(index)",
                                       "pin": served.pin])
            }

            let honoured: Bool = await ControllerWait.untilWritten {
                Self.landed(controller) >= Int(RemoteClient.commandBurst) - 1
            }
            #expect(honoured,
                    "the ceiling cut into a burst a real page can produce")

            // The full-budget wait that proves a change did NOT happen, kept
            // as it was: a ceiling that stopped working shows as the whole
            // flood landing, and this is where that would appear. It also
            // gives the server time to finish READING the tail of the flood,
            // which is what the ledger below counts. It costs the allowance
            // two seconds of refill — 32 commands against a discrimination of
            // 768 to 547 — and a broken ceiling leaves it early anyway.
            _ = await ControllerWait.until(
                { Self.landed(controller) >= sent - 1 }, timeout: .seconds(2))

            let elapsed: Double = Self.seconds(started.duration(to: .now))
            let allowance: Double = RemoteClient.commandBurst
                + RemoteClient.commandsPerSecond * elapsed
            let spent: Int = server.commandsHonoured
            print("command ceiling: \(spent) of \(sent) honoured in "
                + "\(Self.rounded(elapsed)) s; the allowance over that time is "
                + "\(Int(allowance))")
            let overrun: String = "a socket spent \(spent) commands in "
                + "\(Self.rounded(elapsed)) s, against an allowance of "
                + "\(Int(allowance))"
            #expect(Double(spent) <= allowance, "\(overrun)")
        }
    }

    /// The index of the last command that reached the controller.
    private static func landed(_ controller: CaptureController) -> Int {
        Int(controller.takes.first?.comment ?? "") ?? -1
    }

    /// A `Duration` as seconds, and as text. Both spelled out rather than
    /// inferred — the runner's compiler is a version behind and these are test
    /// expressions (see CLAUDE.md).
    private static func seconds(_ duration: Duration) -> Double {
        let parts: (seconds: Int64, attoseconds: Int64) = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func rounded(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// The set's own ceiling, which the per-socket one does not imply: eight
    /// sockets each inside their own limit still reach a hundred and twenty-eight
    /// commands a second on the volume the take is being written to.
    ///
    /// The arithmetic is checked directly rather than by sending a thousand real
    /// commands — that would spend the suite's time rewriting sidecars to prove
    /// a token bucket.
    @Test func theSetHasOneCommandAllowanceBetweenAllOfIt() async throws {
        try await ControllerHarness.run { controller, _ in
            _ = try await RemoteHarness.serve(controller)
            let server: RemoteServer = try #require(controller.remoteServer)
            let spent: Int = server.drainCommandAllowance()
            #expect(spent == Int(RemoteServer.commandBurst),
                    "the set's command burst is not the number it says it is")
        }
    }

    /// And that it is ONE bucket rather than one each: a socket must be refused
    /// on an allowance somebody else spent.
    ///
    /// Driven from an exhausted server rather than from a thousand messages, for
    /// the reason above — what needs proving here is the wiring, not the sum.
    @Test func aSocketIsRefusedOnAnAllowanceAnotherSpent() async throws {
        try await ControllerHarness.run { controller, root in
            let take: Take = try RemoteHarness.seedTake(
                controller, in: root, named: "A001C44", clip: 44)
            let served = try await RemoteHarness.serve(controller)
            let server: RemoteServer = try #require(controller.remoteServer)
            let client = try await RemoteHarness.connect(
                port: served.port, pin: served.pin,
                session: RemoteHarness.session())
            defer { client.close() }
            _ = try await client.next(type: "auth")

            _ = server.drainCommandAllowance()
            try await client.send(["action": "comment",
                                   "id": take.id.uuidString,
                                   "text": "42", "pin": served.pin])
            let landed: Bool = await ControllerWait.until(
                { controller.takes.first?.comment == "42" },
                timeout: .seconds(2))
            #expect(!landed,
                    "a socket spent a command the set had no allowance left for")
        }
    }
}

/// The rating guard, driven the way a phone drives it.
///
/// Its own suite because the claim is about the SOCKET path: the controller-level
/// test next door proves the guard exists, and would go on passing if
/// `perform(remote:)` were changed to bypass `setRating` altogether.
@Suite @MainActor struct RemoteRatingChurnTests {
    @Test func aPhoneRepeatingARatingRewritesNothing() async throws {
        try await ControllerHarness.run { controller, root in
            let take: Take = try RemoteHarness.seedTake(
                controller, in: root, named: "A001C45", clip: 45)
            let log: URL = root.appendingPathComponent(TakeLogExporter.fileName)
            let served = try await RemoteHarness.serve(controller)
            let client = try await RemoteHarness.connect(
                port: served.port, pin: served.pin,
                session: RemoteHarness.session())
            defer { client.close() }
            _ = try await client.next(type: "auth")

            let rate: [String: Any] = ["action": "rate",
                                       "id": take.id.uuidString,
                                       "rating": "good", "pin": served.pin]
            try await client.send(rate)
            let rated: Bool = await ControllerWait.untilWritten {
                controller.takes.first?.rating == TakeRating.good
            }
            try #require(rated, "the rating from the page never landed")
            await ControllerWait.fileExists(at: log)
            try FileManager.default.removeItem(at: log)

            // The same rating again, from the same page. Nothing to write.
            try await client.send(rate)
            let rewritten: Bool = await ControllerWait.until(
                { FileManager.default.fileExists(atPath: log.path) },
                timeout: .seconds(2))
            #expect(!rewritten,
                    "a phone repeating a rating rewrote the sidecars on the record volume")
        }
    }
}

/// That a PIN cannot be verified anywhere that does not pay for it.
///
/// Stated as a rule about WHERE the comparison lives rather than as a list of
/// today's endpoints, because a list of endpoints is itself a thing that goes
/// stale: the next person adds a route, checks a code in it, and no assertion
/// anywhere notices that the tarpit stopped covering the cheapest way in.
@Suite struct RemotePINDoorTests {
    /// The comparison happens in `RemoteServer.swift` and nowhere else under
    /// `Sources`. That file is the one door (`RemoteServer.checkPIN`), and it
    /// charges the tarpit on every path through it.
    @Test func aPINIsComparedInExactlyOnePlace() throws {
        let sources: URL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var reachable = ObjCBool(false)
        try #require(FileManager.default.fileExists(atPath: sources.path,
                                                   isDirectory: &reachable),
                     "the Sources tree was not where this test looked for it")

        let walker = try #require(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil),
                                  "the Sources tree could not be walked")
        var callers: [String] = []
        var swiftFiles = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            swiftFiles += 1
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("RemotePIN.matches(") else { continue }
            callers.append(url.lastPathComponent)
        }
        try #require(swiftFiles > 100, "the walk did not find the source tree")
        #expect(callers.sorted() == ["RemoteServer.swift"],
                "a PIN is compared somewhere that does not charge the tarpit")
    }
}

/// Who the tarpit charges.
@Suite struct RemotePeerIdentityTests {
    /// The ledger key, for the endpoint shapes Network.framework hands over.
    @Test func anEndpointBecomesItsHostAddress() {
        let port: NWEndpoint.Port = 8765
        #expect(RemoteClient.address(
            of: .hostPort(host: .ipv4(.loopback), port: port)) == "127.0.0.1")
        #expect(RemoteClient.address(
            of: .hostPort(host: .ipv6(.loopback), port: port)) == "::1")
        #expect(RemoteClient.address(
            of: .hostPort(host: .name("phone.local", nil), port: port))
            == "phone.local")
        // Anything else falls into one shared bucket, which is the old
        // server-wide behaviour as a fallback rather than as the rule.
        #expect(RemoteClient.address(of: .service(
            name: "x", type: "_x._tcp", domain: "local", interface: nil)) == "")
    }

    /// And the assumption underneath it, against a real accepted connection:
    /// `NWConnection.endpoint` on a socket a listener took is the peer's
    /// address and not the listener's own.
    @Test @MainActor func anAcceptedSocketIsLedgeredByThePeerAddress() async throws {
        try await ControllerHarness.run { controller, _ in
            let served = try await RemoteHarness.serve(controller)
            let server: RemoteServer = try #require(controller.remoteServer)
            let client = try await RemoteHarness.connect(
                port: served.port, pin: served.pin,
                session: RemoteHarness.session())
            defer { client.close() }
            _ = try await client.next(type: "auth")

            let peers: [String] = server.clientPeers
            #expect(peers == ["127.0.0.1"],
                    "a connection was not ledgered by the address it came from")
        }
    }
}
