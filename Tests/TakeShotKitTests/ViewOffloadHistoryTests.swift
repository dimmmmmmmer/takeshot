import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// The log of past offloads at the bottom of the offload sheet (owner item 18),
/// rendered headless in both languages.
///
/// Its own suite rather than another section of `ViewOffloadTests`: this list is
/// not a state of the sheet's form — it is on screen before anything is picked
/// and after everything has finished — and almost every word in a row is
/// localized, where the form above it is mostly paths and numbers. Russian runs
/// 1.5-3x longer here ("verified" against "сверено", "3 copies" against
/// "копий: 3") on a row that has to stay one line.
@Suite @MainActor struct ViewOffloadHistoryTests {
    /// What the sheet's own 20pt padding leaves for the content, as in
    /// `ViewOffloadTests` and `ViewVerifyTests`.
    static let inner = OffloadSheet.width - 40

    private func card(_ name: String) -> URL {
        URL(fileURLWithPath: "/Volumes/\(name)")
    }

    /// A finished run, invented rather than copied: everything a history row
    /// draws comes off the report, so none of this needs a disk.
    private func report(verified: Int, mismatches: [String] = [],
                        failure: String? = nil, cancelled: Bool = false,
                        copies: Int = 1) -> OffloadReport {
        let results = (0..<copies).map { index in
            OffloadDestinationResult(
                id: index,
                url: card("DAILIES_SSD_\(index + 1)/CARD_A001_240730_REEL_02"),
                totals: OffloadDestinationTotals(
                    filesVerified: verified, filesTotal: 128,
                    bytesWritten: 32_000_000_000, elapsed: 620.4),
                mismatches: mismatches, failure: failure,
                wasCancelled: cancelled)
        }
        return OffloadReport(
            run: OffloadRunFacts(
                source: card("CARD_A001_240730_REEL_02"), algorithm: .xxh64,
                creator: .current(version: "0.1.0"),
                span: OffloadSpan(started: Date(), finished: Date()),
                card: OffloadVolume(files: 128, bytes: 64_000_000_000)),
            filesProcessed: 128, wasCancelled: cancelled,
            destinations: results)
    }

    /// One run per verdict the list can show, so all four rows are rendered —
    /// they differ by symbol, colour and a localized word on the right — plus a
    /// three-destination run, which is the row that says "3 copies" instead of
    /// naming a disk.
    private func pastRuns() -> [OffloadReport] {
        [report(verified: 128),
         report(verified: 126,
                mismatches: ["DCIM/100MEDIA/A001C042.mov (checksum mismatch)"]),
         report(verified: 57, failure: "not enough space"),
         report(verified: 40, cancelled: true),
         report(verified: 128, copies: 3)]
    }

    /// The list the sheet opens on. Each row carries a card name, a destination
    /// name, a date formatted by the machine's locale and a verdict word — all
    /// on one line that must truncate rather than widen the sheet.
    @Test func theHistoryListFitsTheSheetsInnerWidth() async throws {
        try await ViewProbe.run { probe in
            let store = probe.controller.offloadHistory
            for report in self.pastRuns() { store.record(report) }
            #expect(store.runs.count == 5)

            let minimum = probe.minimumWidths {
                OffloadHistoryList(store: store)
            }
            let sizes = probe.sizes(proposedWidth: Self.inner) {
                OffloadHistoryList(store: store)
            }

            #expect(minimum.ru <= Self.inner,
                    "the history list needs \(minimum.ru)pt of \(Self.inner)")
            #expect(sizes.ru.width <= Self.inner)
            #expect(sizes.en.width <= Self.inner)
            // A heading and five two-line rows: a list that came back short
            // means a row silently did not render.
            #expect(sizes.ru.height > 100)
        }
    }

    /// The first shooting day. The heading stays — a section that comes and
    /// goes moves everything under it — and the empty sentence is the answer.
    @Test func theEmptyHistoryStillDrawsItsHeading() async throws {
        try await ViewProbe.run { probe in
            let store = probe.controller.offloadHistory
            #expect(store.runs.isEmpty)

            let sizes = probe.sizes(proposedWidth: Self.inner) {
                OffloadHistoryList(store: store)
            }
            let minimum = probe.minimumWidths {
                OffloadHistoryList(store: store)
            }

            #expect(minimum.ru <= Self.inner)
            #expect(sizes.ru.height > 30, "the empty history drew nothing")
            #expect(sizes.ru.width <= Self.inner)
        }
    }

    /// The sheet that opens on nothing but its history — the state an operator
    /// reaches for to answer "have I already copied this card?" — still fits the
    /// width it is pinned to.
    @Test func theSheetOpensOnItsHistoryAndStillFits() async throws {
        try await ViewProbe.run { probe in
            let store = probe.controller.offloadHistory
            for report in self.pastRuns() { store.record(report) }
            let ledger = probe.controller.offloadedCards

            let ideal = probe.fittingSizes {
                OffloadSheet(model: probe.controller.offload, history: store,
                             ledger: ledger)
            }
            let minimum = probe.minimumWidths {
                OffloadSheet(model: probe.controller.offload, history: store,
                             ledger: ledger).content
            }

            #expect(ideal.en.width == OffloadSheet.width)
            #expect(ideal.ru.width == OffloadSheet.width)
            #expect(minimum.ru <= Self.inner,
                    "the sheet with history needs \(minimum.ru)pt")
            // The history is the tallest thing on an otherwise empty sheet.
            #expect(ideal.ru.height > 300)
        }
    }
}

/// The cards the app has stopped asking about, under the history (owner item
/// 18), rendered headless in both languages.
///
/// The row is the same shape as a history row and has the same problem: a card
/// name, a date the machine's locale formats, and a localized word saying which
/// of the two decisions this was — all on one line that must truncate rather
/// than widen the sheet. Russian is the longer of the two everywhere here
/// ("offloaded" against "скопирована").
@Suite @MainActor struct ViewCardLedgerTests {
    static let inner = OffloadSheet.width - 40

    private func remember(_ ledger: OffloadedCardLedger) {
        ledger.markOffloaded(
            CardCandidate(
                volume: MountedVolume(
                    url: URL(fileURLWithPath: "/Volumes/CARD_A001_240730_R2"),
                    name: "CARD_A001_240730_R2"),
                files: 128, bytes: 61_000_000_000,
                evidence: .cameraStructure("DCIM")),
            at: Date(timeIntervalSince1970: 1_800_000_000))
        ledger.suppress(
            CardCandidate(
                volume: MountedVolume(
                    url: URL(fileURLWithPath: "/Volumes/DIT_SCRATCH_DISK"),
                    name: "DIT_SCRATCH_DISK"),
                files: 4, bytes: 200_000_000,
                evidence: .detachableVideo(2)),
            at: Date(timeIntervalSince1970: 1_800_000_500))
    }

    /// Both kinds of row, drawn and measured. A card that was copied and a disk
    /// answered with Never are different decisions with different consequences,
    /// and the list is worth nothing if it cannot tell them apart on screen.
    @Test func bothKindsOfRowRenderAndFitTheSheet() async throws {
        try await ViewProbe.run { probe in
            let ledger = probe.controller.offloadedCards
            self.remember(ledger)
            #expect(ledger.cards.count == 2)

            let minimum = probe.minimumWidths {
                OffloadCardLedgerList(ledger: ledger)
            }
            let sizes = probe.sizes(proposedWidth: Self.inner) {
                OffloadCardLedgerList(ledger: ledger)
            }

            #expect(minimum.ru <= Self.inner,
                    "the remembered cards need \(minimum.ru)pt of \(Self.inner)")
            #expect(sizes.ru.width <= Self.inner)
            #expect(sizes.en.width <= Self.inner)
            // a heading and two two-line rows: a short answer means a row did
            // not render
            #expect(sizes.ru.height > 60)
            // …and the two rows say different things, in both languages
            for language in [AppLanguage.english, .russian] {
                let details = ViewRender.withLanguage(language) {
                    ledger.cards.map(OffloadCardLedgerList.detail)
                }
                #expect(Set(details).count == 2,
                        "\(language): both rows read the same — \(details)")
                for detail in details {
                    #expect(!detail.contains("cards_kind"),
                            "\(language) renders a raw key: \(detail)")
                }
            }
        }
    }

    /// Nothing remembered draws nothing at all. It is the last block on the
    /// sheet, so an absent heading moves nothing under it, and the only person
    /// who comes looking for this list is one whose card was not offered —
    /// which means it is not empty.
    @Test func anEmptyLedgerDrawsNothing() async throws {
        try await ViewProbe.run { probe in
            let ledger = probe.controller.offloadedCards
            #expect(ledger.cards.isEmpty)

            let sizes = probe.sizes(proposedWidth: Self.inner) {
                OffloadCardLedgerList(ledger: ledger)
            }

            #expect(sizes.en.height == 0, "the empty list drew \(sizes.en)")
        }
    }
}
