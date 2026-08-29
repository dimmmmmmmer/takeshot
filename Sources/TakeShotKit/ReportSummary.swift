import CaptureCore
import Foundation

/// The two lines at the top of the two A4 documents that leave set: the shift
/// report and the contact sheet.
///
/// # Why this is one place and was two copies
///
/// `ContactSheet.drawHeader` carried the comment "the shift report's header,
/// word for word except the title — the two documents leave set together and
/// have to read as one family", and then thirteen lines identical to
/// `ShiftReport.drawHeader`'s: the same date formatter, the same good/bad
/// tally, the same total-footage clock, the same optional camera part, the
/// same three-part sentence. A contract stated in a comment, held by nobody,
/// with the two halves in different files.
///
/// Nothing had drifted yet, which is the reason to do this now rather than the
/// reason not to: the header is the piece of paper's identity — the day, the
/// project, the camera, and how much was shot — and the two documents are
/// handed over together. The failure mode of a divergence is two sheets from
/// the same wrap that disagree about how many takes there were, with no third
/// thing to say which is right.
///
/// Testable for the first time as a consequence: the header was only reachable
/// by rendering a PDF and reading the text back out of it, so what could be
/// asserted about it was whatever survived PDFKit's extraction.
struct ReportSummary: Equatable {
    /// "Film — SHIFT REPORT", or "TakeShot — …" when the project is unnamed.
    let title: String
    /// The date, the camera when there is one, the take tally and the day's
    /// footage, in that order and separated by wide gaps.
    let summary: String

    /// `titleKey` is the only thing the two documents do not share.
    ///
    /// The date is the app's language (owner item 21): a Russian shift report
    /// with an English date reads as half-translated. The FILE name's date
    /// stamp is the opposite and deliberately so — see
    /// `CaptureController.reportDateStamp`.
    static func make(titleKey: String, takes: [Take], project: String,
                     camera: String, date: Date = Date()) -> ReportSummary {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        formatter.locale = L10n.current.documentLocale
        let good = takes.filter { $0.rating == .good }.count
        let bad = takes.filter { $0.rating == .bad }.count
        // The day's footage is the sum of the takes on THIS sheet, so a report
        // exported over a selection totals the selection. `ClipTimeText`
        // rather than a third spelling of hours-minutes-seconds: it is also
        // the only one of the three that survives a take whose duration came
        // back non-finite, and a sum poisons on one such take.
        let total = takes.reduce(0.0) { $0 + $1.durationSeconds }
        let cameraPart = camera.isEmpty ? "" : "   \(L("report_camera", camera))"
        return ReportSummary(
            title: "\(project.isEmpty ? "TakeShot" : project) — \(L(titleKey))",
            summary: "\(formatter.string(from: date))\(cameraPart)   "
                + "\(L("report_takes_summary", takes.count, good, bad))   "
                + "\(L("report_footage", ClipTimeText.hoursMinutesSeconds.text(total)))")
    }
}
