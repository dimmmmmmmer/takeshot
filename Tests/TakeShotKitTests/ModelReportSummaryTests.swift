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

    // MARK: - the two documents agree

    /// The acceptance case. Everything but the title is the same sentence, in
    /// both languages — which is the claim the comment used to make and
    /// nothing checked.
    @Test func bothDocumentsCarryTheSameSummaryAndDifferOnlyInTheTitle() {
        for language in [AppLanguage.english, .russian] {
            // spelled out rather than inferred: the CI compiler is two
            // releases behind this one and resolves tuple returns out of a
            // generic closure differently (docs/ARCHITECTURE.md)
            let both: [ReportSummary] = ViewRender.withLanguage(language) {
                [ReportSummary.make(titleKey: "report_title", takes: shift,
                                    project: "Film", camera: "A", date: noon),
                 ReportSummary.make(titleKey: "contact_title", takes: shift,
                                    project: "Film", camera: "A", date: noon)]
            }
            let report: ReportSummary = both[0]
            let contact: ReportSummary = both[1]
            #expect(report.summary == contact.summary,
                    "\(language): \(report.summary) / \(contact.summary)")
            #expect(report.title != contact.title)
            for title in [report.title, contact.title] {
                #expect(title.hasPrefix("Film — "), "\(language): \(title)")
            }
        }
    }

    // MARK: - what the summary says

    @Test func theSummaryCountsTheTakesAndTotalsTheFootage() {
        let header = ViewRender.withLanguage(.english) {
            ReportSummary.make(titleKey: "report_title", takes: shift,
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
            ReportSummary.make(titleKey: "report_title", takes: shift,
                               project: "Film", camera: "", date: noon)
        }
        #expect(!header.summary.contains("Cam"))
    }

    /// An unnamed project still names the app rather than starting the sheet
    /// with a dash.
    @Test func anUnnamedProjectFallsBackToTheAppsName() {
        let header = ViewRender.withLanguage(.english) {
            ReportSummary.make(titleKey: "report_title", takes: [],
                               project: "", camera: "", date: noon)
        }
        #expect(header.title == "TakeShot — shift report")
    }

    /// The DIT hits export before the first setup. An empty day is a real
    /// document (`ModelShiftReportTests` pins that it still prints), so the
    /// header has to read as a sentence rather than divide by anything.
    @Test func anEmptyDayHasAHeaderToo() {
        let header = ViewRender.withLanguage(.english) {
            ReportSummary.make(titleKey: "report_title", takes: [],
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
            ReportSummary.make(titleKey: "report_title", takes: shift,
                               project: "Film", camera: "A", date: noon)
        }
        let russian = ViewRender.withLanguage(.russian) {
            ReportSummary.make(titleKey: "report_title", takes: shift,
                               project: "Film", camera: "A", date: noon)
        }
        #expect(english.summary != russian.summary)
        #expect(english.summary.contains("2025"))
        #expect(russian.summary.contains("2025"))
    }

    /// A take whose length came back non-finite poisons a SUM — one NaN and
    /// the whole day's footage is NaN, which the old `Int(total)` would have
    /// trapped on while drawing the sheet. `ClipTimeText` is why it reads as
    /// zero instead; the take count beside it is unaffected and still says
    /// what was shot.
    @Test func oneUnreadableLengthDoesNotTakeTheWholeSheetDown() {
        var poisoned = shift
        poisoned[0].durationSeconds = .nan
        let header = ViewRender.withLanguage(.english) {
            ReportSummary.make(titleKey: "report_title", takes: poisoned,
                               project: "Film", camera: "A", date: noon)
        }
        #expect(header.summary.contains("footage 0:00:00"))
        #expect(header.summary.contains("5 takes (2 good, 1 bad)"))
    }
}
