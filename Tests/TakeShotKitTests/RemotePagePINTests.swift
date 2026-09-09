import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **A code per page** (owner: "пины на все страницы ремоута кстати хочу иметь
/// уникальные").
///
/// The second AC holding the slate and the script supervisor with the take log
/// are not handed the code that presses REC. The operator's code stays the
/// master — it opens every page — so whoever set the remote up is never locked
/// out of their own rig by the split.
@Suite @MainActor struct RemotePagePINTests {
    @Test func everyPageGetsACodeOfItsOwn() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.ensureRemotePIN()
            let pins = [controller.settings.remote.pin,
                        controller.settings.remote.slatePIN,
                        controller.settings.remote.livePIN,
                        controller.settings.remote.scriptPIN]
                .compactMap { $0 }
            #expect(pins.count == 4, "a page has no code: \(pins)")
            #expect(Set(pins).count == 4,
                    "two pages share a code: \(pins)")
            for pin in pins {
                #expect(pin.count == RemoteSettings.pinLength)
                #expect(pin.allSatisfy { $0.isNumber })
            }
        }
    }

    /// Ensuring twice keeps the codes: they are read out to a unit and written
    /// on a piece of tape, so a relaunch that changed them would be a rig
    /// nobody can get back into.
    @Test func theCodesSurviveBeingEnsuredAgain() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.ensureRemotePIN()
            let before = [controller.settings.remote.pin,
                          controller.settings.remote.slatePIN,
                          controller.settings.remote.livePIN,
                          controller.settings.remote.scriptPIN]
            controller.ensureRemotePIN()
            let after = [controller.settings.remote.pin,
                         controller.settings.remote.slatePIN,
                         controller.settings.remote.livePIN,
                         controller.settings.remote.scriptPIN]
            #expect(before == after)
        }
    }

    /// **One page at a time.** Rotating the slate's code because a runner
    /// walked off with the phone must not lock out the script supervisor.
    @Test func rotatingOneCodeLeavesTheOthersAlone() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.ensureRemotePIN()
            let operatorPIN = controller.settings.remote.pin
            let script = controller.settings.remote.scriptPIN
            let slate = controller.settings.remote.slatePIN

            controller.regenerateRemotePIN(for: .slate)
            #expect(controller.settings.remote.slatePIN != slate)
            #expect(controller.settings.remote.scriptPIN == script)
            #expect(controller.settings.remote.pin == operatorPIN)

            controller.regenerateRemotePIN()
            #expect(controller.settings.remote.pin != operatorPIN,
                    "the default rotation missed the operator's code")
        }
    }

    /// A hand-edited blob with a three-digit code gets a real one rather than
    /// a page nobody can open.
    @Test func aBrokenStoredCodeIsReplaced() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.remote.slatePIN = "12"
            controller.settings.remote.scriptPIN = "abcd"
            controller.ensureRemotePIN()
            #expect(controller.settings.remote.slatePIN?.count
                == RemoteSettings.pinLength)
            #expect(controller.settings.remote.scriptPIN?
                .allSatisfy { $0.isNumber } == true)
        }
    }

    /// The three page codes reach the server; the operator's does not go in
    /// with them, because it is the master and is held separately.
    @Test func theServerIsHandedThePageCodes() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.ensureRemotePIN()
            let pins = controller.remotePagePINs
            #expect(Set(pins.keys) == ["slate", "live", "script"],
                    "\(pins.keys)")
            #expect(!pins.values.contains(controller.settings.remote.pin ?? ""),
                    "the master code was handed out as a page code")
        }
    }
}

/// **What a code is allowed to do.**
///
/// Separate codes only mean something if the role they grant is enforced —
/// otherwise the slate's code, typed into the operator page, presses REC.
@Suite struct RemoteRoleTests {
    @Test func theOperatorsCodeMaySendEverything() {
        let role = RemoteRole.operatorRemote
        for command in Self.everyCommand {
            #expect(role.maySend(command),
                    Comment(rawValue: "the master code was refused \(command)"))
        }
    }

    /// The slate is a face pointed at a lens. It sends nothing at all, and its
    /// code buys nothing at all.
    @Test func theSlatesCodePressesNothing() {
        let role = RemoteRole.page(.slate)
        for command in Self.everyCommand where command != .hello {
            #expect(!role.maySend(command),
                    Comment(rawValue: "the slate's code could send \(command)"))
        }
        #expect(role.maySend(.hello), "the slate cannot even say hello")
    }

    /// **The script supervisor edits takes; they do not roll the camera.**
    @Test func theScriptsCodeEditsTakesAndDoesNotRecord() {
        let role = RemoteRole.page(.script)
        #expect(role.maySend(.rate(takeID: "1", rating: .good)))
        #expect(role.maySend(.comment(takeID: "1", text: "x")))
        #expect(!role.maySend(.rec), "the script page's code could press REC")
        #expect(!role.maySend(.marker))
    }

    /// …and the operator page's own code presses its four buttons and does not
    /// rewrite the take log.
    @Test func theOperatorPagesCodePressesItsFourButtons() {
        let role = RemoteRole.page(.remote)
        for command in [RemoteCommand.rec, .marker, .good, .bad] {
            #expect(role.maySend(command),
                    Comment(rawValue: "the operator page was refused \(command)"))
        }
        #expect(!role.maySend(.comment(takeID: "1", text: "x")),
                "the operator page's code could rewrite a take's comment")
    }

    /// The live page is a video element: it subscribes and sends no commands.
    @Test func theLivePagesCodeOnlySubscribes() {
        let role = RemoteRole.page(.live)
        #expect(role.maySend(.multiview(on: true)))
        #expect(!role.maySend(.rec))
        #expect(!role.maySend(.rate(takeID: "1", rating: .good)))
    }

    static let everyCommand: [RemoteCommand] = [
        .hello, .rec, .marker, .good, .bad, .multiview(on: true),
        .rate(takeID: "1", rating: .good),
        .comment(takeID: "1", text: "x"),
        .slate(takeID: "1", slate: SlateMetadata(scene: "1", shot: 1, take: 1)),
    ]
}

/// **The role is ENFORCED**, not merely described.
///
/// `RemoteRoleTests` above pins the rule; this drives a real socket through a
/// real server and watches what the server DISPATCHES. Two earlier versions of
/// this test passed with the enforcement deleted: the first asserted the rule
/// again, and the second watched `isRecording` — which stays false on a
/// machine with no board whether the command arrived or not. What the app then
/// does with a command is a different question from whether it got one.
@Suite @MainActor struct RemoteRoleEnforcementTests {
    private func serve(_ box: RemoteFailureBox,
                       pagePINs: [String: String]) async throws -> Int {
        let server = RemoteServer(pin: "1234", pagePINs: pagePINs,
                                  page: Data("x".utf8),
                                  slatePage: Data("s".utf8),
                                  handlers: box.handlers())
        server.start(port: 0)
        let up: Bool = await ControllerWait.until { box.boundPort > 0 }
        try #require(up, "the listener never came up")
        servers.append(server)
        return Int(box.boundPort)
    }

    /// Kept alive for the test's duration and stopped after — a listener left
    /// running holds its port against the next suite.
    private final class Box: @unchecked Sendable {
        var servers: [RemoteServer] = []
        deinit { for server in servers { server.stop() } }
    }

    private let box = Box()
    private var servers: [RemoteServer] {
        get { box.servers }
        nonmutating set { box.servers = newValue }
    }

    @Test func aSlateCodeCannotPressRecord() async throws {
        let recorder = RemoteFailureBox()
        let port = try await serve(recorder, pagePINs: ["slate": "9876"])
        let client = RemoteTestClient(
            task: RemoteHarness.session().webSocketTask(
                with: try #require(URL(string: "ws://127.0.0.1:\(port)/ws"))))
        client.task.resume()
        defer { client.task.cancel() }

        // In as the slate, with the slate's own code.
        try await client.send(["action": "hello", "pin": "9876",
                               "page": "slate"])
        try await client.send(["action": "rec", "pin": "9876",
                               "page": "slate"])
        try await Task.sleep(for: .milliseconds(400))
        #expect(recorder.commands.isEmpty,
                "the slate's code reached the app with \(recorder.commands)")
    }

    /// …and the operator's code, which is the master, gets through — so the
    /// test above is about the ROLE and not about a socket that never worked.
    @Test func theOperatorsCodeReachesTheApp() async throws {
        let recorder = RemoteFailureBox()
        let port = try await serve(recorder, pagePINs: ["slate": "9876"])
        let client = RemoteTestClient(
            task: RemoteHarness.session().webSocketTask(
                with: try #require(URL(string: "ws://127.0.0.1:\(port)/ws"))))
        client.task.resume()
        defer { client.task.cancel() }

        try await client.send(["action": "hello", "pin": "1234",
                               "page": "remote"])
        try await client.send(["action": "rec", "pin": "1234",
                               "page": "remote"])
        let arrived: Bool = await ControllerWait.until {
            recorder.commands.contains(.rec)
        }
        #expect(arrived, "the master code's REC never reached the app")
    }

    /// The slate's code on the SLATE page is still accepted — it opens the
    /// page, which is what it is for. What it does not buy is the buttons.
    @Test func aSlateCodeStillOpensItsOwnPage() async throws {
        let recorder = RemoteFailureBox()
        let port = try await serve(recorder, pagePINs: ["slate": "9876"])
        let client = RemoteTestClient(
            task: RemoteHarness.session().webSocketTask(
                with: try #require(URL(string: "ws://127.0.0.1:\(port)/ws"))))
        client.task.resume()
        defer { client.task.cancel() }
        try await client.send(["action": "hello", "pin": "9876",
                               "page": "slate"])
        let opened: Bool = await ControllerWait.until {
            self.servers.first?.clientCount == 1
        }
        #expect(opened, "the slate's own code was refused its own page")
    }
}

/// **All four codes stay out of a diagnostics bundle.**
///
/// The bundle gets emailed to somebody. The redaction drops a key whose NAME
/// marks it a secret, and the three new keys carry "PIN" for exactly that
/// reason — which is a property worth asserting rather than assuming, because
/// a key named `remoteSlateCode` would have been just as natural to write and
/// would have shipped the code.
@Suite struct RemotePINRedactionTests {
    @Test func noPageCodeReachesADiagnosticsBundle() {
        for key in ["remotePIN", "remoteSlatePIN", "remoteLivePIN",
                    "remoteScriptPIN"] {
            #expect(DiagnosticsRedaction.isSecretKey(key),
                    Comment(rawValue: "\(key) would be emailed out"))
        }
        // …and the check is about the NAME, so an ordinary key is untouched.
        #expect(!DiagnosticsRedaction.isSecretKey("remotePort"))
    }
}
