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
        // Cut, then read as a number — and an ellipsis is not one, which is
        // the honest answer to five thousand digits nobody slated.
        #expect(slate.take == 0)
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
    /// Each command carries its own index as the comment text, so the take
    /// itself reports how many got through.
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
            // — which would look exactly like the ceiling doing its job.
            let drain = Task { @MainActor in
                while true { _ = try await client.task.receive() }
            }
            defer { drain.cancel() }

            let identifier: String = take.id.uuidString
            let sent: Int = Int(RemoteClient.commandBurst) + 256
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

            let overran: Bool = await ControllerWait.until(
                { Self.landed(controller) >= sent - 1 }, timeout: .seconds(2))
            #expect(!overran,
                    "a socket spent more commands than the ceiling allows")
        }
    }

    /// The index of the last command that reached the controller.
    private static func landed(_ controller: CaptureController) -> Int {
        Int(controller.takes.first?.comment ?? "") ?? -1
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
