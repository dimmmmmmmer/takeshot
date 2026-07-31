import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The tarpit's arithmetic, on its own clock.
///
/// The decay is a rolling window, and a window is the kind of thing that is
/// either right or off by exactly one attempt in a way nobody notices until a
/// unit on set cannot connect. Testing it against the wall clock would cost a
/// minute of suite per assertion, so the clock is handed in.
@Suite struct RemotePINTarpitTests {
    /// `count` failures, all at the same instant; the delay each was told to
    /// take comes back.
    private func guesses(_ count: Int, into tarpit: inout RemotePINTarpit,
                         at now: TimeInterval) -> [TimeInterval] {
        (0..<count).map { _ in tarpit.attempt(failed: true, now: now) }
    }

    /// A unit mistyping the code on two phones must not meet the delay at all.
    @Test func aHandfulOfWrongCodesIsStillAnsweredAtOnce() {
        var tarpit = RemotePINTarpit()
        let held = guesses(RemotePINTarpit.threshold, into: &tarpit, at: 100)
        #expect(held.allSatisfy { $0 == 0 })
        #expect(tarpit.attempt(failed: false, now: 100) == 0,
                "a right code was slowed before anyone was enumerating")
    }

    /// The point of the whole thing: past the threshold, the answer is held —
    /// and held for the right code exactly as long as for a wrong one, or the
    /// clock becomes the oracle the delay was meant to close.
    @Test func pastTheThresholdRightAndWrongWaitTheSame() {
        var tarpit = RemotePINTarpit()
        _ = guesses(RemotePINTarpit.threshold + 1, into: &tarpit, at: 100)
        #expect(tarpit.attempt(failed: true, now: 100) == RemotePINTarpit.delay)
        #expect(tarpit.attempt(failed: false, now: 100) == RemotePINTarpit.delay)
    }

    /// Never a lockout, and never an escalation either. However long the
    /// guessing goes on, the right code is answered the same two seconds late:
    /// a delay that climbed with the pressure would be a lockout wearing a
    /// duration, and the unit holding the code would meet it first.
    @Test func theDelayNeverGrowsPastTheOne() {
        var tarpit = RemotePINTarpit()
        _ = guesses(500, into: &tarpit, at: 100)
        #expect(tarpit.attempt(failed: false, now: 100) == RemotePINTarpit.delay)
        _ = guesses(5_000, into: &tarpit, at: 101)
        #expect(tarpit.attempt(failed: false, now: 101) == RemotePINTarpit.delay)
    }

    @Test func theDelayDecaysOnceTheGuessingStops() {
        var tarpit = RemotePINTarpit()
        _ = guesses(RemotePINTarpit.threshold + 1, into: &tarpit, at: 100)
        #expect(tarpit.attempt(failed: false, now: 100) == RemotePINTarpit.delay)

        let afterTheWindow = 100 + RemotePINTarpit.window
        #expect(tarpit.attempt(failed: false, now: afterTheWindow) == 0,
                "the tarpit stayed hot after the guessing stopped")
        #expect(tarpit.pressure == 0)
    }

    /// One guess a minute is a person, not a script, and must never be slowed
    /// however long they keep at it.
    @Test func attemptsFurtherApartThanTheWindowNeverAddUp() {
        var tarpit = RemotePINTarpit()
        var now: TimeInterval = 100
        for _ in 0..<50 {
            #expect(tarpit.attempt(failed: true, now: now) == 0,
                    "a guess a window apart was counted as an enumeration")
            now += RemotePINTarpit.window
        }
    }

    /// The delay slows the answers, not the sending: a script can keep firing,
    /// and what it fires at must not be a list that grows for a minute on a
    /// machine that is recording.
    @Test func aFloodIsRememberedBoundedly() {
        var tarpit = RemotePINTarpit()
        _ = guesses(50_000, into: &tarpit, at: 100)
        #expect(tarpit.pressure == RemotePINTarpit.threshold + 1)
        #expect(tarpit.attempt(failed: false, now: 100) == RemotePINTarpit.delay)
    }
}

/// The same thing through a real listener, real sockets and a real stopwatch.
///
/// Every assertion here is a DELTA from a measurement taken on the same machine
/// moments earlier. An absolute millisecond budget on a box that may be encoding
/// ProRes for another suite is a flake with a schedule.
@Suite @MainActor struct RemoteTarpitServerTests {
    /// The enumeration a per-socket cap does not touch: fresh connections, each
    /// staying well under the wrong codes one socket is allowed.
    private func enumerate(port: Int, wrong: String,
                           sockets: Int, each: Int) throws {
        for _ in 0..<sockets {
            let socket = try RemoteRawSocket(port: port)
            defer { socket.close() }
            try socket.handshake()
            for _ in 0..<each { socket.sendHello(pin: wrong) }
        }
    }

    /// Reconnecting used to make the four-digit space free to walk. It costs
    /// two seconds a guess now — and the right code costs the same two seconds,
    /// which is what keeps the stopwatch from telling them apart.
    @Test func guessesFromFreshSocketsSlowTheNextAnswerEitherWay() async throws {
        try await ControllerHarness.run { controller, _ in
            let (port, pin) = try await RemoteHarness.serve(controller)
            let server = try #require(controller.remoteServer)
            let wrong = RemoteHarness.wrongPIN(besides: pin)

            let cold = try await RemoteHarness.measureAuth(port: port, pin: pin)
            #expect(cold.ok, "the right code was refused on a quiet server")

            try enumerate(port: port, wrong: wrong,
                          sockets: 4, each: RemoteClient.maximumBadPINs - 3)
            let hot = await ControllerWait.until {
                server.pinPressure > RemotePINTarpit.threshold
            }
            try #require(hot, """
                the guesses never reached the server's own count \
                (\(server.pinPressure) failures registered)
                """)

            let refused = try await RemoteHarness.measureAuth(port: port,
                                                              pin: wrong)
            let accepted = try await RemoteHarness.measureAuth(port: port,
                                                               pin: pin)
            // Generous: the delay is two seconds and the baseline is a
            // loopback handshake. Anything between leaves room for a machine
            // under load without letting a missing tarpit pass.
            let margin = Duration.seconds(1)

            #expect(!refused.ok)
            #expect(accepted.ok, "the tarpit turned into a lockout")
            #expect(refused.elapsed > cold.elapsed + margin, """
                a wrong code was answered as fast as on a quiet server: \
                \(refused.elapsed) against \(cold.elapsed)
                """)
            #expect(accepted.elapsed > cold.elapsed + margin, """
                the right code was answered early while the tarpit was hot, \
                which is the oracle the delay is for: \
                \(accepted.elapsed) against \(cold.elapsed)
                """)
            let gap = refused.elapsed > accepted.elapsed
                ? refused.elapsed - accepted.elapsed
                : accepted.elapsed - refused.elapsed
            #expect(gap < margin, """
                right and wrong are told apart by a stopwatch: \
                \(accepted.elapsed) against \(refused.elapsed)
                """)
        }
    }

    /// The delay is on the answer, never on the queue. One serial queue carries
    /// every phone's traffic, so a tarpit that waited on it would stop the
    /// timecode on the whole set while somebody guessed.
    @Test func aHeldAnswerDoesNotStopTheOtherPhones() async throws {
        try await ControllerHarness.run { controller, root in
            try RemoteHarness.seedTake(controller, in: root, named: "A001C22",
                                       clip: 22)
            let (port, pin) = try await RemoteHarness.serve(controller)
            let server = try #require(controller.remoteServer)
            let wrong = RemoteHarness.wrongPIN(besides: pin)

            // A phone already on the socket, from before the guessing started.
            let phone = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { phone.close() }
            #expect(try await phone.next(type: "auth")["ok"] as? Bool == true)
            _ = try await phone.next(type: "status")

            try enumerate(port: port, wrong: wrong,
                          sockets: 4, each: RemoteClient.maximumBadPINs - 3)
            try #require(await ControllerWait.until {
                server.pinPressure > RemotePINTarpit.threshold
            })
            // A guess left mid-flight: its answer is parked on the queue right
            // now, which is the moment the readout must not stop.
            let guessing = try RemoteRawSocket(port: port)
            defer { guessing.close() }
            try guessing.handshake()
            guessing.sendHello(pin: wrong)

            controller.takes[0].rating = .good
            controller.pushRemoteStatus()
            // Bounded, and reading past whatever the pump had already queued:
            // the assertion is that the stream kept moving, not that this was
            // the very next frame on it.
            var rating = ""
            for _ in 0..<8 where rating != "good" {
                rating = try await phone.next(type: "status")["rating"]
                    as? String ?? ""
            }
            #expect(rating == "good",
                    "a held answer stalled the traffic of a phone already on")
        }
    }

    /// How long a rating button took to reach the controller, from the tap to
    /// the take carrying the new rating.
    private func rate(_ phone: RemoteTestClient, pin: String, to rating: TakeRating,
                      on controller: CaptureController) async throws -> Duration {
        let action = rating == .good ? "good" : "bad"
        let started = ContinuousClock.now
        try await phone.send(action: action, pin: pin)
        let landed = await ControllerWait.until {
            controller.takes.first?.rating == rating
        }
        let elapsed = started.duration(to: .now)
        try #require(landed, "the \(action) button never reached the controller")
        return elapsed
    }

    /// How long a refused command took to be answered on an open socket. The
    /// same call either side of a burst of guessing is what makes the assertion
    /// a delta rather than a millisecond budget on somebody else's machine.
    private func refusal(_ phone: RemoteTestClient,
                         pin wrong: String) async throws -> Duration {
        let started = ContinuousClock.now
        try await phone.send(action: "good", pin: wrong)
        // Read past the status pushes a held answer leaves in front of the
        // refusal — four a second, and the refusal comes out behind them.
        #expect(try await phone.next(type: "auth",
                                     within: 40)["ok"] as? Bool == false)
        return started.duration(to: .now)
    }

    /// The delay must never reach the phone that holds the code. Every message
    /// carries the PIN, so without this the operator's own REC button is two
    /// seconds late for as long as somebody else keeps guessing — which is the
    /// lockout the whole design refuses, wearing a duration instead of a
    /// refusal, and it lands on the head of a take.
    @Test func aPhoneAlreadyOnTheSocketKeepsItsButtons() async throws {
        try await ControllerHarness.run { controller, root in
            try RemoteHarness.seedTake(controller, in: root, named: "A001C30",
                                       clip: 30)
            let (port, pin) = try await RemoteHarness.serve(controller)
            let server = try #require(controller.remoteServer)
            let wrong = RemoteHarness.wrongPIN(besides: pin)

            let phone = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { phone.close() }
            #expect(try await phone.next(type: "auth")["ok"] as? Bool == true)

            // The same button on a quiet server, for the delta to be read from.
            let cold = try await rate(phone, pin: pin, to: .good, on: controller)

            try enumerate(port: port, wrong: wrong,
                          sockets: 4, each: RemoteClient.maximumBadPINs - 3)
            try #require(await ControllerWait.until {
                server.pinPressure > RemotePINTarpit.threshold
            })

            let hot = try await rate(phone, pin: pin, to: .bad, on: controller)
            #expect(hot < cold + .seconds(1), """
                the operator's own button was held back by somebody else's \
                guessing: \(hot) against \(cold)
                """)
        }
    }

    /// The exemption is for a code that still matches, not for a socket that
    /// once showed one. A page whose PIN has been rotated under it is back to
    /// paying, or an attacker who had yesterday's code would walk today's for
    /// free from a socket that is already open.
    @Test func aRotatedCodeOnAnOpenSocketPaysAgain() async throws {
        try await ControllerHarness.run { controller, root in
            try RemoteHarness.seedTake(controller, in: root, named: "A001C31",
                                       clip: 31)
            let (port, pin) = try await RemoteHarness.serve(controller)
            let server = try #require(controller.remoteServer)
            let wrong = RemoteHarness.wrongPIN(besides: pin)

            let phone = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { phone.close() }
            #expect(try await phone.next(type: "auth")["ok"] as? Bool == true)

            // The same refusal either side of the guessing, so what is compared
            // is one operation against itself on one machine.
            let cold = try await refusal(phone, pin: wrong)

            try enumerate(port: port, wrong: wrong,
                          sockets: 4, each: RemoteClient.maximumBadPINs - 3)
            try #require(await ControllerWait.until {
                server.pinPressure > RemotePINTarpit.threshold
            })

            let hot = try await refusal(phone, pin: wrong)
            #expect(hot > cold + .seconds(1), """
                a wrong code on an authenticated socket was answered as fast as \
                on a quiet server, which is the whole four-digit space at no \
                cost: \(hot) against \(cold)
                """)
            #expect(controller.takes.first?.rating == TakeRating.none,
                    "a refused command still reached the controller")
        }
    }

    /// The poster endpoint checks the same four digits over plain HTTP. Left
    /// out of the tarpit it would be the cheaper of the two to walk — no
    /// handshake, no frame, one GET per guess — and the socket's delay would be
    /// worth nothing.
    @Test func thePosterEndpointFeedsAndPaysTheSameTarpit() async throws {
        try await ControllerHarness.run { controller, root in
            try RemoteHarness.seedTake(controller, in: root, named: "A001C23",
                                       clip: 23)
            let (port, pin) = try await RemoteHarness.serve(controller)
            let server = try #require(controller.remoteServer)
            let wrong = RemoteHarness.wrongPIN(besides: pin)

            let cold = try await RemoteHarness.poster(port: port, pin: wrong)
            #expect(cold.http.statusCode == 403)

            for _ in 0...RemotePINTarpit.threshold {
                _ = try await RemoteHarness.poster(port: port, pin: wrong)
            }
            #expect(server.pinPressure > RemotePINTarpit.threshold,
                    "guessing over HTTP never reached the server's count")

            let hot = try await RemoteHarness.poster(port: port, pin: wrong)
            #expect(hot.http.statusCode == 403)
            #expect(hot.elapsed > cold.elapsed + .seconds(1), """
                the poster endpoint answers a PIN for free: \
                \(hot.elapsed) against \(cold.elapsed)
                """)
        }
    }
}
