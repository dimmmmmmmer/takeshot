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

    /// The takes panel's export menu still calls this name; the footer reorg
    /// moves to `showOffloadSheet`. Kept as a forwarder so neither has to land
    /// at the same moment as the other.
    func offloadFolder() {
        showOffloadSheet()
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

/// State of the offload sheet, and the run it drives.
///
/// Owned by the controller rather than by the view: the run outlives any
/// particular render of the sheet, and the takes-panel status line reads from it
/// too. Panels (`NSOpenPanel`) deliberately do NOT live here — that keeps the
/// whole engine-facing side of the sheet reachable from a test.
@MainActor
final class OffloadSheetModel: ObservableObject {
    /// One destination row. Its identity is its own, not its URL's: while the
    /// operator is still picking, two rows can legitimately hold the same
    /// folder, and a URL-keyed list would collapse them.
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var url: URL
    }

    @Published var source: URL?
    @Published var rows: [Row] = []
    @Published var algorithm: OffloadHashAlgorithm = .xxh64
    /// Live state of the run; nil when nothing is running.
    @Published var progress: OffloadProgress?
    /// The last finished run. Set by the run, and by the view-render tests,
    /// which have to be able to draw every result state without a disk.
    @Published var report: OffloadReport?
    @Published var isRunning = false
    /// Cancel has been pressed: the file in flight finishes, then the run stops.
    @Published var isCancelling = false

    /// Stamped into every manifest.
    var creator: OffloadCreatorInfo = .current()
    private var cancellation: OffloadCancellation?
    private weak var controller: CaptureController?

    var destinations: [URL] { rows.map(\.url) }

    /// Wired once, in `CaptureController.init`, rather than when the sheet
    /// opens: a run reports through the controller (status line, toast, sticky
    /// alarm), and a model that only got its controller on the way through the
    /// UI would run perfectly silently if it were ever started another way.
    func attach(to controller: CaptureController) {
        self.controller = controller
    }

    /// Seed from the operator's saved rig and clear the previous run's result —
    /// a stale "verified" card on top of a sheet opened for the next card is a
    /// dangerous thing to leave lying around.
    func prepare(settings: CaptureSettings, version: String) {
        creator = .current(version: version)
        if !isRunning {
            progress = nil
            report = nil
            isCancelling = false
        }
        if let stored = settings.offloadHashAlgorithm,
           let known = OffloadHashAlgorithm(rawValue: stored) {
            algorithm = known
        }
        guard rows.isEmpty else { return }
        // The operator's saved destination list; failing that, the folder the
        // old two-panel flow used to leave in `backupPath`, so nobody loses a
        // path they had already chosen.
        let saved = settings.offloadDestinationPaths
            ?? settings.backupPath.map { [$0] } ?? []
        rows = saved.map { Row(url: URL(fileURLWithPath: $0)) }
    }

    // MARK: - editing the list

    func addDestination(_ url: URL) {
        rows.append(Row(url: url))
    }

    func setDestination(_ url: URL, at id: Row.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].url = url
    }

    func removeDestination(_ id: Row.ID) {
        rows.removeAll { $0.id == id }
    }

    /// Where a row's copy actually lands: the card's own folder name, created
    /// inside the chosen destination. Three SSDs then hold three folders named
    /// after the card rather than three loose DCIM trees.
    func destinationFolder(for row: Row) -> URL? {
        guard let source else { return nil }
        return row.url.appendingPathComponent(source.lastPathComponent)
    }

    var destinationFolders: [URL] {
        rows.compactMap { destinationFolder(for: $0) }
    }

    // MARK: - validation

    /// Why the run cannot start, in the operator's language. nil means either
    /// "ready" or "nothing chosen yet" — the button's own disabled state covers
    /// the second case without shouting about it.
    var validationMessage: String? {
        let folders = destinationFolders
        if Set(folders.map(\.standardizedFileURL.path)).count != folders.count {
            return L("offload_error_duplicate")
        }
        guard let source = source?.standardizedFileURL else { return nil }
        for folder in folders.map(\.standardizedFileURL)
        where folder == source || folder.path.hasPrefix(source.path + "/") {
            // Copying a tree into itself grows forever and can never verify.
            return L("offload_error_nested")
        }
        return nil
    }

    var canStart: Bool {
        !isRunning && source != nil && !rows.isEmpty && validationMessage == nil
    }

    // MARK: - the run

    func start() {
        guard let source, canStart else { return }
        let plan = OffloadPlan(source: source, destinations: destinationFolders,
                               algorithm: algorithm, creator: creator)
        let token = OffloadCancellation()
        cancellation = token
        isRunning = true
        isCancelling = false
        progress = nil
        report = nil
        controller?.rememberOffloadChoices(destinations: destinations,
                                           algorithm: algorithm)
        controller?.offloadStatus = L("offload_scanning")
        CaptureController.offloadQueue.async { [weak self] in
            let result = OffloadEngine.run(plan, cancellation: token) { snapshot in
                DispatchQueue.main.async { self?.apply(snapshot) }
            }
            DispatchQueue.main.async { self?.finish(result) }
        }
    }

    /// Safe cancel: the flag is read between files, so what is on the
    /// destination is always a whole file, and the summary records where it
    /// stopped.
    func cancel() {
        guard isRunning else { return }
        cancellation?.cancel()
        isCancelling = true
        controller?.offloadStatus = L("offload_cancelling")
    }

    private func apply(_ snapshot: OffloadProgress) {
        guard isRunning else { return }
        progress = snapshot
        guard !isCancelling else { return }
        let done = snapshot.destinations.map(\.filesDone).max() ?? 0
        controller?.offloadStatus = L("offload_progress", done,
                                      snapshot.filesTotal)
    }

    private func finish(_ result: OffloadReport) {
        isRunning = false
        isCancelling = false
        progress = nil
        report = result
        cancellation = nil
        controller?.offloadDidFinish(result)
    }
}
