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

/// **The sheet has no scroll view, so its height is now a rule.**
///
/// It used to be `ScrollView { … }`, and a scroll view answers whatever
/// proposal it is given — so nothing could be measured and nothing was: the
/// sheet quietly grew past the window and put a scrollbar on content the owner
/// could see fit ("почему-то это окошко скролл еще выдает"). Measured instead,
/// the three states were 558, 660 and 841pt against a 560pt budget.
///
/// The footer is measured on its own because that is how the sheet is built —
/// `DailiesSheetFooter` takes its dismissal in precisely so a test can host it
/// — plus the divider and the 14pt above and below it.
@Suite @MainActor struct ViewDailiesHeightTests {
    /// Divider plus the footer's own vertical padding, from `DailiesSheet`.
    static let footerChrome: CGFloat = 29

    private func seed(_ model: DailiesQueueModel, controller: CaptureController,
                      root: URL) {
        model.prepare(takes: ["A001C01", "A001C02"].map {
            ControllerFixtures.take(named: $0, in: root)
        }, settings: controller.settings,
           defaultFolder: root.appendingPathComponent("Dailies"))
        model.customText = "FOR REVIEW"
        model.burnCustom = true
    }

    /// The worst report this sheet can be handed: every take in a long batch
    /// failed, each with a sentence for a reason.
    private func worstReport(root: URL) -> DailiesReport {
        DailiesReport(items: (1...14).map { index in
            DailiesItemResult(
                source: root.appendingPathComponent("A001C\(index).mov"),
                failure: "the disk went away in the middle of the write")
        }, wasCancelled: false)
    }

    @Test func everyStateOfTheSheetFitsAWindowAtItsMinimum() async throws {
        try await ViewProbe.run { probe in
            let model = probe.controller.dailies
            self.seed(model, controller: probe.controller, root: probe.root)

            @MainActor func height() -> (en: CGFloat, ru: CGFloat) {
                let content = probe.sizes(proposedWidth: DailiesSheet.width) {
                    DailiesSheet(model: model).content.padding(DailiesSheet.margin)
                }
                let footer = probe.sizes(proposedWidth: DailiesSheet.width - 2 * DailiesSheet.margin) {
                    DailiesSheetFooter(model: model) {}
                }
                return (content.en.height + footer.en.height + Self.footerChrome,
                        content.ru.height + footer.ru.height + Self.footerChrome)
            }

            let idle = height()
            #expect(idle.en <= ViewBudget.sheetHeight,
                    "the idle sheet needs \(idle.en)pt of \(ViewBudget.sheetHeight)")
            #expect(idle.ru <= ViewBudget.sheetHeight,
                    "the idle sheet needs \(idle.ru)pt of \(ViewBudget.sheetHeight)")

            model.progress = DailiesProgress(
                itemIndex: 0, itemCount: 14,
                currentFile: "A001C042_260802_R1AB.mov",
                framesDone: 512, framesTotal: 1500, isPaused: true,
                isCancelling: false)
            let running = height()
            #expect(running.en <= ViewBudget.sheetHeight,
                    "the running sheet needs \(running.en)pt")
            #expect(running.ru <= ViewBudget.sheetHeight,
                    "the running sheet needs \(running.ru)pt")

            model.progress = nil
            model.report = self.worstReport(root: probe.root)
            let finished = height()
            #expect(finished.en <= ViewBudget.sheetHeight,
                    "the worst finished sheet needs \(finished.en)pt")
            #expect(finished.ru <= ViewBudget.sheetHeight,
                    "the worst finished sheet needs \(finished.ru)pt")

            // …and the point of the right column taking turns: the height does
            // not depend on the run at all. A stacked layout would make the
            // finished state the tallest by a wide margin.
            #expect(finished.en == idle.en,
                    "idle \(idle.en) vs finished \(finished.en)")
            #expect(running.en == idle.en,
                    "idle \(idle.en) vs running \(running.en)")
        }
    }

    /// **The sheet still fits with the appearance dials open.**
    ///
    /// A `DisclosureGroup` cannot be expanded from a render test — the state is
    /// its own — so the open height is measured as the closed sheet plus the
    /// rows it reveals. That is an approximation in one direction only: the
    /// real thing also loses the collapsed row's own height, so a pass here is
    /// a pass there.
    @Test func theSheetFitsWithTheAppearanceDialsOpen() async throws {
        try await ViewProbe.run { probe in
            let model = probe.controller.dailies
            self.seed(model, controller: probe.controller, root: probe.root)
            let content = probe.sizes(proposedWidth: DailiesSheet.width) {
                DailiesSheet(model: model).content.padding(DailiesSheet.margin)
            }
            let footer = probe.sizes(proposedWidth: DailiesSheet.width - 2 * DailiesSheet.margin) {
                DailiesSheetFooter(model: model) {}
            }
            let dials = probe.sizes(
                proposedWidth: DailiesBurninSection.columnWidth) {
                probe.hosted(DailiesInkRows(model: model))
            }
            for language in ["en", "ru"] {
                let closed = language == "en"
                    ? content.en.height + footer.en.height
                    : content.ru.height + footer.ru.height
                let open = closed + Self.footerChrome
                    + (language == "en" ? dials.en.height : dials.ru.height)
                #expect(open <= ViewBudget.sheetHeight,
                        Comment(rawValue: "\(language) open needs \(open)pt of \(ViewBudget.sheetHeight)"))
            }
        }
    }

    /// **And the burn-ins face fits the tab it is fixed inside.**
    ///
    /// `DailiesSheet.tabHeight` is a fixed frame, so a face that outgrows it
    /// does not make the sheet taller — it is CLIPPED, silently, and the
    /// bottom of the picture simply is not there. That is the failure mode the
    /// restack introduced: the switches and the preview used to be side by
    /// side, where the face's height was the larger of the two, and they are
    /// stacked now, where it is the sum.
    ///
    /// Measured the same way the sheet's own budget is — closed, plus the rows
    /// the disclosure reveals — and conservative for the same reason.
    @Test func theBurninsFaceFitsInsideTheTab() async throws {
        try await ViewProbe.run { probe in
            let model = probe.controller.dailies
            self.seed(model, controller: probe.controller, root: probe.root)
            let face = probe.sizes(proposedWidth: DailiesSheet.width - 2 * DailiesSheet.margin) {
                DailiesSheet(model: model).burninsFace(stretched: false)
            }
            let dials = probe.sizes(proposedWidth: DailiesSheet.width - 2 * DailiesSheet.margin) {
                probe.hosted(DailiesInkRows(model: model))
            }
            for (language, closed, open) in [
                ("en", face.en.height, face.en.height + dials.en.height),
                ("ru", face.ru.height, face.ru.height + dials.ru.height),
            ] {
                #expect(closed <= DailiesSheet.tabHeight, Comment(rawValue:
                    "\(language) closed face is \(closed)pt of \(DailiesSheet.tabHeight)"))
                #expect(open <= DailiesSheet.tabHeight, Comment(rawValue:
                    "\(language) open face is \(open)pt of \(DailiesSheet.tabHeight)"))
            }
        }
    }

    /// The preview is the size it says it is.
    ///
    /// It was `maxWidth: .infinity` with an aspect ratio, so inside the
    /// sheet's content width it laid out at 430×241.875 — 62pt taller than
    /// declared, fractional, and a 320px bitmap stretched over 430pt. That one
    /// number is where the scrollbar came from.
    @Test func thePreviewKeepsTheSizeItDeclares() async throws {
        try await ViewProbe.run { probe in
            let model = probe.controller.dailies
            self.seed(model, controller: probe.controller, root: probe.root)
            // Through `hosted`: the preview reads the controller from the
            // environment now (it looks for a decoded thumbnail to lay the
            // strips over), and a missing `@EnvironmentObject` does not
            // degrade — it traps, and a trap takes the whole run down.
            let size = probe.sizes(proposedWidth: 900) {
                probe.hosted(DailiesBurninPreview(model: model).picture)
            }
            #expect(size.en == DailiesBurninPreview.size,
                    "the preview took \(size.en) of \(DailiesBurninPreview.size)")
        }
    }

    /// The 2x raster is load-bearing, not a nicety: the strips are 5% of the
    /// frame's height but never under 14 points, so at the DISPLAY size the
    /// floor binds and the preview draws plates half again as thick as the
    /// daily will carry. At twice that it does not bind, and the preview shows
    /// the proportion a real frame gets.
    @Test func thePreviewRasterIsBigEnoughToShowTheRealStripHeight() {
        let display = DailiesBurninPreview.size.height
        let raster = display * DailiesBurninPreview.raster
        #expect(display * 0.05 < DailiesStripMetrics.minimumStripHeight,
                "the floor no longer binds at the display size")
        #expect(raster * 0.05 >= DailiesStripMetrics.minimumStripHeight,
                "at \(raster)pt the strip floor still binds")
    }
}
