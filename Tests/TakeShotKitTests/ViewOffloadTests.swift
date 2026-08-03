import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// The offload sheet, rendered headless in both languages.
///
/// The sheet is a fixed 620pt wide, which is exactly why it needs measuring: a
/// Russian label that cannot compress does not throw, it silently pushes the
/// content wider than the frame that clips it. Russian runs 1.5-3x longer than
/// English here — "Add destination" against "Добавить диск", a verdict line
/// against a whole sentence — and every state of the sheet has different text in
/// it, so all four are rendered: empty, configured, running, finished.
@Suite @MainActor struct ViewOffloadTests {
    /// What the sheet's own 20pt padding leaves for the content.
    static let inner = OffloadSheet.width - 40

    // MARK: - fixtures

    private func card(_ name: String) -> URL {
        URL(fileURLWithPath: "/Volumes/\(name)")
    }

    /// The sheet with everything it now draws: the form, the run history and
    /// the cards already dealt with (owner item 18). Built through one helper
    /// so a block added to the sheet cannot go unmeasured in half the states.
    private func sheet(_ probe: ViewProbe) -> OffloadSheet {
        OffloadSheet(model: probe.controller.offload,
                     history: probe.controller.offloadHistory,
                     ledger: probe.controller.offloadedCards)
    }

    /// Two remembered cards, one of each kind. Written into the ledger the
    /// harness has already pointed at scratch — never the operator's own.
    private func rememberCards(_ probe: ViewProbe) {
        let ledger = probe.controller.offloadedCards
        ledger.markOffloaded(
            CardCandidate(volume: MountedVolume(url: card("CARD_A001"),
                                                name: "CARD_A001"),
                          files: 128, bytes: 61_000_000_000,
                          evidence: .cameraStructure("DCIM")),
            at: Date(timeIntervalSince1970: 1_800_000_000))
        ledger.suppress(
            CardCandidate(volume: MountedVolume(url: card("DIT_STICK"),
                                                name: "DIT_STICK"),
                          files: 4, bytes: 200_000_000,
                          evidence: .detachableVideo(2)),
            at: Date(timeIntervalSince1970: 1_800_000_500))
    }

    private func configure(_ model: OffloadSheetModel) {
        model.source = card("CARD_A001")
        model.addDestination(card("DAILIES_SSD_1/Offload"))
        model.addDestination(card("DAILIES_SSD_2/Offload"))
    }

    private func progress(failing: Bool) -> OffloadProgress {
        OffloadProgress(
            filesTotal: 128, bytesTotal: 64_000_000_000,
            currentFile: "DCIM/100MEDIA/A001C042_240730_R1AB.mov",
            destinations: [
                OffloadDestinationProgress(
                    id: 0, url: card("DAILIES_SSD_1/Offload/CARD_A001"),
                    filesDone: 41, bytesWritten: 20_000_000_000, mismatches: 0,
                    failure: nil, megabytesPerSecond: 412.5),
                OffloadDestinationProgress(
                    id: 1, url: card("DAILIES_SSD_2/Offload/CARD_A001"),
                    filesDone: 12, bytesWritten: 6_000_000_000, mismatches: 0,
                    failure: failing
                        ? "DCIM/100MEDIA/A001C013.mov: The volume “DAILIES_SSD_2”"
                            + " could not be found."
                        : nil,
                    megabytesPerSecond: failing ? 0 : 95.2),
            ],
            elapsed: 48.5, isCancelling: false)
    }

    /// One destination's ending, for the four cards below.
    private struct Ending {
        var verified: Int
        var mismatches: [String] = []
        var failure: String?
        var cancelled = false
    }

    /// One of each outcome — the four cards have four different verdict
    /// sentences, and the failed one carries an arbitrarily long reason.
    private func report() -> OffloadReport {
        let endings = [
            Ending(verified: 128),
            Ending(verified: 126,
                   mismatches: ["DCIM/100MEDIA/A001C042.mov (checksum mismatch)",
                                "DCIM/100MEDIA/A001C043.mov (checksum mismatch)"]),
            Ending(verified: 57,
                   failure: "DCIM/100MEDIA/A001C058.mov: not enough space: needs "
                    + "64.0 GB, 3.1 GB free"),
            Ending(verified: 40, cancelled: true),
        ]
        let results = endings.enumerated().map { index, ending in
            var result = OffloadDestinationResult(
                id: index, url: card("DAILIES_SSD_\(index + 1)/CARD_A001"),
                totals: OffloadDestinationTotals(
                    filesVerified: ending.verified, filesTotal: 128,
                    bytesWritten: 32_000_000_000, elapsed: 620.4),
                mismatches: ending.mismatches, failure: ending.failure,
                wasCancelled: ending.cancelled)
            result.manifestURL =
                card("SSD/ascmhl/0001_CARD_A001_2026-07-30_143102.mhl")
            // The card names the REPORT, not the manifest (owner item 17), and
            // the picture is what it names when there is one — so both have to
            // be on the fixture or the line the rework added never renders and
            // this suite measures a sheet the operator never sees.
            result.summaryURL = card("SSD/offload-summary_2026-07-30_143102.txt")
            result.imageURL = card("SSD/offload-summary_2026-07-30_143102.png")
            return result
        }
        return OffloadReport(
            run: OffloadRunFacts(
                source: card("CARD_A001"), algorithm: .xxh64,
                creator: .current(version: "0.1.0"),
                span: OffloadSpan(started: Date(), finished: Date()),
                card: OffloadVolume(files: 128, bytes: 64_000_000_000),
                problems: OffloadProblems(source: [
                    "DCIM/100MEDIA/A001C099.mov (Input/output error)",
                ])),
            filesProcessed: 128, wasCancelled: false, destinations: results)
    }

    // MARK: - the sheet

    /// Nothing chosen yet: the empty states are localized sentences ("Add at
    /// least one destination", "Ничего не выбрано") and they sit in a tile of
    /// the same family a chosen card gets.
    @Test func theEmptySheetFitsItsOwnFixedWidth() async throws {
        try await ViewProbe.run { probe in
            self.rememberCards(probe)

            let ideal = probe.fittingSizes { self.sheet(probe) }
            let minimum = probe.minimumWidths { self.sheet(probe).content }

            #expect(ideal.en.width == OffloadSheet.width)
            #expect(ideal.ru.width == OffloadSheet.width)
            #expect(minimum.ru <= Self.inner,
                    "the empty sheet needs \(minimum.ru)pt of \(Self.inner)")
            #expect(ideal.ru.height > 120)
        }
    }

    /// A card and two SSDs, as two halves of one operation (owner item 22): the
    /// source is a tile with a name, a path and a size line, exactly like the
    /// destinations under it, and each destination's tile also says which
    /// folder its copy lands in.
    @Test func theConfiguredSheetFitsInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            self.configure(probe.controller.offload)
            self.rememberCards(probe)

            let ideal = probe.fittingSizes { self.sheet(probe) }
            let minimum = probe.minimumWidths { self.sheet(probe).content }

            #expect(ideal.ru.width == OffloadSheet.width)
            #expect(minimum.ru <= Self.inner,
                    "the configured sheet needs \(minimum.ru)pt")
            // Russian is longer, but a label that wrapped where English did not
            // shows up as a step change in height, not a few points.
            #expect(ideal.ru.height <= ideal.en.height * 1.5,
                    "RU grew to \(ideal.ru.height) from \(ideal.en.height)")
        }
    }

    /// Mid-run: the file line, and a row per destination with files done and
    /// MB/s. One destination is dead, so its reason has to truncate rather than
    /// widen the sheet.
    @Test func theRunningSheetFitsWithADeadDestination() async throws {
        try await ViewProbe.run { probe in
            let model = probe.controller.offload
            self.configure(model)
            self.rememberCards(probe)
            model.isRunning = true
            model.progress = self.progress(failing: true)

            let ideal = probe.fittingSizes { self.sheet(probe) }
            let minimum = probe.minimumWidths { self.sheet(probe).content }

            #expect(ideal.ru.width == OffloadSheet.width)
            #expect(minimum.ru <= Self.inner,
                    "the running sheet needs \(minimum.ru)pt")
            #expect(ideal.ru.height > ideal.en.height * 0.6)
        }
    }

    /// The progress panel on its own, at the width the sheet actually gives it:
    /// this is the number that says whether "%d из %d файлов" plus a rate still
    /// fits on one line beside the disk name.
    @Test func theProgressPanelFitsTheSheetsInnerWidth() async throws {
        try await ViewProbe.run { probe in
            for failing in [false, true] {
                let minimum = probe.minimumWidths {
                    OffloadProgressPanel(progress: self.progress(failing: failing),
                                         isCancelling: false)
                }
                #expect(minimum.ru <= Self.inner,
                        "progress panel (failing: \(failing)) needs \(minimum.ru)pt")
                #expect(minimum.en <= Self.inner)
            }
        }
    }

    /// Cancelling replaces the file line with a sentence ("Завершаю текущий
    /// файл...") that is much longer than the English one.
    @Test func theCancellingLineFitsTheSheetsInnerWidth() async throws {
        try await ViewProbe.run { probe in
            let minimum = probe.minimumWidths {
                OffloadProgressPanel(progress: self.progress(failing: false),
                                     isCancelling: true)
            }

            #expect(minimum.ru <= Self.inner, "cancelling line needs \(minimum.ru)pt")
        }
    }

    /// The result cards: four outcomes, four verdict sentences, and the longest
    /// Russian one ("Сверено только %d из %d файлов — карту не стирать") is the
    /// one that has to wrap inside the card instead of stretching it.
    @Test func theResultPanelFitsTheSheetsInnerWidth() async throws {
        try await ViewProbe.run { probe in
            let sizes = probe.sizes(proposedWidth: Self.inner) {
                OffloadResultPanel(report: self.report())
            }
            let minimum = probe.minimumWidths {
                OffloadResultPanel(report: self.report())
            }

            #expect(minimum.ru <= Self.inner,
                    "the result panel needs \(minimum.ru)pt of \(Self.inner)")
            #expect(sizes.ru.width <= Self.inner)
            #expect(sizes.en.width <= Self.inner)
            // Four cards plus the source-problem line: a panel that came back
            // short would mean a card silently did not render.
            #expect(sizes.ru.height > 200)
            #expect(sizes.ru.height <= sizes.en.height * 1.6,
                    "RU results grew to \(sizes.ru.height) from \(sizes.en.height)")
        }
    }

    /// What the card names is the REPORT (owner item 17): the picture that gets
    /// handed over, the text file if the picture could not be drawn, and nothing
    /// at all rather than the manifest — an editor handed
    /// "Manifest: 0001_CARD_A001.mhl" does not know what they have been given.
    @Test func theResultCardNamesTheReportAndNeverTheManifest() {
        var result = OffloadDestinationResult(
            id: 0, url: card("SSD/CARD_A001"),
            totals: OffloadDestinationTotals(filesVerified: 1, filesTotal: 1,
                                             bytesWritten: 1, elapsed: 1))
        result.manifestURL = card("SSD/ascmhl/0001_CARD_A001.mhl")

        #expect(OffloadResultPanel.reportName(result) == nil,
                "it fell back to the manifest")
        result.summaryURL = card("SSD/offload-summary_x.txt")
        #expect(OffloadResultPanel.reportName(result) == "offload-summary_x.txt")
        result.imageURL = card("SSD/offload-summary_x.png")
        #expect(OffloadResultPanel.reportName(result) == "offload-summary_x.png")
    }

    /// The whole sheet with a finished run in it — the state the operator reads
    /// before deciding to wipe the card.
    @Test func theFinishedSheetFitsInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let model = probe.controller.offload
            self.configure(model)
            self.rememberCards(probe)
            model.report = self.report()

            let ideal = probe.fittingSizes { self.sheet(probe) }
            let minimum = probe.minimumWidths { self.sheet(probe).content }

            #expect(ideal.ru.width == OffloadSheet.width)
            #expect(minimum.ru <= Self.inner,
                    "the finished sheet needs \(minimum.ru)pt")
            #expect(ideal.ru.height > 400)
        }
    }

    // MARK: - the run seen from the takes panel (owner item 16)

    /// The strip that reports a running job while the sheet is closed. It lives
    /// in a 310pt panel, which is less than half the sheet's width, so every
    /// line in it has to truncate.
    ///
    /// The status line is measured in RUSSIAN in both renders on purpose: it is
    /// a stored string set before the view is built, and the Russian one is the
    /// longer of the two — so this is the worst case for both languages.
    @Test func theStatusStripFitsTheNarrowestTakesPanel() async throws {
        try await ViewProbe.run { probe in
            let model = probe.controller.offload
            model.isRunning = true
            model.progress = self.progress(failing: false)
            let status = ViewRender.withLanguage(.russian) {
                L("offload_progress", 41, 128)
            }
            probe.controller.offloadStatus = status
            // What the readout actually gets: the panel minus its own inset.
            let budget = ViewBudget.panelMinWidth - 24

            let minimum = probe.minimumWidths {
                OffloadStatusStrip(status: status, offload: model,
                                   verify: probe.controller.verify)
            }
            let panel = probe.minimumWidths(proposedHeight: 600) {
                PanelRunStatus()
            }

            #expect(minimum.ru <= budget,
                    "the status strip needs \(minimum.ru)pt of \(budget)")
            #expect(minimum.en <= budget)
            #expect(panel.ru <= ViewBudget.panelMinWidth,
                    "a running job pushed the panel readout to \(panel.ru)pt")
        }
    }

}

/// The two pieces of the sheet a whole-sheet measurement cannot see.
///
/// Its own suite rather than more of the one above, which is at the type-length
/// ceiling — and these two are measured on their own for a reason of their own:
/// the sheet is PINNED to 620pt, so anything that does not fit inside it is
/// clipped rather than reported, and every measurement of the sheet answers 620
/// whatever is on it.
@Suite @MainActor struct ViewOffloadTileTests {
    static let inner = OffloadSheet.width - 40

    /// The action bar. Four Russian labels in a row — Stop, "Проверить копию на
    /// диске...", Hide and "Начать офлоад" — is the widest it ever gets, and the
    /// verify button is what put it there (owner item 25).
    @Test func theFooterFitsTheSheetsFixedWidthInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let model = probe.controller.offload
            model.isRunning = true

            let minimum = probe.minimumWidths {
                OffloadSheetFooter(model: model) {}
            }

            #expect(minimum.ru <= Self.inner,
                    "the footer needs \(minimum.ru)pt of \(Self.inner)")
            #expect(minimum.en <= Self.inner)
        }
    }

    /// The two ends of the copy read as one family (owner item 22): the source
    /// tile and a destination tile are the same view, so what is measured here
    /// is the widest thing either can hold — a full path and a size line.
    @Test func theSourceAndDestinationTilesFitTheSheet() async throws {
        try await ViewProbe.run { probe in
            let long = "/Volumes/DAILIES_SSD_1/2026-07-30/Offload/CARD_A001"
            let sizes = probe.minimumWidths {
                VStack {
                    OffloadPathTile(
                        icon: "externaldrive", title: "CARD_A001", path: long,
                        detail: L("offload_space_used", "312.0 GB", "512.0 GB"),
                        finderTarget: URL(fileURLWithPath: long)) {
                            Button(L("choose")) {}
                        }
                    OffloadPathTile(
                        icon: "folder", title: L("offload_no_source"),
                        isEmpty: true) { Button(L("choose")) {} }
                }
            }

            #expect(sizes.ru <= Self.inner,
                    "the tiles need \(sizes.ru)pt of \(Self.inner)")
            #expect(sizes.en <= Self.inner)
        }
    }
}

/// The prompt a mounted card raises, as a rendered view.
///
/// Its own suite rather than more of the one above: the offload views were
/// already at the type-length ceiling, and this is a different surface — three
/// buttons and two sentences squeezed into the takes panel, not a sheet.
@MainActor
struct ViewCardOfferTests {
    /// The card-mount prompt shares that 310pt panel and carries the longest
    /// localized sentences in it: a card name, the reason it is being offered,
    /// and three buttons in a row. Three Russian button labels side by side is
    /// exactly the shape that pushes a panel wider than the split view allows.
    @Test func theCardOfferBannerFitsTheNarrowestTakesPanel() async throws {
        try await ViewProbe.run { probe in
            let card = CardCandidate(
                volume: MountedVolume(url: URL(fileURLWithPath: "/Volumes/A001"),
                                      name: "CARD_A001", isRemovable: true),
                files: 128, bytes: 61_000_000_000,
                evidence: .cameraStructure("DCIM"))
            // What the banner actually gets: the panel minus the readout's inset.
            let budget = ViewBudget.panelMinWidth - 24

            let minimum = probe.minimumWidths { CardOfferBanner(card: card) }
            #expect(minimum.ru <= budget,
                    "the card prompt needs \(minimum.ru)pt of \(budget)")
            #expect(minimum.en <= budget)

            probe.controller.cardOffer = card
            let panel = probe.minimumWidths(proposedHeight: 600) {
                PanelRunStatus()
            }
            #expect(panel.ru <= ViewBudget.panelMinWidth,
                    "a card prompt pushed the panel readout to \(panel.ru)pt")
        }
    }

    /// Both branches of the heuristic explain themselves, in both languages —
    /// the reason line is the whole reason the prompt is trustworthy, and a raw
    /// key there would be worse than no reason at all.
    @Test func everyOfferReasonIsTranslated() async throws {
        try await ViewProbe.run { _ in
            let card = CardCandidate(
                volume: MountedVolume(url: URL(fileURLWithPath: "/Volumes/X"),
                                      name: "X"),
                files: 3, bytes: 300, evidence: .cameraStructure("XDROOT"))
            var stick = card
            stick.evidence = .detachableVideo(2)
            for candidate in [card, stick] {
                for language in [AppLanguage.english, .russian] {
                    let reason = ViewRender.withLanguage(language) {
                        candidate.reasonText
                    }
                    #expect(!reason.hasPrefix("card_reason"),
                            "\(candidate.evidence) renders its raw key in \(language)")
                }
            }
        }
    }
}
