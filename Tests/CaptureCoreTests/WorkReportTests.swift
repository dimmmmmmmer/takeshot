import Foundation
import Testing

@testable import CaptureCore

/// **What the cart did, on one page** (owner: "хотелось бы иметь возможность
/// отгружать отчеты проделанной работы по дейликам и по слитым карточкам").
///
/// The failure that matters is a total that is wrong: this is the page a
/// production office reads instead of counting files, and a runtime or a byte
/// count that quietly drops an item is worse than no report at all.
@Suite struct WorkReportTests {
    private func at(day: Int, hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: day, hour: hour, minute: minute))
            ?? Date(timeIntervalSince1970: 0)
    }

    private func entry(_ name: String, seconds: Double?, size: Int64,
                       at finished: Date) -> DailiesJournal.Entry {
        DailiesJournal.Entry(
            source: "\(name).mov", sourceSize: size * 4,
            sourceModified: finished, recipe: "prores422/1920",
            output: "\(name)_proxy.mov", outputSize: size,
            outputName: "\(name)_proxy.mov", outputSeconds: seconds,
            outputAudio: 1, finishedAt: finished)
    }

    private func card(_ name: String, at date: Date, verdict: String = "verified",
                      files: Int = 100, verified: Int = 100,
                      bytes: Int64 = 32_000_000_000,
                      destinations: [String] = ["/Volumes/SHOW1"]) -> WorkReport.Card {
        WorkReport.Card(date: date, source: "/Volumes/\(name)",
                        destinations: destinations, verdict: verdict,
                        files: files, filesVerified: verified, bytes: bytes)
    }

    private let folder = URL(fileURLWithPath: "/Volumes/SHOW/DAILIES")

    /// The value beside one label in the totals block. By LINE rather than by
    /// substring: the labels are padded into a column whose width follows the
    /// longest label actually present, so a report with no span is spaced
    /// differently from one with it — and an assertion that spelled the
    /// spacing would be testing the padding rather than the number.
    private func value(_ text: String, of label: String) -> String? {
        text.components(separatedBy: "\n")
            .first { $0.hasPrefix(label) }?
            .dropFirst(label.count)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - the dailies half

    @Test func theDailiesReportTotalsWhatWasRendered() {
        var journal = DailiesJournal()
        journal.entries = [
            entry("A001C001", seconds: 120, size: 1_000_000_000,
                  at: at(day: 11, hour: 22)),
            entry("A001C002", seconds: 60, size: 500_000_000,
                  at: at(day: 11, hour: 23)),
        ]
        let text: String = WorkReport.dailies(journal, folder: folder)
        #expect(text.hasPrefix("TakeShot — dailies work report\n"))
        #expect(text.contains("/Volumes/SHOW/DAILIES"))
        #expect(value(text, of: "Dailies") == "2", "\(text)")
        // 180 s of proxy and 1.5 GB of it
        #expect(text.contains("3 min 00 s"), "\(text)")
        #expect(text.contains("1.5 GB"), "\(text)")
        // a line per daily, source to output
        #expect(text.contains("A001C001.mov → A001C001_proxy.mov"), "\(text)")
        #expect(text.contains("A001C002.mov → A001C002_proxy.mov"), "\(text)")
    }

    /// An entry written by a build that recorded no length is still an entry.
    /// It contributes nothing to the runtime rather than poisoning it, and its
    /// own line simply has no length on it.
    @Test func aDailyWithNoRecordedLengthStillAppears() {
        var journal = DailiesJournal()
        journal.entries = [
            entry("A", seconds: 120, size: 1_000_000_000, at: at(day: 11, hour: 22)),
            entry("B", seconds: nil, size: 500_000_000, at: at(day: 11, hour: 23)),
        ]
        let text: String = WorkReport.dailies(journal, folder: folder)
        #expect(value(text, of: "Dailies") == "2", "\(text)")
        #expect(text.contains("2 min 00 s"), "\(text)")
        #expect(text.contains("B.mov → B_proxy.mov"), "\(text)")
    }

    /// Rows go in the order the work was done, whatever order the journal
    /// happens to hold them in — a journal is appended to by a run and read
    /// back by another.
    @Test func theDailiesRowsAreInTheOrderTheWorkWasDone() {
        var journal = DailiesJournal()
        journal.entries = [
            entry("C", seconds: 10, size: 1, at: at(day: 13, hour: 2)),
            entry("A", seconds: 10, size: 1, at: at(day: 11, hour: 20)),
            entry("B", seconds: 10, size: 1, at: at(day: 12, hour: 1)),
        ]
        let text: String = WorkReport.dailies(journal, folder: folder)
        let rows: [String] = text.components(separatedBy: "\n")
            .filter { $0.contains("_proxy.mov") }
        #expect(rows.count == 3)
        #expect(rows[0].contains("A.mov"), "\(rows[0])")
        #expect(rows[2].contains("C.mov"), "\(rows[2])")
        // …and the span names the two ends of the work
        #expect(text.contains("First"))
        #expect(text.contains("Last"))
    }

    /// A folder nothing has been rendered into yet is a real report: the DIT
    /// presses export before the first pass finishes. What it must NOT do is
    /// print the epoch as the day's first item.
    @Test func anEmptyFolderIsAReportWithNoSpan() {
        let text: String = WorkReport.dailies(DailiesJournal(), folder: folder)
        #expect(value(text, of: "Dailies") == "0", "\(text)")
        #expect(!text.contains("First"), "\(text)")
        #expect(!text.contains("1970"), "\(text)")
    }

    // MARK: - the cards half

    @Test func theCardsReportTotalsWhatWasCopied() {
        let text: String = WorkReport.cards([
            card("A001", at: at(day: 11, hour: 18), files: 120,
                 verified: 120, bytes: 32_000_000_000),
            card("A002", at: at(day: 11, hour: 20), files: 80,
                 verified: 80, bytes: 16_000_000_000),
        ])
        #expect(text.hasPrefix("TakeShot — card work report\n"))
        #expect(value(text, of: "Cards") == "2", "\(text)")
        #expect(value(text, of: "Files") == "200", "\(text)")
        #expect(text.contains("48.0 GB"), "\(text)")
        #expect(value(text, of: "Verified") == "2 of 2", "\(text)")
        #expect(text.contains("/Volumes/A001"), "\(text)")
        #expect(text.contains("120 of 120 files"), "\(text)")
        #expect(text.contains("→ /Volumes/SHOW1"), "\(text)")
    }

    /// The verified tally counts RUNS that came back clean, and a run that did
    /// not is still on the page with its own word against it — a report that
    /// listed only the good runs is the one document nobody could trust.
    @Test func aRunThatDidNotVerifyIsOnThePageAndOutOfTheTally() {
        let text: String = WorkReport.cards([
            card("A001", at: at(day: 11, hour: 18)),
            card("A002", at: at(day: 11, hour: 20), verdict: "problems",
                 files: 80, verified: 74),
            card("A003", at: at(day: 11, hour: 22), verdict: "cancelled"),
        ])
        #expect(value(text, of: "Verified") == "1 of 3", "\(text)")
        #expect(text.contains("/Volumes/A002"), "\(text)")
        #expect(text.contains("74 of 80 files"), "\(text)")
        #expect(text.contains("problems"), "\(text)")
        #expect(text.contains("cancelled"), "\(text)")
    }

    /// A verdict a later build invents renders as itself rather than as a
    /// blank cell beside a card that was copied.
    @Test func anUnknownVerdictRendersAsItself() {
        let text: String = WorkReport.cards(
            [card("A001", at: at(day: 11, hour: 18), verdict: "half-eaten")])
        #expect(text.contains("half-eaten"), "\(text)")
        #expect(value(text, of: "Verified") == "0 of 1", "\(text)")
    }

    /// Two disks are named; five are counted. Five absolute paths on one row
    /// makes the column unreadable for every other row on the page.
    @Test func aRunToManyDisksIsCountedRatherThanListed() {
        let two: String = WorkReport.cards([card(
            "A001", at: at(day: 11, hour: 18),
            destinations: ["/Volumes/S1", "/Volumes/S2"])])
        #expect(two.contains("/Volumes/S1, /Volumes/S2"), "\(two)")
        let five: String = WorkReport.cards([card(
            "A001", at: at(day: 11, hour: 18),
            destinations: (1...5).map { "/Volumes/S\($0)" })])
        #expect(five.contains("5 disks"), "\(five)")
        #expect(!five.contains("/Volumes/S5"), "\(five)")
    }

    @Test func noCardsIsAReportWithNoSpan() {
        let text: String = WorkReport.cards([])
        #expect(value(text, of: "Cards") == "0", "\(text)")
        #expect(!text.contains("First"), "\(text)")
        #expect(!text.contains("1970"), "\(text)")
    }

    /// Both reports are labelled through the same value, so a cart's two
    /// documents cannot end up half translated.
    @Test func bothReportsTakeTheirWordsFromTheSameLabels() {
        var labels = WorkReportLabels()
        labels.dailiesTitle = "СМЕНА — дейлики"
        labels.cardsTitle = "СМЕНА — карты"
        labels.cards = "Карт"
        labels.verdicts = ["verified": "проверено"]
        let cards: String = WorkReport.cards(
            [card("A001", at: at(day: 11, hour: 18))], labels: labels)
        #expect(cards.hasPrefix("СМЕНА — карты\n"))
        #expect(cards.contains("Карт"), "\(cards)")
        #expect(cards.contains("проверено"), "\(cards)")
        #expect(WorkReport.dailies(DailiesJournal(), folder: folder,
                                   labels: labels)
            .hasPrefix("СМЕНА — дейлики\n"))
    }

    /// The rule under the title is as long as the title, whatever language it
    /// is in — a heading underlined halfway is the first thing anybody sees.
    @Test func theRuleUnderTheTitleFollowsTheTitle() {
        var labels = WorkReportLabels()
        labels.cardsTitle = "A much longer title in another language"
        let lines: [String] = WorkReport.cards([], labels: labels)
            .components(separatedBy: "\n")
        #expect(lines[1] == String(repeating: "=", count: lines[0].count))
    }
}
