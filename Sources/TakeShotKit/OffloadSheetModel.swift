import CaptureCore
import Foundation

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

    /// The checksum every run uses.
    ///
    /// A constant, not a setting. The picker that used to be on the sheet asked
    /// the operator a question they cannot answer on set — xxHash64 is what
    /// every DIT tool (Silverstack, OffShoot, ascmhl) verifies against, and
    /// SHA-256 is several times slower for a guarantee nobody downstream asked
    /// for. The ENGINE stays capable of both, and a manifest written in either
    /// still verifies (see `OffloadManifestReader`); what went is the question.
    static let algorithm: OffloadHashAlgorithm = .xxh64

    @Published var source: URL?
    @Published var rows: [Row] = []
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
        guard rows.isEmpty else { return }
        // The operator's saved destination list. The folder the retired verified
        // backup used to hold is in it too — `CaptureSettings.migrateToVersion2`
        // moves it there on load, so nobody loses a path they had chosen.
        let saved = settings.offloadDestinationPaths ?? []
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

    /// What "show it in the Finder" opens for a row (owner item 23): the copy's
    /// own folder once it exists, and the disk the operator chose before that.
    ///
    /// A run that has not started has no card folder yet, and a button that
    /// does nothing until the copy is under way is one the operator stops
    /// trying. During and after the run it opens the copy itself, which is
    /// what they are actually asking to look at.
    func finderTarget(for row: Row) -> URL {
        guard let folder = destinationFolder(for: row),
              FileManager.default.fileExists(atPath: folder.path)
        else { return row.url }
        return folder
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
        // The report labels are read here, once, in the operator's current UI
        // language: the summary and the card of THIS run speak one language
        // even if the switch is flipped while it copies (owner item 21).
        let plan = OffloadPlan(source: source, destinations: destinationFolders,
                               algorithm: Self.algorithm, creator: creator,
                               reportLabels: .current())
        let token = OffloadCancellation()
        cancellation = token
        isRunning = true
        isCancelling = false
        progress = nil
        report = nil
        controller?.rememberOffloadChoices(destinations: destinations)
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
