import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// The verify sheet, rendered headless in both languages.
///
/// Same fixed 620pt as the offload sheet and the same reason for measuring it: a
/// Russian sentence that cannot compress does not throw, it silently pushes the
/// content past the frame that clips it. This sheet is worse than the offload's
/// in that respect — its verdict lines are whole sentences with two numbers in
/// them ("Испорчено или потеряно %d из %d файлов — этот диск не удалять") and
/// its fault rows carry a path AND a reason on one line.
@Suite @MainActor struct ViewVerifyTests {
    /// What the sheet's own 20pt padding leaves for the content. The two sheets
    /// share a width, so they share the budget.
    static let inner = OffloadSheet.width - 40

    private func disk(_ name: String) -> URL {
        URL(fileURLWithPath: "/Volumes/\(name)")
    }

    private func progress(cancelling: Bool) -> OffloadVerifyProgress {
        OffloadVerifyProgress(
            filesTotal: 128, filesDone: 41, bytesTotal: 64_000_000_000,
            bytesRead: 20_000_000_000,
            currentFile: "DCIM/100MEDIA/A001C042_240730_R1AB.mov",
            elapsed: 48.5, isCancelling: cancelling)
    }

    /// One ending, for the states below.
    private func report(mismatched: [OffloadVerifyFault] = [],
                        missing: [String] = [], extra: [String] = [],
                        scanFailures: [String] = [],
                        verified: Int = 128,
                        cancelled: Bool = false) -> OffloadVerifyReport {
        OffloadVerifyReport(
            root: disk("DAILIES_SSD_1/CARD_A001"),
            manifest: disk("DAILIES_SSD_1/CARD_A001/ascmhl/"
                + "0001_CARD_A001_2026-07-30_143102.mhl"),
            algorithm: .xxh64,
            span: OffloadSpan(started: Date(), finished: Date()),
            verified: (0..<verified).map { "DCIM/100MEDIA/A001C\($0).mov" },
            mismatched: mismatched, missing: missing, extra: extra,
            scanFailures: scanFailures, bytesRead: 64_000_000_000,
            wasCancelled: cancelled)
    }

    /// The worst card there is: two faults with long reasons, a missing list, a
    /// stray list and a scan problem, all at once.
    private func damaged() -> OffloadVerifyReport {
        report(mismatched: [
            OffloadVerifyFault(relativePath: "DCIM/100MEDIA/A001C042.mov",
                               reason: "checksum mismatch"),
            OffloadVerifyFault(relativePath: "DCIM/100MEDIA/A001C043.mov",
                               reason: "size is 4194304 bytes, manifest says "
                                + "8402653184"),
        ],
        missing: (0..<9).map { "DCIM/100MEDIA/A001C0\($0)_240730_R1AB.mov" },
        extra: ["Icon\r", "lut/Kodak 2383 D65.cube"],
        scanFailures: ["100MEDIA (Permission denied)"],
        verified: 117)
    }

    // MARK: - the sheet

    /// Freshly opened, before the first file has been hashed: the title and the
    /// disk, as a tile of the same family the offload sheet's two ends are
    /// drawn in (owner item 22).
    @Test func theOpeningSheetFitsItsOwnFixedWidth() async throws {
        try await ViewProbe.run { probe in
            probe.controller.verify.root = self.disk("DAILIES_SSD_1/CARD_A001")

            let ideal = probe.fittingSizes {
                OffloadVerifySheet(model: probe.controller.verify)
            }
            let minimum = probe.minimumWidths {
                OffloadVerifySheet(model: probe.controller.verify).content
            }

            #expect(ideal.en.width == OffloadSheet.width)
            #expect(ideal.ru.width == OffloadSheet.width)
            #expect(minimum.ru <= Self.inner,
                    "the opening sheet needs \(minimum.ru)pt of \(Self.inner)")
            #expect(ideal.ru.height > 120)
        }
    }

    /// Mid-pass: the file line, the count, the rate and the bar.
    @Test func theRunningSheetFitsInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let model = probe.controller.verify
            model.root = self.disk("DAILIES_SSD_1/CARD_A001")
            model.isRunning = true
            model.progress = self.progress(cancelling: false)

            let ideal = probe.fittingSizes { OffloadVerifySheet(model: model) }
            let minimum = probe.minimumWidths {
                OffloadVerifySheet(model: model).content
            }

            #expect(ideal.ru.width == OffloadSheet.width)
            #expect(minimum.ru <= Self.inner,
                    "the running sheet needs \(minimum.ru)pt")
        }
    }

    /// Stopping replaces the file line with a sentence ("Завершаю текущий
    /// файл...") that is much longer than the path it stands in for is short.
    @Test func theProgressPanelFitsTheSheetsInnerWidth() async throws {
        try await ViewProbe.run { probe in
            for cancelling in [false, true] {
                let minimum = probe.minimumWidths {
                    OffloadVerifyProgressPanel(
                        progress: self.progress(cancelling: cancelling),
                        isCancelling: cancelling)
                }
                #expect(minimum.ru <= Self.inner,
                        "progress (cancelling: \(cancelling)) needs \(minimum.ru)pt")
                #expect(minimum.en <= Self.inner)
            }
        }
    }

    // MARK: - the verdict card

    /// All four endings, at the width the sheet actually gives the card.
    @Test func everyVerdictCardFitsTheSheetsInnerWidth() async throws {
        try await ViewProbe.run { probe in
            let endings: [(name: String, report: OffloadVerifyReport)] = [
                ("intact", self.report()),
                ("strays only", self.report(extra: ["shot-list.txt"])),
                ("damaged", self.damaged()),
                ("cancelled", self.report(verified: 40, cancelled: true)),
            ]
            for ending in endings {
                let sizes = probe.sizes(proposedWidth: Self.inner) {
                    OffloadVerifyResultPanel(report: ending.report)
                }
                let minimum = probe.minimumWidths {
                    OffloadVerifyResultPanel(report: ending.report)
                }

                #expect(minimum.ru <= Self.inner,
                        "\(ending.name): needs \(minimum.ru)pt of \(Self.inner)")
                #expect(sizes.ru.width <= Self.inner, "\(ending.name)")
                #expect(sizes.en.width <= Self.inner, "\(ending.name)")
                #expect(sizes.ru.height > 40, "the \(ending.name) card is empty")
            }
        }
    }

    /// A disk that lost a whole folder is hundreds of rows. The card caps each
    /// list, because a sheet that grows past the window is one nobody scrolls
    /// back up to the verdict on — and the verdict is the sentence the decision
    /// is made from.
    @Test func aLongFaultListDoesNotGrowTheCardWithoutBound() async throws {
        try await ViewProbe.run { probe in
            let five = self.report(
                missing: (0..<OffloadVerifyResultPanel.listLimit)
                    .map { "DCIM/100MEDIA/A001C\($0).mov" },
                verified: 0)
            let hundreds = self.report(
                missing: (0..<400).map { "DCIM/100MEDIA/A001C\($0).mov" },
                verified: 0)

            let short = probe.sizes(proposedWidth: Self.inner) {
                OffloadVerifyResultPanel(report: five)
            }
            let long = probe.sizes(proposedWidth: Self.inner) {
                OffloadVerifyResultPanel(report: hundreds)
            }

            // one extra line: the "...and %d more" summary, and nothing else
            #expect(long.en.height > short.en.height,
                    "the overflow line is not drawn")
            #expect(long.en.height < short.en.height * 1.5,
                    "400 rows drew \(long.en.height)pt, five drew \(short.en.height)")
            #expect(long.ru.width <= Self.inner)
        }
    }

    /// The folder that could not be checked at all: one localized sentence, and
    /// it wraps inside the sheet rather than widening it.
    @Test func theNoManifestSentenceFitsTheSheet() async throws {
        try await ViewProbe.run { probe in
            let model = probe.controller.verify
            model.root = self.disk("DAILIES_SSD_1")
            model.failure = CaptureController.verifyFailureMessage(
                OffloadVerifyError.noManifest("DAILIES_SSD_1"), at: model.root)

            let ideal = probe.fittingSizes { OffloadVerifySheet(model: model) }
            let minimum = probe.minimumWidths {
                OffloadVerifySheet(model: model).content
            }

            #expect(ideal.ru.width == OffloadSheet.width)
            #expect(minimum.ru <= Self.inner,
                    "the failure sheet needs \(minimum.ru)pt")
        }
    }

    /// The whole sheet with the worst result in it — the state the operator
    /// reads before deciding whether the disk can be shipped.
    @Test func theFinishedSheetFitsInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let model = probe.controller.verify
            model.root = self.disk("DAILIES_SSD_1/CARD_A001")
            model.report = self.damaged()

            let ideal = probe.fittingSizes { OffloadVerifySheet(model: model) }
            let minimum = probe.minimumWidths {
                OffloadVerifySheet(model: model).content
            }

            #expect(ideal.ru.width == OffloadSheet.width)
            #expect(minimum.ru <= Self.inner,
                    "the finished sheet needs \(minimum.ru)pt")
            #expect(ideal.ru.height > 300)
            // Russian is longer, but a label that wrapped where English did not
            // shows up as a step change in height, not a few points
            #expect(ideal.ru.height <= ideal.en.height * 1.6,
                    "RU grew to \(ideal.ru.height) from \(ideal.en.height)")
        }
    }
}
