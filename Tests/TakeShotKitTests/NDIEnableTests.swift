import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **Using NDI and announcing a source are two switches.**
///
/// They used to be one: `settings.ndi.enabled` both meant "this cart streams
/// over NDI" and created the sender, so the Settings checkbox was a transmit
/// button (owner: "кнопка включения/выключения не запускала стримы а включала
/// возможность"). Split out of `NDILifecycleTests` when that file reached the
/// length ceiling, which is also the honest division: those tests are about
/// the sender's life, these are about which switch owns it.
@Suite @MainActor struct NDIEnableTests {
    /// **The run switch announces the source; the enable switch does not.**
    ///
    /// This used to be "a shoot that left the switch on gets its source back
    /// after a relaunch", on the web remote's terms. Enabling a transport now
    /// means the cart uses NDI — the badge, this settings section — and
    /// `setNDIRunning` is what puts a source on the network (owner: "кнопка
    /// включения/выключения не запускала стримы а включала возможность").
    @Test func theRunSwitchAnnouncesTheSource() async throws {
        try await NDIProbe.run { controller, log in
            controller.settings.naming.projectName = "Dune"
            controller.settings.naming.cameraLabel = "C"
            controller.mirrors.ndiState = .off
            controller.settings.ndi.enabled = true
            // Enabling the transport announced nothing by itself — no sender
            // was ever built, which is the whole change.
            #expect(log.all.isEmpty, "enabling the transport announced a source")
            #expect(controller.mirrors.ndiState == NDIOutputState.off)

            controller.setNDIRunning(true)
            #expect(log.names == ["Dune C"],
                    "the run switch did not announce: \(log.names)")
            // ANNOUNCED, not sending: the source is on the network and nobody
            // has opened it. "Sending" one line after `send_create` was the
            // switch wearing the link's clothes — see
            // `NDIOutputState.announced`.
            #expect(controller.mirrors.ndiState == NDIOutputState.announced)

            // …and off again takes it down.
            controller.setNDIRunning(false)
            #expect(controller.mirrors.ndiState == NDIOutputState.off)
        }
    }

    /// A transport the cart does not use cannot be started at all: the two
    /// switches mean different things and one must not quietly set the other.
    @Test func theRunSwitchRefusesATransportThatIsNotEnabled() async throws {
        try await NDIProbe.run { controller, log in
            controller.settings.ndi.enabled = nil
            controller.setNDIRunning(true)
            #expect(!controller.mirrors.ndiRunning)
            #expect(log.names.isEmpty, "an unused transport announced a source")
            #expect(controller.settings.ndi.enabled == nil,
                    "starting the stream switched the transport on by itself")
        }
    }

    /// …and un-enabling the transport takes a running source down with it: you
    /// cannot be streaming over a transport the cart does not use.
    @Test func droppingTheTransportStopsALiveSource() async throws {
        try await NDIProbe.run { controller, _ in
            controller.settings.ndi.enabled = true
            controller.setNDIRunning(true)
            #expect(controller.mirrors.ndiState == NDIOutputState.announced)
            controller.settings.ndi.enabled = nil
            #expect(!controller.mirrors.ndiRunning)
            #expect(controller.mirrors.ndiState == NDIOutputState.off,
                    "the source outlived the transport being dropped")
        }
    }

}
