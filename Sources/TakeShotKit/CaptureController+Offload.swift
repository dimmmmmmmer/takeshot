import AppKit
import CaptureCore
import Foundation
import SwiftUI

/// DIT offload: one camera card copied to SEVERAL destinations in one pass,
/// verified, with a report in each.
///
/// The engine itself is in CaptureCore (`OffloadEngine`) so it can be tested
/// without a window; what lives here is the app-side glue — the sheet's state,
/// the queue the run happens on, and how a result reaches the operator.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the size
/// at which nobody reads it top to bottom any more.
extension CaptureController {
    /// The offload runs here: blocking file I/O for minutes at a time, so
    /// never on the main queue and never on the capture queue.
    nonisolated static let offloadQueue = DispatchQueue(
        label: "takeshot.offload", qos: .utility)

    /// Open the offload sheet. This is the entry point the UI calls.
    func showOffloadSheet() {
        guard claimTheDiskJob() else { return }
        verifySheetPresented = false
        offload.prepare(settings: settings, version: Self.appVersion)
        offloadSheetPresented = true
    }

    /// One disk job at a time.
    ///
    /// The offload and the verify share the offload queue and the takes panel's
    /// single status line, so a second one started over the first would run
    /// behind it while overwriting what it says about itself. The sheets alone
    /// do not prevent it: both jobs also have a menu-bar item, and the main menu
    /// stays live while a sheet is up.
    ///
    /// Says so rather than doing nothing — a menu item that silently ignores a
    /// click reads as a broken app.
    private func claimTheDiskJob() -> Bool {
        guard offload.isRunning || verify.isRunning else { return true }
        lastError = L("offload_busy")
        return false
    }

    /// What goes into the MHL manifest's `creatorinfo`. `Bundle.main` is the app
    /// bundle in the app and the test runner in the suite — hence a word rather
    /// than an invented version number as the fallback.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "dev"
    }

    /// Remember the operator's rig: the same two or three SSDs come back every
    /// day, and re-picking them through a file panel each time is the part of
    /// the old flow people complained about.
    func rememberOffloadChoices(destinations: [URL],
                                algorithm: OffloadHashAlgorithm) {
        settings.offloadDestinationPaths = destinations.isEmpty
            ? nil : destinations.map(\.path)
        settings.offloadHashAlgorithm = algorithm.rawValue
    }

    /// A finished run, as the rest of the app sees it.
    ///
    /// A clean offload is a toast. Anything else is a STICKY alarm: the card is
    /// about to be formatted on the strength of this result, and a five-second
    /// toast that scrolled past while the operator was lighting the next setup
    /// is how footage disappears.
    func offloadDidFinish(_ report: OffloadReport) {
        offloadStatus = nil
        guard !report.isFullyVerified else {
            // One destination is still the common case (a single shuttle drive),
            // and "1 copies" is not what anybody wants to read.
            lastNotice = report.destinations.count == 1
                ? L("offload_done", report.run.card.files)
                : L("offload_done_multi", report.run.card.files,
                    report.destinations.count)
            return
        }
        persistentAlert = L("offload_alert_problem",
                            report.destinations.filter { $0.outcome != .verified }
                                .count,
                            Self.offloadProblemReason(report))
    }

    /// The one line that says what went wrong, worst first.
    static func offloadProblemReason(_ report: OffloadReport) -> String {
        if let failure = report.failedDestinations.first?.failure {
            return failure
        }
        if let mismatch = report.destinations
            .lazy.compactMap({ $0.mismatches.first }).first {
            return mismatch
        }
        if let source = report.run.problems.source.first { return source }
        if let scan = report.run.problems.scan.first { return scan }
        return L("offload_result_cancelled", report.filesProcessed,
                 report.run.card.files)
    }

    // MARK: - checking a disk that was offloaded earlier

    /// Ask for the disk and start checking it against the manifest on it.
    ///
    /// The other half of what the offload promises. The offload verifies every
    /// file as it lands; this answers the same question weeks later, when the
    /// SSD comes back from post or out of a case in a van, without `ascmhl` or
    /// Silverstack having to be on the set machine.
    func chooseDiskToVerify() {
        // Before the panel, not after it: being told the app is busy having
        // already browsed to the disk is the annoying half of the same answer.
        guard claimTheDiskJob() else { return }
        guard let url = OffloadPanels.pickFolder(
            message: L("verify_pick_disk"), prompt: L("verify_disk_prompt"))
        else { return }
        startVerify(at: url)
    }

    /// The half of that flow a test can drive: the panel has answered, the sheet
    /// goes up and the pass starts. There is nothing to fill in between the two
    /// — every parameter of a verify, the checksum included, comes out of the
    /// manifest already on the disk.
    func startVerify(at url: URL) {
        guard claimTheDiskJob() else { return }
        offloadSheetPresented = false
        verifySheetPresented = true
        verify.begin(url)
    }

    /// A finished pass, as the rest of the app sees it.
    ///
    /// Same rule as the offload: intact is a toast, damaged is a STICKY alarm.
    /// This one is read before a disk is shipped or a backup is retired, and a
    /// five-second toast that scrolled past is how the last copy gets deleted.
    ///
    /// A pass the operator stopped is neither. Nothing is known to be wrong, so
    /// an alarm would be a false one — and false alarms are how real ones stop
    /// being read — but "verified" over a disk that was half read is the one lie
    /// this tool must never tell, so it says where it got to instead.
    func verifyDidFinish(_ report: OffloadVerifyReport) {
        offloadStatus = nil
        guard !report.wasCancelled else {
            lastNotice = L("verify_result_cancelled", report.verified.count,
                           report.filesListed)
            return
        }
        guard report.isIntact else {
            persistentAlert = L("verify_alert_problem",
                                report.mismatched.count + report.missing.count,
                                report.filesListed,
                                Self.verifyProblemReason(report))
            return
        }
        // Strays are reported and do not downgrade the verdict: every file the
        // manifest covers is exactly what it says it is, and a tool that refuses
        // to say so until somebody clears a .DS_Store teaches its operator to
        // stop reading it.
        lastNotice = report.extra.isEmpty
            ? L("verify_done", report.verified.count)
            : L("verify_done_strays", report.verified.count, report.extra.count)
    }

    /// The one file the alarm names, worst first: something that is there and
    /// WRONG before something that is simply gone. The first is a disk going
    /// bad, which threatens every file around it too.
    static func verifyProblemReason(_ report: OffloadVerifyReport) -> String {
        if let fault = report.mismatched.first {
            return "\(fault.relativePath) (\(fault.reason))"
        }
        return report.missing.first ?? report.root.lastPathComponent
    }

    /// The folder could not be checked at all.
    ///
    /// An error toast, not the sticky alarm: the alarm means footage is at risk,
    /// and a folder nothing ever offloaded to is not footage at risk — it is the
    /// wrong folder, which is the mistake an operator makes first.
    func verifyDidFail(_ message: String) {
        offloadStatus = nil
        lastError = message
    }

    /// Why a folder could not be checked, in the operator's language.
    ///
    /// "No manifest here" gets its own sentence because it is both the common
    /// case and the one an operator can act on immediately. The rest are rare
    /// and technical, and CaptureCore already states them in English — dressing
    /// those up in a translated wrapper would hide the only part that says what
    /// actually happened.
    static func verifyFailureMessage(_ error: Error, at url: URL?) -> String {
        if let verify = error as? OffloadVerifyError, case .noManifest = verify {
            return L("verify_error_no_manifest",
                     url?.lastPathComponent ?? "")
        }
        return L("verify_error", error.localizedDescription)
    }
}
