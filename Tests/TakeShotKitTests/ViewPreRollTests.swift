import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// The pre-roll rows inside the Settings form's FIXED width, in both units and
/// both languages.
///
/// Measured rather than eyeballed for the reason the rest of the settings
/// suites are: a grouped Form truncates a label that does not fit instead of
/// wrapping it, so a Russian "Читается как" beside a readout that is one
/// character too long is a silent failure. And the seconds field is a row no
/// other test can reach — the default unit is frames, so the whole-form test
/// never renders it.
@MainActor
struct ViewPreRollTests {
    @Test func bothUnitsFitTheSettingsForm() async throws {
        try await ViewProbe.run { probe in
            let form = ViewBudget.settingsFormWidth
            for unit: PreRollUnit in [.frames, .seconds] {
                probe.controller.preRollUnit = unit
                let minimum = probe.minimumWidths { PreRollRows() }
                #expect(minimum.ru <= form,
                        "\(unit.rawValue) wants \(minimum.ru)pt of \(form) in Russian")
                #expect(minimum.en <= form,
                        "\(unit.rawValue) wants \(minimum.en)pt of \(form) in English")
            }
        }
    }

    /// The readout is the row that changes shape with the value — a long rate
    /// and two numbers — and it is the one that has to keep fitting.
    @Test func theReadoutFitsAtItsWidestValue() async throws {
        try await ViewProbe.run { probe in
            probe.controller.signalFormat = CaptureFormat(
                width: 3840, height: 2160, frameRate: 23.976, timecodeFPS: 24,
                name: "2160p23.98")
            probe.controller.preRollFrames =
                CaptureSignalSettings.preRollFrameRange.upperBound
            let minimum = probe.minimumWidths { PreRollRows() }
            #expect(minimum.ru <= ViewBudget.settingsFormWidth,
                    "the readout wants \(minimum.ru)pt in Russian")
            #expect(minimum.en <= ViewBudget.settingsFormWidth,
                    "the readout wants \(minimum.en)pt in English")
        }
    }

    /// Switching the unit must not change the height of the settings form by
    /// more than the one row that swaps — a unit picker that reflowed the whole
    /// pane would be a worse affordance than no picker at all.
    @Test func theUnitSwitchSwapsOneRowAndNotTheLayout() async throws {
        try await ViewProbe.run { probe in
            probe.controller.preRollUnit = .frames
            let frames = probe.fittingSizes { PreRollRows() }
            probe.controller.preRollUnit = .seconds
            let seconds = probe.fittingSizes { PreRollRows() }
            #expect(abs(frames.en.height - seconds.en.height) < 8,
                    "the rows changed height with the unit: \(frames) vs \(seconds)")
            #expect(abs(frames.ru.height - seconds.ru.height) < 8,
                    "the Russian rows changed height with the unit")
        }
    }
}
