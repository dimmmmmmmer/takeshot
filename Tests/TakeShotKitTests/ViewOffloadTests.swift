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
            OffloadDestinationResult(
                id: index, url: card("DAILIES_SSD_\(index + 1)/CARD_A001"),
                filesVerified: ending.verified, filesTotal: 128,
                bytesWritten: 32_000_000_000, mismatches: ending.mismatches,
                failure: ending.failure,
                manifestURL: card("SSD/ascmhl/0001_CARD_A001_2026-07-30_143102.mhl"),
                summaryURL: nil, elapsed: 620.4, wasCancelled: ending.cancelled)
        }
        return OffloadReport(
            source: card("CARD_A001"), algorithm: .xxh64, started: Date(),
            finished: Date(), filesTotal: 128, bytesTotal: 64_000_000_000,
            filesProcessed: 128, scanFailures: [],
            sourceFailures: ["DCIM/100MEDIA/A001C099.mov (Input/output error)"],
            wasCancelled: false, destinations: results)
    }

    // MARK: - the sheet

    /// Nothing chosen yet: the empty states are localized sentences ("Add at
    /// least one destination", "Ничего не выбрано") and they share the row with
    /// the pickers.
    @Test func theEmptySheetFitsItsOwnFixedWidth() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes {
                OffloadSheet(model: probe.controller.offload)
            }
            let minimum = probe.minimumWidths {
                OffloadSheet(model: probe.controller.offload).content
            }

            #expect(ideal.en.width == OffloadSheet.width)
            #expect(ideal.ru.width == OffloadSheet.width)
            #expect(minimum.ru <= Self.inner,
                    "the empty sheet needs \(minimum.ru)pt of \(Self.inner)")
            #expect(ideal.ru.height > 120)
        }
    }

    /// A card and two SSDs: paths, the "→ card folder" hint under each row, and
    /// the checksum picker with its explanatory line.
    @Test func theConfiguredSheetFitsInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            self.configure(probe.controller.offload)

            let ideal = probe.fittingSizes {
                OffloadSheet(model: probe.controller.offload)
            }
            let minimum = probe.minimumWidths {
                OffloadSheet(model: probe.controller.offload).content
            }

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
            model.isRunning = true
            model.progress = self.progress(failing: true)

            let ideal = probe.fittingSizes { OffloadSheet(model: model) }
            let minimum = probe.minimumWidths { OffloadSheet(model: model).content }

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

    /// The whole sheet with a finished run in it — the state the operator reads
    /// before deciding to wipe the card.
    @Test func theFinishedSheetFitsInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let model = probe.controller.offload
            self.configure(model)
            model.report = self.report()

            let ideal = probe.fittingSizes { OffloadSheet(model: model) }
            let minimum = probe.minimumWidths { OffloadSheet(model: model).content }

            #expect(ideal.ru.width == OffloadSheet.width)
            #expect(minimum.ru <= Self.inner,
                    "the finished sheet needs \(minimum.ru)pt")
            #expect(ideal.ru.height > 400)
        }
    }
}
