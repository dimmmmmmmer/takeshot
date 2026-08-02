import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// The dailies sheet and its panel strip, rendered headless in both languages.
///
/// The sheet is a fixed 470pt wide, which is exactly why it needs measuring
/// (the offload suite's reasoning): a Russian toggle label that cannot
/// compress does not throw — it silently pushes the content wider than the
/// frame that clips it. Every state has different text, so all three render:
/// idle, running (with the paused badge, the longest line), and finished with
/// a failure.
@Suite @MainActor struct ViewDailiesTests {
    /// What the sheet's own 20pt padding leaves for the content.
    static let inner = DailiesSheet.width - 40

    private func seed(_ model: DailiesQueueModel, controller: CaptureController,
                      root: URL) {
        let takes = ["A001C01", "A001C02"].map {
            ControllerFixtures.take(named: $0, in: root)
        }
        model.prepare(takes: takes, settings: controller.settings,
                      defaultFolder: root.appendingPathComponent("Dailies"))
        model.customText = "FOR REVIEW"
    }

    @Test func theIdleSheetFitsItsOwnFixedWidthInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            self.seed(probe.controller.dailies, controller: probe.controller,
                      root: probe.root)
            let ideal = probe.fittingSizes {
                DailiesSheet(model: probe.controller.dailies)
            }
            let minimum = probe.minimumWidths {
                DailiesSheet(model: probe.controller.dailies).content
            }

            #expect(ideal.en.width == DailiesSheet.width)
            #expect(ideal.ru.width == DailiesSheet.width)
            #expect(minimum.en <= Self.inner,
                    "the idle sheet needs \(minimum.en)pt of \(Self.inner)")
            #expect(minimum.ru <= Self.inner,
                    "the idle sheet needs \(minimum.ru)pt of \(Self.inner)")
        }
    }

    /// Mid-run with the recording pause engaged — the progress row carries
    /// its longest text (item counter + paused badge + Skip button), and the
    /// result panel below it names a failed take with a long reason.
    @Test func theRunningAndFinishedStatesFitInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let model = probe.controller.dailies
            self.seed(model, controller: probe.controller, root: probe.root)
            model.progress = DailiesProgress(
                itemIndex: 0, itemCount: 14,
                currentFile: "A001C042_260802_R1AB.mov",
                framesDone: 512, framesTotal: 1500,
                isPaused: true, isCancelling: false)
            model.report = DailiesReport(
                items: [
                    DailiesItemResult(
                        source: probe.root.appendingPathComponent("A001C01.mov"),
                        output: probe.root.appendingPathComponent(
                            "Dailies/A001C01_DAILY.mp4")),
                    DailiesItemResult(
                        source: probe.root.appendingPathComponent("A001C02.mov"),
                        failure: "The volume \u{201C}DAILIES_SSD\u{201D} is out"
                            + " of space."),
                ],
                wasCancelled: true)

            let minimum = probe.minimumWidths {
                DailiesSheet(model: model).content
            }
            #expect(minimum.en <= Self.inner,
                    "the busy sheet needs \(minimum.en)pt of \(Self.inner)")
            #expect(minimum.ru <= Self.inner,
                    "the busy sheet needs \(minimum.ru)pt of \(Self.inner)")
        }
    }

    /// The strip lives in the 310pt takes panel; its three lines truncate
    /// rather than widen it (the offload strip's contract).
    @Test func theStatusStripSqueezesIntoThePanelWidth() async throws {
        try await ViewProbe.run { probe in
            let model = probe.controller.dailies
            model.progress = DailiesProgress(
                itemIndex: 3, itemCount: 14,
                currentFile: "A001C042_260802_R1AB.mov",
                framesDone: 512, framesTotal: 1500,
                isPaused: true, isCancelling: false)

            let minimum = probe.minimumWidths {
                DailiesStatusStrip(status: L("dailies_status", 4, 14),
                                   dailies: model)
            }
            // the panel is 310pt minimum with 12pt of strip padding each side
            #expect(minimum.en <= 286,
                    "the strip needs \(minimum.en)pt of 286")
            #expect(minimum.ru <= 286,
                    "the strip needs \(minimum.ru)pt of 286")
        }
    }
}
