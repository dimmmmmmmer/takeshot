import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// The resume question, rendered headless in both languages.
///
/// It is the one panel in the app whose whole job is to be READ before a button
/// is pressed — the operator is agreeing to skip files — so it carries more prose
/// than anything else on the sheet, and the Russian is longer again. The sheet is
/// a fixed 620pt: a sentence that does not fit does not throw, it silently pushes
/// the content past the frame that clips it.
@Suite @MainActor struct ViewOffloadResumeTests {
    static let inner = OffloadSheet.width - 40

    private func card(_ name: String) -> URL {
        URL(fileURLWithPath: "/Volumes/\(name)")
    }

    /// One disk holding most of the card, one holding another card's copy, one
    /// that has never been offloaded to — the three lines the panel has to draw.
    private func review() -> OffloadResumeReview {
        let claimed = (0..<400).map {
            OffloadEntry(relativePath: String(format: "DCIM/100MEDIA/A001C%03d.mov",
                                              $0 + 1),
                         size: 152_000_000, hash: "0011223344556677")
        }
        return OffloadResumeReview(
            card: OffloadVolume(files: 900, bytes: 137_000_000_000),
            offers: [
                OffloadResumeOffer(
                    destination: card("DAILIES_SSD_1/CARD_A001"),
                    manifest: card("DAILIES_SSD_1/CARD_A001/ascmhl/0001_x.mhl"),
                    claimed: claimed, refusal: nil),
                OffloadResumeOffer(
                    destination: card("DAILIES_SSD_2/CARD_A001"),
                    manifest: card("DAILIES_SSD_2/CARD_A001/ascmhl/0001_y.mhl"),
                    claimed: [], refusal: .differentCard),
                OffloadResumeOffer(
                    destination: card("DAILIES_SSD_3/CARD_A001"),
                    manifest: nil, claimed: [], refusal: .noManifest),
            ])
    }

    private func panel() -> OffloadResumePanel {
        OffloadResumePanel(review: review(), resume: {}, copyEverything: {})
    }

    // MARK: - it fits

    @Test func theResumeQuestionFitsTheSheetsInnerWidth() async throws {
        try await ViewProbe.run { probe in
            let minimum = probe.minimumWidths { self.panel() }
            let sizes = probe.sizes(proposedWidth: Self.inner) { self.panel() }

            #expect(minimum.ru <= Self.inner,
                    "the resume question needs \(minimum.ru)pt of \(Self.inner)")
            #expect(minimum.en <= Self.inner)
            #expect(sizes.ru.width <= Self.inner)
            // Three destination lines, two explanations and two buttons: a panel
            // that came back short would mean a line silently did not render.
            #expect(sizes.en.height > 120)
            #expect(sizes.ru.height > 120)
        }
    }

    /// The whole sheet with the question in it — the state the operator is
    /// actually looking at when they decide.
    @Test func theSheetWithTheQuestionFitsItsFixedWidth() async throws {
        try await ViewProbe.run { probe in
            let model = probe.controller.offload
            model.source = self.card("CARD_A001")
            model.addDestination(self.card("DAILIES_SSD_1/Offload"))
            model.resumeReview = self.review()

            let sheet = OffloadSheet(model: model,
                                     history: probe.controller.offloadHistory,
                                     ledger: probe.controller.offloadedCards)
            let ideal = probe.fittingSizes { sheet }
            let minimum = probe.minimumWidths { sheet.content }

            #expect(ideal.en.width == OffloadSheet.width)
            #expect(ideal.ru.width == OffloadSheet.width)
            #expect(minimum.ru <= Self.inner,
                    "the sheet with the question needs \(minimum.ru)pt")
        }
    }

    // MARK: - what the line says

    /// The count is the operator's whole basis for answering, so it has to be the
    /// count: files already there, out of the files on the card.
    @Test func theLineNamesTheDiskAndBothCounts() {
        let review = self.review()
        let line = OffloadResumePanel.line(review.offers[0], card: review.card)

        #expect(line.contains("CARD_A001"))
        #expect(line.contains("400"))
        #expect(line.contains("900"))
        // …and the size, because 400 files means nothing without it
        #expect(line.contains("60.8 GB"))
    }

    /// A disk that cannot be resumed says WHY, in the operator's language. Just
    /// "everything will be copied" teaches nobody anything, and an operator who
    /// is not told why stops believing the count on the disks that do offer one.
    @Test func aRefusedDiskSaysWhyInBothLanguages() {
        let review = self.review()
        let english = ViewRender.withLanguage(.english) {
            OffloadResumePanel.line(review.offers[1], card: review.card)
        }
        let russian = ViewRender.withLanguage(.russian) {
            OffloadResumePanel.line(review.offers[1], card: review.card)
        }

        #expect(english.contains("different card"))
        #expect(russian != english, "the refusal was not translated")
        #expect(russian.contains("CARD_A001"))
        // every refusal the engine can return has a sentence of its own
        for refusal: OffloadResumeRefusal in [.noManifest, .noStamp,
                                              .differentCard, .cardChanged,
                                              .differentHash(.sha256),
                                              .unreadable("malformed XML")] {
            let text = OffloadResumePanel.text(refusal)
            #expect(!text.hasPrefix("offload_resume_"),
                    "untranslated: \(text)")
            #expect(!text.isEmpty)
        }
    }

    /// The reused count reaches the result card. The verdict above it counts
    /// reused files as verified — because they were, off this disk, this run — so
    /// without this line the operator cannot tell an hour of copying from four
    /// minutes.
    @Test func theResultCardSaysWhatWasReusedRatherThanCopied() async throws {
        try await ViewProbe.run { probe in
            var result = OffloadDestinationResult(
                id: 0, url: self.card("DAILIES_SSD_1/CARD_A001"),
                totals: OffloadDestinationTotals(
                    filesVerified: 900, filesTotal: 900,
                    bytesWritten: 76_000_000_000, elapsed: 620.4),
                resume: OffloadResumeFacts(
                    claimed: 401, reused: 400, reusedBytes: 61_000_000_000,
                    replaced: ["DCIM/100MEDIA/A001C401.mov"]))
            result.summaryURL = self.card("SSD/offload-summary_x.txt")
            let report = OffloadReport(
                run: OffloadRunFacts(
                    source: self.card("CARD_A001"), algorithm: .xxh64,
                    creator: .current(version: "0.1.0"),
                    span: OffloadSpan(started: Date(), finished: Date()),
                    card: OffloadVolume(files: 900, bytes: 137_000_000_000)),
                filesProcessed: 900, wasCancelled: false,
                destinations: [result])
            let panel = OffloadResultPanel(report: report)

            let minimum = probe.minimumWidths { panel }
            let sizes = probe.sizes(proposedWidth: Self.inner) { panel }

            #expect(minimum.ru <= Self.inner,
                    "the resumed result card needs \(minimum.ru)pt")
            #expect(sizes.ru.width <= Self.inner)
            // the extra line is drawn: a card without it is shorter
            let plain = OffloadResultPanel(report: OffloadReport(
                run: report.run, filesProcessed: 900, wasCancelled: false,
                destinations: [OffloadDestinationResult(
                    id: 0, url: result.url, totals: result.totals)]))
            let bare = probe.sizes(proposedWidth: Self.inner) { plain }
            #expect(sizes.en.height > bare.en.height)
        }
    }
}
