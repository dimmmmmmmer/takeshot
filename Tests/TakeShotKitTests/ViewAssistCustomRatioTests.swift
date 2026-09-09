import CaptureCore
import Foundation
import SwiftUI
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
        #expect(AssistPresets.custom(2.39, among: AssistPresets.frameline,
                                       off: AssistPresets.framelineOff) == nil)
        let typed = try #require(
            AssistRatioInput.parse("4:3", in: AssistRatioInput.framelineRange))
        #expect(AssistPresets.custom(typed, among: AssistPresets.frameline,
                                       off: AssistPresets.framelineOff) == nil)
        #expect(AssistPresets.custom(1.0, among: AssistPresets.desqueeze,
                                       off: AssistPresets.desqueezeOff) == nil)
    }

    /// …and an aspect nobody listed gets its own row, so the picker can show it.
    @Test func anAspectNoPresetCoversGetsItsOwnRow() {
        #expect(AssistPresets.custom(2.76, among: AssistPresets.frameline,
                                       off: AssistPresets.framelineOff) == 2.76)
        #expect(AssistPresets.custom(1.25, among: AssistPresets.desqueeze,
                                       off: AssistPresets.desqueezeOff) == 1.25)
    }

    /// Off is not a custom value — the framelines picker already has an Off row
    /// and a second one tagged 0 would be two ways to spell the same nothing.
    @Test func offIsNotACustomRow() {
        #expect(AssistPresets.custom(nil, among: AssistPresets.frameline,
                                       off: AssistPresets.framelineOff) == nil)
        #expect(AssistPresets.custom(0, among: AssistPresets.frameline,
                                       off: AssistPresets.framelineOff) == nil)
    }

    /// The box is empty when the control is off, rather than showing a number
    /// that is not being drawn.
    @Test func theBoxIsEmptyWhileTheControlIsOff() {
        #expect(AssistCustomField.text(for: nil) == "")
        #expect(AssistCustomField.text(for: 0) == "")
        #expect(AssistCustomField.text(for: 2.76) == "2.76")
    }

    /// **A value nobody typed is not committed.** The box commits on the way
    /// out as well as on Return, and "the way out" includes clicking the
    /// picker: type 2.76, press Return, then choose Off, and the blur that the
    /// click causes wrote 2.76 straight back over the Off — so neither aid
    /// could be switched off at all once anything had been typed into its box
    /// (owner: "если в кастоме вписано значение – фреймлайнсы и десквиз не
    /// выключается").
    @Test func choosingOffIsNotUndoneByTheBoxOnItsWayOut() {
        // the state right after a commit: the box and the control agree
        let outcome = AssistCustomField.committed(
            text: "2.76", written: "2.76", current: nil,
            in: AssistRatioInput.framelineRange)

        #expect(outcome.value == nil, "the box re-applied a value nobody typed")
        #expect(outcome.text == "2.76")
    }

    /// …and a value the operator DID type still lands.
    @Test func aValueTypedOverThePickersOwnIsCommitted() {
        let outcome = AssistCustomField.committed(
            text: "2.76", written: "1.85", current: 1.85,
            in: AssistRatioInput.framelineRange)

        #expect(outcome.value == 2.76)
        #expect(outcome.text == "2.76")
    }

    /// **Both aids have an Off, and it carries the value that means it.** A
    /// desqueeze is off at a factor of one, and the picker said "1x" — a
    /// number rather than a state, which read as the control having no way to
    /// turn it off (owner: "у десквиза нет теперь опции off").
    @Test func bothAidsHaveAnOffRowCarryingTheValueThatMeansIt() {
        #expect(AssistPresets.desqueezeOff == 1)
        #expect(AssistPresets.framelineOff == 0)
        // …and the off value never doubles as a custom row: a typed "1" on the
        // desqueeze IS the Off row, not a second entry saying the same thing
        #expect(AssistPresets.custom(1, among: AssistPresets.desqueeze,
                                     off: AssistPresets.desqueezeOff) == nil)
        #expect(!AssistPresets.desqueeze.contains { $0.value == 1 },
                "the preset list still carries the off value as a preset too")
    }

    /// **A refusal snaps the box back.** A field that keeps a rejected "0" on
    /// screen looks accepted, and the operator walks away believing the
    /// frameline is set to something the app quietly ignored.
    @Test func aRefusedNumberChangesNothingAndTheBoxSaysSo() {
        let outcome = AssistCustomField.committed(
            text: "0", written: "2.39", current: 2.39, in: AssistRatioInput.framelineRange)

        #expect(outcome.value == nil, "a zero was applied to the frameline")
        #expect(outcome.text == "2.39", "the box kept a number nothing is drawn at")
    }

    /// …and the empty box comes back empty when the control is off, rather
    /// than filling itself in with a value nobody set.
    @Test func aRefusedNumberOnAControlThatIsOffLeavesItEmpty() {
        let outcome = AssistCustomField.committed(
            text: "nonsense", written: "", current: nil, in: AssistRatioInput.framelineRange)

        #expect(outcome.value == nil)
        #expect(outcome.text == "")
    }

    /// An accepted value is rewritten from the NUMBER, not left as typed — so
    /// the box and the picker cannot spell one value two ways.
    @Test func anAcceptedNumberSettlesIntoOneSpelling() throws {
        let outcome = AssistCustomField.committed(
            text: " 2,39 ", written: "", current: nil, in: AssistRatioInput.framelineRange)

        #expect(outcome.value == 2.39)
        #expect(outcome.text == "2.39")

        let fraction = AssistCustomField.committed(
            text: "16/9", written: "", current: nil, in: AssistRatioInput.framelineRange)
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

    /// **Both controls are the same control.** Asserted on the source: a
    /// popover never renders while its trigger is measured, so the rows
    /// themselves are out of reach of a headless render — and a picker that
    /// lost its Custom row fails silently, by simply not offering it.
    @Test func bothAidsMountTheSameRatioRow() throws {
        let code = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TakeShotKit/AssistMenu.swift"),
            encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.components(separatedBy: "AssistRatioRow(").count == 3,
                "an aid stopped mounting the shared ratio row")
        // …and neither builds a picker or a box of its own beside it, which is
        // how the two came to disagree about Off the last time.
        #expect(!code.contains("AssistCustomField("),
                "an aid mounts a typed box outside the shared row")
        #expect(!code.contains("AssistPresets.custom("),
                "an aid decides what counts as a typed value for itself")
        #expect(code.contains("range: AssistRatioInput.framelineRange"))
        #expect(code.contains("range: AssistRatioInput.desqueezeRange"))
    }

    /// **The box appears with the Custom row and not before it.**
    ///
    /// It used to be under every picker whenever the aid was on — a field
    /// showing a number the picker was already showing, and the only way in to
    /// typing (owner: "поле для нее есть но оно всегда видно – стоит просто
    /// пунктом сделать кастом и чтоб тогда поле для него появлялось").
    @Test func theTypedBoxIsBehindTheCustomRow() {
        // a preset: the picker says it, and there is no box
        #expect(!AssistRatioRow.showsBox(
            chosen: false, value: 1.85, among: AssistPresets.frameline,
            off: AssistPresets.framelineOff))
        #expect(!AssistRatioRow.showsBox(
            chosen: false, value: 2.0, among: AssistPresets.desqueeze,
            off: AssistPresets.desqueezeOff))
        // choosing the row opens it over a value that has not changed yet —
        // without this the box could never be reached from a preset at all
        #expect(AssistRatioRow.showsBox(
            chosen: true, value: 1.85, among: AssistPresets.frameline,
            off: AssistPresets.framelineOff))
        // …and a typed value opens it with nothing chosen, which is the state
        // a relaunch restores: 2.76 is on no row of its own any more, so the
        // control has to know it is Custom from the NUMBER.
        #expect(AssistRatioRow.showsBox(
            chosen: false, value: 2.76, among: AssistPresets.frameline,
            off: AssistPresets.framelineOff))
        #expect(AssistRatioRow.showsBox(
            chosen: false, value: 1.25, among: AssistPresets.desqueeze,
            off: AssistPresets.desqueezeOff))
        // off is not custom: a desqueeze of exactly 1 is a spherical lens
        #expect(!AssistRatioRow.showsBox(
            chosen: false, value: 1.0, among: AssistPresets.desqueeze,
            off: AssistPresets.desqueezeOff))
    }

    /// And the box really is what the row grows by, measured: the Custom state
    /// is taller than the preset state by a field.
    @Test func theCustomStateIsTallerByABox() async throws {
        try await ViewProbe.run { probe in
            @MainActor func height(_ value: Double) -> CGFloat {
                probe.fittingSize(VStack {
                    AssistRatioRow(presets: AssistPresets.frameline,
                                   off: AssistPresets.framelineOff,
                                   range: AssistRatioInput.framelineRange,
                                   value: value) { _ in }
                }).height
            }
            let preset = height(1.85)
            let typed = height(2.76)
            #expect(typed > preset + 8,
                    "preset \(preset)pt, typed \(typed)pt — the box did not appear")
        }
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
