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
        offload.prepare(settings: settings, version: Self.appVersion)
        offloadSheetPresented = true
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
                ? L("offload_done", report.filesTotal)
                : L("offload_done_multi", report.filesTotal,
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
        if let source = report.sourceFailures.first { return source }
        if let scan = report.scanFailures.first { return scan }
        return L("offload_result_cancelled", report.filesProcessed,
                 report.filesTotal)
    }
}
