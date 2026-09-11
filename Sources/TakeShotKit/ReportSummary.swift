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
    /// **What the good takes came to** (owner: "в шифт репорте пиши еще плис
    /// по хорошим тейкам сколько хрона вышло и чтоб если был выбран ин/аут
    /// тоже писало это"), or empty when nothing is circled.
    ///
    /// A line of its own and not a fourth clause on `summary`: that line is
    /// already around 90 characters at 9pt, which is most of the 523pt between
    /// the margins, and the header draws with `.byTruncatingTail` — so a fifth
    /// clause would not overflow visibly, it would silently cut the day's
    /// footage off the end of the sheet.
    let selects: String

    /// `titleKey` is a parameter because two documents used this — the shift
    /// report and the contact sheet, which differed in their title and in
    /// nothing else. The sheet is retired; the parameter stays because the
    /// title is still the document's own word and a hard-coded one here would
    /// be a header that cannot be reused by the next document that wants it.
    ///
    /// The date is the app's language (owner item 21): a Russian shift report
    /// with an English date reads as half-translated. The FILE name's date
    /// stamp is the opposite and deliberately so — see
    /// `CaptureController.reportDateStamp`.
    static func make(titleKey: String, material: TakeRuntime.ReportMaterial,
                     project: String, camera: String,
                     date: Date = Date()) -> ReportSummary {
        let takes = material.takes
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        formatter.locale = L10n.current.documentLocale
        let good = takes.filter { $0.rating == .good }.count
        let bad = takes.filter { $0.rating == .bad }.count
        // The day's footage is the sum of the takes on THIS sheet, so a report
        // exported over a selection totals the selection. Summed by
        // `TakeRuntime`, which is also what counts the selects line below —
        // one piece of arithmetic, and one guard: a plain `reduce` poisons on
        // a take whose length came back non-finite, and `ClipTimeText` only
        // rescues NaN. An infinite one reached the paper as a day tens of
        // thousands of hours long.
        let total = TakeRuntime.footage(of: takes)
        let cameraPart = camera.isEmpty ? "" : "   \(L("report_camera", camera))"
        // The count is a PHRASE and not a number: Russian agrees the noun with
        // it and has three forms, so "1 дублей" was on the headline of every
        // shift report a single-take day produced. See `localizedCount`.
        let takeLine = L("report_takes_summary",
                         localizedCount(takes.count, .take), good, bad)
        return ReportSummary(
            title: "\(project.isEmpty ? "TakeShot" : project) — \(L(titleKey))",
            summary: "\(formatter.string(from: date))\(cameraPart)   "
                + takeLine + "   "
                + "\(L("report_footage", ClipTimeText.hoursMinutesSeconds.text(total)))",
            selects: selectsLine(material))
    }

    /// The second line: how much the circled takes came to, and whether an
    /// in/out took anything off that.
    ///
    /// Empty when nothing is circled, because a line reading "good: 0 takes
    /// runtime 0:00:00" would be a row of zeros on the header of every sheet
    /// made before anyone has been through the day's rushes.
    ///
    /// When a mark IS in play the sheet quotes BOTH numbers and says how many
    /// takes were trimmed. A single runtime with no note beside it is a number
    /// the office cannot check: the take table above adds up to the other one,
    /// and a total that does not match the rows it sits over reads as an
    /// arithmetic mistake rather than as a selection.
    private static func selectsLine(_ material: TakeRuntime.ReportMaterial) -> String {
        let runtime = TakeRuntime.selects(of: material)
        guard runtime.count > 0 else { return "" }
        let counted = localizedCount(runtime.count, .take)
        let marked = ClipTimeText.hoursMinutesSeconds.text(runtime.marked)
        guard runtime.isTrimmed else { return L("report_selects", counted, marked) }
        return L("report_selects_inout", counted, marked,
                 localizedCount(runtime.markedCount, .take),
                 ClipTimeText.hoursMinutesSeconds.text(runtime.whole))
    }
}
