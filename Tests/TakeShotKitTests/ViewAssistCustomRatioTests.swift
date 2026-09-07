import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// A frameline aspect and a squeeze factor the pickers do not list.
///
/// The typed value has to reach the picture AND has to be visible in the
/// control that is set to it: a `Picker` whose selection matches none of its
/// rows shows nothing at all, so an operator who typed 2.76 would be looking
/// at a blank framelines control with a 2.76 frameline on the picture.
@Suite @MainActor struct ViewAssistCustomRatioTests {
    /// A preset is not a custom value, and 4:3 typed by hand is the preset —
    /// it is 1.3333333333333333 either way, and a second row a ten-thousandth
    /// off it would be two rows for one aspect.
    @Test func aTypedPresetIsStillThePreset() throws {
        #expect(AssistPresets.custom(2.39, among: AssistPresets.frameline) == nil)
        let typed = try #require(
            AssistRatioInput.parse("4:3", in: AssistRatioInput.framelineRange))
        #expect(AssistPresets.custom(typed, among: AssistPresets.frameline) == nil)
        #expect(AssistPresets.custom(1.0, among: AssistPresets.desqueeze) == nil)
    }

    /// …and an aspect nobody listed gets its own row, so the picker can show it.
    @Test func anAspectNoPresetCoversGetsItsOwnRow() {
        #expect(AssistPresets.custom(2.76, among: AssistPresets.frameline) == 2.76)
        #expect(AssistPresets.custom(1.25, among: AssistPresets.desqueeze) == 1.25)
    }

    /// Off is not a custom value — the framelines picker already has an Off row
    /// and a second one tagged 0 would be two ways to spell the same nothing.
    @Test func offIsNotACustomRow() {
        #expect(AssistPresets.custom(nil, among: AssistPresets.frameline) == nil)
        #expect(AssistPresets.custom(0, among: AssistPresets.frameline) == nil)
    }

    /// The box is empty when the control is off, rather than showing a number
    /// that is not being drawn.
    @Test func theBoxIsEmptyWhileTheControlIsOff() {
        #expect(AssistCustomField.text(for: nil) == "")
        #expect(AssistCustomField.text(for: 0) == "")
        #expect(AssistCustomField.text(for: 2.76) == "2.76")
    }

    /// **A refusal snaps the box back.** A field that keeps a rejected "0" on
    /// screen looks accepted, and the operator walks away believing the
    /// frameline is set to something the app quietly ignored.
    @Test func aRefusedNumberChangesNothingAndTheBoxSaysSo() {
        let outcome = AssistCustomField.committed(
            text: "0", current: 2.39, in: AssistRatioInput.framelineRange)

        #expect(outcome.value == nil, "a zero was applied to the frameline")
        #expect(outcome.text == "2.39", "the box kept a number nothing is drawn at")
    }

    /// …and the empty box comes back empty when the control is off, rather
    /// than filling itself in with a value nobody set.
    @Test func aRefusedNumberOnAControlThatIsOffLeavesItEmpty() {
        let outcome = AssistCustomField.committed(
            text: "nonsense", current: nil, in: AssistRatioInput.framelineRange)

        #expect(outcome.value == nil)
        #expect(outcome.text == "")
    }

    /// An accepted value is rewritten from the NUMBER, not left as typed — so
    /// the box and the picker cannot spell one value two ways.
    @Test func anAcceptedNumberSettlesIntoOneSpelling() throws {
        let outcome = AssistCustomField.committed(
            text: " 2,39 ", current: nil, in: AssistRatioInput.framelineRange)

        #expect(outcome.value == 2.39)
        #expect(outcome.text == "2.39")

        let fraction = AssistCustomField.committed(
            text: "16/9", current: nil, in: AssistRatioInput.framelineRange)
        let value = try #require(fraction.value)
        #expect(abs(value - 16.0 / 9.0) < 0.000001)
        #expect(fraction.text == AssistRatioInput.text(value))
    }

    /// End to end through the controller: a typed aspect is what the renderer
    /// draws, and it is what the next launch comes back to.
    @Test func aTypedFramelineIsDrawnAndRemembered() async throws {
        try await ControllerHarness.run { controller, _ in
            let typed = try #require(
                AssistRatioInput.parse("2.76", in: AssistRatioInput.framelineRange))
            controller.settings.assist.framelineRatio = typed

            #expect(controller.liveAssist.guides.ratio == 2.76,
                    "the typed frameline never reached the renderer")
            #expect(CaptureSettings.loaded(from: controller.defaults)
                        .assist.framelineRatio == 2.76,
                    "the typed frameline will not survive a relaunch")
        }
    }

    /// **Both controls carry both halves.** Asserted on the source: a popover
    /// never renders while its trigger is measured, so the rows themselves are
    /// out of reach of a headless render — and a picker that lost its custom
    /// tag fails silently, by showing an empty control rather than by throwing.
    @Test func bothPickersOfferATypedValueAndShowIt() throws {
        let code = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TakeShotKit/AssistMenu.swift"),
            encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        // one box each, and one custom row each
        #expect(code.components(separatedBy: "AssistCustomField(").count == 3,
                "a control lost the box a value is typed into")
        #expect(code.components(separatedBy: "AssistPresets.custom(").count == 3,
                "a picker lost the row its typed value is shown on")
        #expect(code.contains("range: AssistRatioInput.framelineRange"))
        #expect(code.contains("range: AssistRatioInput.desqueezeRange"))
    }

    /// Same for the squeeze factor, which takes the other route into the
    /// picture (`setAssist`, not a settings write).
    @Test func aTypedDesqueezeIsAppliedAndRemembered() async throws {
        try await ControllerHarness.run { controller, _ in
            let typed = try #require(
                AssistRatioInput.parse("1.25x", in: AssistRatioInput.desqueezeRange))
            controller.setAssist { $0.desqueeze = typed }

            #expect(controller.liveAssist.desqueeze == 1.25)
            #expect(CaptureSettings.loaded(from: controller.defaults)
                        .assist.desqueezeFactor == 1.25,
                    "the typed squeeze factor will not survive a relaunch")
        }
    }
}
