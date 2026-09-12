import CaptureCore
import Foundation

/// **What the cart did, as a document that leaves with it** (owner: "плюс
/// хотелось бы иметь возможность отгружать отчеты проделанной работы по
/// дейликам и по слитым карточкам").
///
/// Beside the shift report rather than inside it, because they answer for
/// different things: that one is the day's TAKES and is the camera
/// department's paperwork; these two are the cart's own work — what was
/// copied off the cards and what was rendered out as dailies — and the person
/// who asks for them is the one signing the day off.
///
/// The documents themselves are `WorkReport`, in CaptureCore and localization
/// free; what is decided here is where the words come from, what the file is
/// offered as, and which record each report is built out of.
extension CaptureController {
    /// The dailies rendered into `folder`, from that folder's own journal.
    ///
    /// The JOURNAL and not the folder's contents, which is the same decision
    /// `DailiesVerify` states: a folder also holds whatever else somebody put
    /// in it, and a report that walked the directory would count an operator's
    /// own copy of a reference clip as a daily this cart made.
    func exportDailiesWorkReport(for folder: URL) {
        let journal = DailiesProgressJournal.read(in: folder)
        let name = NamingEngine.sanitize(
            "\(settings.naming.projectName)_dailies_\(Self.reportDateStamp())")
            + ".txt"
        write(WorkReport.dailies(journal, folder: folder,
                                 labels: .current()),
              named: name, in: folder)
    }

    /// The cards offloaded, from the app's own history.
    ///
    /// That history is capped at twenty runs, and the report says what it was
    /// built from by listing every row it has: this is a summary of what the
    /// app remembers, and the receipts on the destination disks are the record
    /// it cannot replace. Offered at the end of a day, which is well inside
    /// the window.
    func exportCardWorkReport() {
        let cards = offloadHistory.runs.map {
            WorkReport.Card(date: $0.date, source: $0.sourcePath,
                            destinations: $0.destinationPaths,
                            verdict: $0.verdict.rawValue, files: $0.files,
                            filesVerified: $0.filesVerified, bytes: $0.bytes)
        }
        let name = NamingEngine.sanitize(
            "\(settings.naming.projectName)_cards_\(Self.reportDateStamp())")
            + ".txt"
        write(WorkReport.cards(cards, labels: .current()), named: name,
              in: destinationRoot)
    }

    /// The half both share: a save panel, a write, and one toast either way.
    private func write(_ text: String, named name: String, in folder: URL?) {
        guard let url = FilePanel.save(named: name, in: folder) else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastNotice = L("work_report_saved", url.lastPathComponent)
        } catch {
            lastError = L("toast_work_report_failed", error.localizedDescription)
        }
    }
}
