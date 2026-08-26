import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// The chroma key asked INTO the recording, from the controller's side:
/// `chromaRecordOn`, its gate, and what a relaunch does to it.
///
/// Its own file rather than three more tests in `ControllerChromaKeyTests`,
/// which is at the project's type-body ceiling — and the split reads right
/// anyway: everything there is about dialling a PREVIEW in, and everything here
/// is about a switch that changes what a take is.
@Suite @MainActor struct ControllerChromaBakeTests {
    /// **Start from the defaults and require the door.** The bake's gate is
    /// `canBakeChromaKey`, and the whole failure this test exists for is a gate
    /// only the thing behind it could open: so this begins at a fresh install,
    /// asks the gate (shut), opens it the one way the panel offers — the key's
    /// own toggle, right above it — and requires the switch to take.
    ///
    /// Asserted as the rule rather than as a rendered control, for the reason
    /// `canApplyLUT` is: `.disabled(…)` is not something a headless render can be
    /// asked about, and a suite of size measurements cannot see a door that is
    /// not there.
    @Test func theBakeIsReachableFromAFreshInstall() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.settings.chromaKey == ChromaKeySettings(),
                    "the harness pre-configured the key — this proves nothing")
            #expect(!controller.chromaKeyOn, "the key is on before anyone asked")
            #expect(!controller.chromaRecordOn, "the bake is armed at install")
            #expect(!controller.canBakeChromaKey,
                    "the bake is offered over no key at all")

            // the way in: the key's own switch, and nothing else is required —
            // no plate, no eyedropper, no LUT, no signal
            controller.chromaKeyOn = true
            #expect(controller.canBakeChromaKey,
                    "switching the key on left the bake behind a shut gate")
            controller.chromaRecordOn = true
            #expect(controller.chromaRecordOn, "the bake switch did not take")
            #expect(controller.chroma.record,
                    "the surfaces disagree about what the key is doing")
        }
    }

    /// Switching the KEY off takes the bake with it: a bake armed over no key
    /// describes a take nobody can produce, and it would come back armed the
    /// moment the key was switched on again.
    @Test func switchingTheKeyOffDisarmsTheBake() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.chromaKeyOn = true
            controller.chromaRecordOn = true
            #expect(controller.chromaRecordOn)

            controller.chromaKeyOn = false
            #expect(!controller.chromaRecordOn,
                    "the bake stayed armed over a key that is off")
            #expect(!controller.canBakeChromaKey)
        }
    }

    /// Neither the key nor the bake is stored, and the bake for the stronger
    /// reason: a flag that survives a relaunch would bake a display decision
    /// into the first take of the next shooting day, which is the one thing here
    /// nobody would catch on set.
    @Test func theBakeIsNeverPersisted() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.chromaKeyOn = true
            controller.chromaRecordOn = true
            controller.chromaTolerance = 0.42
            controller.commitAssistDraft() // the sliders are debounced

            // the dial-in went in…
            #expect(controller.settings.chromaKey.tolerance == 0.42)
            // …and neither switch has a key in the format to be stored under
            let json: Data = try JSONEncoder().encode(controller.settings)
            let text = try #require(String(bytes: json, encoding: .utf8))
            #expect(!text.contains("chromaKeyRecord"),
                    "the bake reached the stored settings blob")

            // and what comes back out of a real reload has both switches off
            let reloaded: CaptureSettings = CaptureSettings.loaded(from: probe.store)
            controller.restoreChroma(from: reloaded.chromaKey)
            #expect(!controller.chromaKeyOn)
            #expect(!controller.chromaRecordOn)
            #expect(controller.chroma.tolerance == 0.42,
                    "the dial-in was lost with the switches")
        }
    }
}
