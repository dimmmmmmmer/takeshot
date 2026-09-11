import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The header both A4 documents carry: the project, the day, the camera, the
/// take tally and the footage.
///
/// The two documents are handed over together at wrap, and their headers were
/// two copies of thirteen identical lines in two files, held together by a
/// comment saying they had to agree. Nothing had drifted; what was missing was
/// anything that could tell. The failure mode is two sheets from one wrap
/// disagreeing about how many takes there were, with no third thing to say
/// which is right.
///
/// Until now the header could only be reached by rendering a PDF and reading
/// the text back out of it, so what could be asserted was whatever survived
/// PDFKit.
@Suite @MainActor struct ModelReportSummaryTests {
    private func take(_ index: Int, rating: TakeRating = .none,
                      duration: Double = 12) -> Take {
        var take = Take(
            url: URL(fileURLWithPath: "/tmp/CLIP\(index).mov"),
            scene: "", roll: "001", takeNumber: index,
            startTimecode: Timecode(hours: 10, minutes: 0, seconds: index,
                                    frames: 0, fps: 25),
            durationSeconds: duration,
            recordedAt: Date(timeIntervalSince1970: 0))
        take.rating = rating
        return take
    }

    /// A wrap: five takes, two circled, one rejected, and 3 601 seconds of
    /// footage between them.
    private var shift: [Take] {
        [take(1, rating: .good, duration: 900),
         take(2, rating: .good, duration: 900),
         take(3, rating: .bad, duration: 900),
         take(4, duration: 900),
         take(5, duration: 1)]
    }

    private let noon = Date(timeIntervalSince1970: 1_735_732_800) // 2025-01-01

    /// The header of a day, in one language, with whatever marks are filed
    /// against its takes.
    private func header(_ takes: [Take],
                        ranges: [String: ClipRange] = [:],
                        language: AppLanguage = .english) -> ReportSummary {
        ViewRender.withLanguage(language) {
            ReportSummary.make(
                titleKey: "report_title",
                material: TakeRuntime.ReportMaterial(takes, ranges: ranges),
                project: "Film", camera: "A", date: noon)
        }
    }

    // MARK: - the two documents agree

    /// **The summary does not depend on the title.**
    ///
    /// It used to be written as "both documents carry the same summary" — the
    /// shift report and the contact sheet, which differed in their title and
    /// in nothing else. The sheet is retired, and the property it was
    /// demonstrating is the one `make` actually promises: the title is the
    /// document's own word and the sentence under it is the day's, so two
    /// titles produce one summary. Asserted with two real keys, because a
    /// summary that moved with the title would be a header that lies about
    /// the day depending on which document asked.
    @Test func theSummaryIsTheSameWhateverTheTitleIs() {
        for language in [AppLanguage.english, .russian] {
            // spelled out rather than inferred: the CI compiler is two
            // releases behind this one and resolves tuple returns out of a
            // generic closure differently (docs/ARCHITECTURE.md)
            let both: [ReportSummary] = ViewRender.withLanguage(language) {
                [ReportSummary.make(titleKey: "report_title",
                                    material: TakeRuntime.ReportMaterial(shift),
                                    project: "Film", camera: "A", date: noon),
                 ReportSummary.make(titleKey: "dailies_title",
                                    material: TakeRuntime.ReportMaterial(shift),
                                    project: "Film", camera: "A", date: noon)]
            }
            let report: ReportSummary = both[0]
            let other: ReportSummary = both[1]
            #expect(report.summary == other.summary,
                    "\(language): \(report.summary) / \(other.summary)")
            #expect(report.title != other.title)
            for title in [report.title, other.title] {
                #expect(title.hasPrefix("Film — "), "\(language): \(title)")
            }
        }
    }

    // MARK: - what the summary says

    @Test func theSummaryCountsTheTakesAndTotalsTheFootage() {
        let header = ViewRender.withLanguage(.english) {
            ReportSummary.make(titleKey: "report_title",
                               material: TakeRuntime.ReportMaterial(shift),
                               project: "Film", camera: "A", date: noon)
        }
        #expect(header.summary.contains("5 takes (2 good, 1 bad)"))
        // 900 * 4 + 1 = 3601 s, and the hours column is why this readout is
        // the wide one
        #expect(header.summary.contains("footage 1:00:01"))
        #expect(header.summary.contains("Cam A"))
    }

    /// The camera part is dropped rather than left as an empty label: a
    /// single-camera shoot has nothing to put there and "Cam" on its own is a
    /// column heading with no value.
    @Test func anUnnamedCameraLeavesNoEmptyLabel() {
        let header = ViewRender.withLanguage(.english) {
            ReportSummary.make(titleKey: "report_title",
                               material: TakeRuntime.ReportMaterial(shift),
                               project: "Film", camera: "", date: noon)
        }
        #expect(!header.summary.contains("Cam"))
    }

    /// An unnamed project still names the app rather than starting the sheet
    /// with a dash.
    @Test func anUnnamedProjectFallsBackToTheAppsName() {
        let header = ViewRender.withLanguage(.english) {
            ReportSummary.make(titleKey: "report_title",
                               material: TakeRuntime.ReportMaterial([]),
                               project: "", camera: "", date: noon)
        }
        #expect(header.title == "TakeShot — shift report")
    }

    /// The DIT hits export before the first setup. An empty day is a real
    /// document (`ModelShiftReportTests` pins that it still prints), so the
    /// header has to read as a sentence rather than divide by anything.
    @Test func anEmptyDayHasAHeaderToo() {
        let header = ViewRender.withLanguage(.english) {
            ReportSummary.make(titleKey: "report_title",
                               material: TakeRuntime.ReportMaterial([]),
                               project: "Film", camera: "A", date: noon)
        }
        #expect(header.summary.contains("0 takes (0 good, 0 bad)"))
        #expect(header.summary.contains("footage 0:00:00"))
    }

    /// The date follows the app language — a Russian shift report with an
    /// English date reads as half-translated (owner item 21). The FILE name's
    /// stamp is deliberately the opposite; see
    /// `CaptureController.reportDateStamp`.
    @Test func theDateIsWrittenInTheAppsLanguage() {
        let english = ViewRender.withLanguage(.english) {
            ReportSummary.make(titleKey: "report_title",
                               material: TakeRuntime.ReportMaterial(shift),
                               project: "Film", camera: "A", date: noon)
        }
        let russian = ViewRender.withLanguage(.russian) {
            ReportSummary.make(titleKey: "report_title",
                               material: TakeRuntime.ReportMaterial(shift),
                               project: "Film", camera: "A", date: noon)
        }
        #expect(english.summary != russian.summary)
        #expect(english.summary.contains("2025"))
        #expect(russian.summary.contains("2025"))
    }

    // MARK: - what the circled takes came to

    /// Owner: "в шифт репорте пиши еще плис по хорошим тейкам сколько хрона
    /// вышло". The day's footage is what was ROLLED; this is what was KEPT,
    /// and the two are different numbers on every day that rejects anything.
    @Test func theHeaderSaysWhatTheCircledTakesCameTo() {
        let summary: ReportSummary = header(shift)
        #expect(summary.selects.contains("2 takes"))
        #expect(summary.selects.contains("runtime 0:30:00"), "\(summary.selects)")
        // and it does NOT move the day's own total, which is still the five
        // takes that were shot
        #expect(summary.summary.contains("footage 1:00:01"))
        #expect(!summary.summary.contains("runtime"))
    }

    /// …"и чтоб если был выбран ин/аут тоже писало это". BOTH numbers, plus
    /// how many takes were trimmed: a runtime that does not add up to the rows
    /// under it, with nothing to say why, reads as an arithmetic mistake.
    @Test func anInOutOnACircledTakeIsSaidWithBothNumbers() {
        let summary: ReportSummary = header(
            shift, ranges: ["CLIP1.mov": ClipRange(inPoint: 0, outPoint: 300)])
        #expect(summary.selects.contains("runtime 0:20:00"), "\(summary.selects)")
        #expect(summary.selects.contains("in/out on 1 take"), "\(summary.selects)")
        #expect(summary.selects.contains("(0:30:00 whole)"), "\(summary.selects)")
    }

    /// A mark on a take nobody circled is review state about a take that is
    /// not going forward.
    @Test func aMarkOnARejectedTakeDoesNotReachTheHeader() {
        // CLIP3 is the rejected take of the shift
        #expect(header(shift, ranges: ["CLIP3.mov": ClipRange(inPoint: 0,
                                                              outPoint: 10)])
            == header(shift))
    }

    /// Before anyone has been through the rushes there is nothing to say, and
    /// "good: 0 takes   runtime 0:00:00" would be a row of zeros on the header
    /// of every sheet exported mid-shift.
    @Test func aDayWithNothingCircledHasNoSelectsLineAtAll() {
        #expect(header([take(1), take(2)]).selects.isEmpty)
        #expect(header([]).selects.isEmpty)
    }

    @Test func theSelectsLineSpeaksTheAppLanguage() {
        let russian: ReportSummary = header(shift, language: .russian)
        #expect(russian.selects.contains("годные"), "\(russian.selects)")
        #expect(russian.selects.contains("2 дубля"), "\(russian.selects)")
        #expect(russian.selects != header(shift).selects)
    }

    /// A take whose length came back non-finite poisons a SUM — one NaN and
    /// the whole day's footage is NaN, which the old `Int(total)` would have
    /// trapped on while drawing the sheet.
    ///
    /// It used to read 0:00:00 from there on, which is `ClipTimeText`
    /// catching the NaN at the very last step and is the wrong place to catch
    /// it: one unreadable file cost the whole day's figure, and an INFINITE
    /// length — the other shape `CMTime.seconds` produces — was not caught at
    /// all and printed tens of thousands of hours. Summed through
    /// `TakeRuntime` the damaged take costs its own length and nothing else.
    @Test func oneUnreadableLengthCostsOnlyItsOwnLength() {
        for unreadable in [Double.nan, .infinity] {
            var poisoned = shift
            poisoned[0].durationSeconds = unreadable
            let summary: ReportSummary = header(poisoned)
            // 3601 s less the 900 that can no longer be read
            #expect(summary.summary.contains("footage 0:45:01"),
                    "\(unreadable): \(summary.summary)")
            #expect(summary.summary.contains("5 takes (2 good, 1 bad)"))
            // …and the selects runtime survives it too, counting the circled
            // take that IS readable rather than answering for neither
            #expect(summary.selects.contains("runtime 0:15:00"),
                    "\(unreadable): \(summary.selects)")
        }
    }
}
