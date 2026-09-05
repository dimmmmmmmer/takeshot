import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The remote's lifecycle: the port it binds, the port it gives back, the PIN,
/// and what the operator is told when the listener cannot be had. The socket
/// itself is next door in `RemoteServerTests`.
@Suite @MainActor struct RemoteLifecycleTests {
    @Test func stoppingTheServerReleasesThePort() async throws {
        try await ControllerHarness.run { controller, _ in
            let (port, _) = try await RemoteHarness.serve(controller)
            let url = try HTTPURLProbe.url(port: port)
            #expect(await HTTPURLProbe.reachable(url), "the page never came up")

            controller.stopRemoteServer()
            #expect(controller.remoteServer == nil)
            #expect(controller.remoteBoundPort == 0)
            let refused = await HTTPURLProbe.unreachableWithin(url)
            #expect(refused, "the port is still answering after stop")
        }
    }

    /// Cancelling a listener is asynchronous: the socket is still bound for a
    /// while after `stop()` returns. An operator who switches the remote off and
    /// straight back on, or edits the port and puts it back, meets that race —
    /// and used to be told the port was in use and left with a switch that had
    /// turned itself off.
    @Test func theSamePortIsRebindableStraightAfterAStop() async throws {
        try await ControllerHarness.run { controller, _ in
            let (port, _) = try await RemoteHarness.serve(controller)
            let url = try HTTPURLProbe.url(port: port)
            controller.settings.remote.enabled = true // the switch, as the operator left it
            controller.stopRemoteServer()

            // No wait between the two on purpose: the collision is the point.
            controller.startRemoteServer(overridePort: port)
            let up = await ControllerWait.until { controller.remoteBoundPort == port }
            #expect(up, """
                the remote could not have its own port back: \
                \(controller.lastError ?? "nothing was reported")
                """)
            #expect(await HTTPURLProbe.reachable(url))
            #expect(controller.lastError == nil)
            #expect(controller.settings.remote.enabled == true,
                    "the rebind switched the remote off")
        }
    }

    /// The port field writes the number it is showing, so the operator's first
    /// keystroke in it turns nil into 8765 without moving the listener anywhere.
    /// Read as a port change, that tore down a working listener mid-shoot — and
    /// would have this suite claim the app's real port on the machine running it.
    @Test func touchingThePortFieldKeepsTheListenerWhereItIs() async throws {
        try await ControllerHarness.run { controller, _ in
            let (port, _) = try await RemoteHarness.serve(controller)
            let url = try HTTPURLProbe.url(port: port)
            controller.settings.remote.enabled = true

            controller.settings.remote.port = CaptureSettings().remote.portEffective

            #expect(controller.remoteBoundPort == port,
                    "the listener moved: \(controller.remoteBoundPort) not \(port)")
            #expect(await HTTPURLProbe.reachable(url))
            #expect(controller.lastError == nil)
        }
    }

    /// The rebind that collides, made to collide.
    ///
    /// `stop()` returns long before the socket is released, so a listener coming
    /// up in that window finds its own port still taken. On an idle machine the
    /// window is a few hundred microseconds and the test above sails through it;
    /// held open deliberately, it is the failure an operator meets on a machine
    /// that is busy recording — a rebind reported as "address in use" and a
    /// switch that turned itself off.
    @Test func aListenerWaitsOutThePortItIsAboutToInherit() async throws {
        let sitting = RemoteFailureBox()
        let first = RemoteServer(pin: "0000", page: Data(),
                                 handlers: sitting.handlers())
        first.start(port: 0)
        let up = await ControllerWait.until { sitting.boundPort > 0 }
        try #require(up, "the first listener never reached ready")
        let port = sitting.boundPort

        let arriving = RemoteFailureBox()
        let second = RemoteServer(pin: "0000", page: Data(),
                                  handlers: arriving.handlers())
        defer { second.stop() }
        second.start(port: port)
        // Long enough that the first bind has certainly been refused, short
        // enough to land inside the retry window.
        try await Task.sleep(for: .milliseconds(50))
        first.stop()

        let inherited = await ControllerWait.until({ arriving.boundPort == port },
                                                   timeout: .seconds(5))
        #expect(inherited, """
            the port was not waited out: \
            \(arriving.message ?? "no failure reported")
            """)
    }

    /// Another process (or a second copy of TakeShot) already has the port. The
    /// operator has to be told; the app must not crash and must not leave a
    /// switch on over a server that is not listening.
    @Test func aBusyPortIsReportedAndTheSwitchGoesBack() async throws {
        try await ControllerHarness.run { controller, _ in
            let (port, _) = try await RemoteHarness.serve(controller)

            let reported = RemoteFailureBox()
            let second = RemoteServer(pin: "0000", page: Data(),
                                      handlers: reported.handlers())
            second.start(port: UInt16(port))
            defer { second.stop() }

            let failed = await ControllerWait.until({ reported.message != nil },
                                                    timeout: .seconds(10))
            #expect(failed,
                    "a second listener on the same port neither failed nor was refused")
            #expect(reported.readyCount == 0,
                    "two listeners bound the same port at once")
        }
    }

    /// The controller's own reaction to that failure, without needing a busy
    /// port: the toast, the switch and the dropped server.
    @Test func aFailureTurnsTheRemoteBackOff() async throws {
        try await ControllerHarness.run { controller, _ in
            _ = try await RemoteHarness.serve(controller)
            controller.settings.remote.enabled = true

            controller.remoteFailed("Address already in use")

            #expect(controller.remoteServer == nil)
            #expect(controller.settings.remote.enabled != true)
            #expect(controller.lastError?.contains("Address already in use") == true)
        }
    }

    /// The switch is off out of the box: nothing binds a port on the set
    /// network until an operator asks for it.
    @Test func theRemoteIsOffUntilItIsSwitchedOn() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.settings.remote.enabled == nil)
            #expect(controller.remoteServer == nil)
            #expect(controller.remoteBoundPort == 0)
            #expect(controller.settings.remote.pin == nil)
            // The default port is stated once, in the model.
            #expect(controller.settings.remote.portEffective == 8765)
        }
    }

    @Test func thePINIsGeneratedOnceAndKept() async throws {
        try await ControllerHarness.run { controller, _ in
            let first = controller.ensureRemotePIN()
            #expect(first.count == 4)
            #expect(controller.ensureRemotePIN() == first,
                    "the PIN changed under a client that was already using it")

            controller.regenerateRemotePIN()
            #expect(controller.settings.remote.pin != first)
            #expect(controller.settings.remote.pin?.count == 4)
        }
    }

    /// The status is a snapshot of what the operator sees, not a second source
    /// of truth: the take name is the one the collision warning is about.
    @Test func theStatusMirrorsTheControllersOwnState() async throws {
        try await ControllerHarness.run { controller, root in
            try RemoteHarness.seedTake(controller, in: root, named: "A001C11",
                                       clip: 11, rating: .bad)
            controller.live.currentTimecode = Timecode(
                hours: 10, minutes: 11, seconds: 12, frames: 13, fps: 25)

            let status = controller.remoteStatus()
            #expect(status.timecode == "10:11:12:13")
            #expect(status.takeName == "A001C11")
            #expect(status.rating == "bad")
            #expect(!status.recording)
            #expect(!status.capturing)
        }
    }

    /// The page calls the socket dead when nothing has arrived for a while, which
    /// is the only way it can tell a network that vanished from a still frame —
    /// mobile Safari reports neither. That deadline has to outlast the heartbeat
    /// it is watching for, with room for a missed one, or the page reconnects
    /// through a shoot on a socket that was fine.
    @Test func thePageOutwaitsTwoHeartbeats() {
        let beat = CaptureController.remoteTick
            * CaptureController.remoteHeartbeatTicks
        let watchdog = Duration.milliseconds(RemotePage.watchdogMilliseconds)
        #expect(watchdog > beat * 2,
                "the page gives up inside two heartbeats: \(watchdog) vs \(beat)")
    }

    /// And the page is told what that deadline is, rather than carrying its own
    /// copy of it.
    @Test func thePageIsGivenItsWatchdog() throws {
        let html = try #require(String(bytes: RemotePage.html(), encoding: .utf8))
        #expect(html.contains("watchdogMs:\(RemotePage.watchdogMilliseconds)"))
        #expect(html.contains("CFG.watchdogMs"),
                "the page was handed a watchdog it does not read")
    }

    /// **A rotated PIN cuts the sockets that were holding the old one.**
    ///
    /// Rotation is what an operator reaches for when a unit walked off set with
    /// the code in it. The old shape only refused that unit's next COMMAND —
    /// and the pages that matter most here send none: the slate and the live
    /// view open a socket, show their code once and then only ever receive.
    /// A phone parked on the slate kept the timecode, the take name and the
    /// frames arriving indefinitely after the code it used had been retired,
    /// which is the one thing rotating a code is meant to stop.
    @Test func rotatingThePINDropsTheSocketsHoldingTheOldOne() async throws {
        try await ControllerHarness.run { controller, _ in
            let (port, pin) = try await RemoteHarness.serve(controller)
            let session = RemoteHarness.session()
            let client = try await RemoteHarness.connect(port: port, pin: pin,
                                                         session: session)
            defer { client.close() }
            _ = try await client.next(type: "auth")
            let seated = await ControllerWait.until {
                controller.remoteServer?.clientCount == 1
            }
            #expect(seated, "the socket never seated")

            controller.regenerateRemotePIN()

            let dropped = await ControllerWait.until {
                controller.remoteServer?.clientCount == 0
            }
            #expect(dropped, """
                a socket holding the retired PIN is still connected — a phone \
                parked on the slate keeps receiving
                """)
        }
    }

    /// And the rotation does not take the listener with it: the operator reads
    /// the new code out and the same unit comes straight back in on it.
    @Test func theNewPINWorksOnTheSameListener() async throws {
        try await ControllerHarness.run { controller, _ in
            let (port, pin) = try await RemoteHarness.serve(controller)
            let session = RemoteHarness.session()
            let first = try await RemoteHarness.connect(port: port, pin: pin,
                                                        session: session)
            _ = try await first.next(type: "auth")
            controller.regenerateRemotePIN()
            first.close()

            let fresh = try #require(controller.settings.remote.pin)
            #expect(fresh != pin)
            let again = try await RemoteHarness.measureAuth(port: port, pin: fresh)
            #expect(again.ok, "the new code was refused on the same listener")
            let stale = try await RemoteHarness.measureAuth(port: port, pin: pin)
            #expect(!stale.ok, "the retired code still opens the door")
        }
    }

    /// **A failure from a server that was already replaced is not news about
    /// the running one.** A port change stops one server and starts another;
    /// the old one's listener reports its failure on its own queue a hop later,
    /// and that hop used to tear down the REPLACEMENT and flip the switch off.
    @Test func aStaleFailureDoesNotTearDownTheReplacement() async throws {
        try await ControllerHarness.run { controller, _ in
            _ = try await RemoteHarness.serve(controller)
            controller.settings.remote.enabled = true
            let stale = controller.remoteGeneration

            // the port changes: one server goes, another comes
            controller.stopRemoteServer()
            controller.startRemoteServer(overridePort: 0)
            #expect(await ControllerWait.until { controller.remoteBoundPort > 0 })
            #expect(controller.remoteGeneration != stale)

            // …and the OLD one's failure arrives late
            controller.remoteFailed("address in use", generation: stale)
            #expect(controller.remoteServer != nil, """
                a failure from a server that had already been replaced tore \
                down the one that replaced it
                """)
            #expect(controller.settings.remote.enabled == true,
                    "the stale failure flipped the remote switch off")

            // …while the CURRENT server's failure still does what it should
            controller.remoteFailed("address in use", generation: controller.remoteGeneration)
            #expect(controller.remoteServer == nil)
            #expect(controller.settings.remote.enabled == false)
        }
    }
}
