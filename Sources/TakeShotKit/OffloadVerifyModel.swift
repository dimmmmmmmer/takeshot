import CaptureCore
import Foundation

/// State of the "verify disk against MHL" sheet, and the pass it drives.
///
/// The same shape as `OffloadSheetModel` and for the same reasons: owned by the
/// controller so a pass outlives any render of the sheet, and the file panel
/// lives in the view rather than here so everything the model does stays
/// reachable from a test.
///
/// Where it differs is that there is nothing to configure. An offload is a plan
/// — a card, a list of destinations, a checksum. A verify is a question about
/// one folder, and every parameter of it comes out of the manifest already on
/// that folder, including which hash to use. So the sheet opens with the folder
/// already picked and the pass already running.
@MainActor
final class OffloadVerifyModel: ObservableObject {
    /// The folder being checked; nil before the operator has picked one.
    @Published var root: URL?
    /// Live state of the pass; nil when nothing is running.
    @Published var progress: OffloadVerifyProgress?
    /// The last finished pass. Set by a run, and by the view-render tests, which
    /// have to be able to draw every result state without a disk.
    @Published var report: OffloadVerifyReport?
    /// Why the folder could not be checked at all — no manifest, or one that
    /// will not parse. Distinct from a report saying the disk is damaged: this
    /// one means nothing was checked.
    @Published var failure: String?
    @Published var isRunning = false
    /// Stop has been pressed: the file in flight finishes, then the pass stops.
    @Published var isCancelling = false

    private var cancellation: OffloadCancellation?
    private weak var controller: CaptureController?

    /// Wired once, in startup, rather than when the sheet opens — a pass reports
    /// through the controller, and a model that only got its controller on the
    /// way through the UI would run silently if it were ever started otherwise.
    func attach(to controller: CaptureController) {
        self.controller = controller
    }

    /// Point the sheet at a folder and start. One call because there is nothing
    /// to fill in between the two — the operator picked the disk in the panel,
    /// and waiting for a second click on Start would only be a chance to pick
    /// wrong twice.
    func begin(_ url: URL) {
        guard !isRunning else { return }
        root = url
        progress = nil
        report = nil
        failure = nil
        isCancelling = false
        isRunning = true
        controller?.offloadStatus = L("verify_scanning")
        let token = OffloadCancellation()
        cancellation = token
        CaptureController.offloadQueue.async { [weak self] in
            // Named rather than trailing: the call can end two ways, so the
            // `do` has to wrap it, and a multi-line closure hanging off the end
            // of a three-argument call inside a `do` inside a dispatch block is
            // four levels of brace before anything happens.
            let publish: @Sendable (OffloadVerifyProgress) -> Void = { snapshot in
                DispatchQueue.main.async { self?.apply(snapshot) }
            }
            do {
                let result = try OffloadVerify.run(root: url,
                                                   cancellation: token,
                                                   progress: publish)
                DispatchQueue.main.async { self?.finish(result) }
            } catch {
                DispatchQueue.main.async { self?.fail(error) }
            }
        }
    }

    /// Safe stop: the flag is read between files, so the pass always ends having
    /// finished whatever it was reading.
    func cancel() {
        guard isRunning else { return }
        cancellation?.cancel()
        isCancelling = true
        controller?.offloadStatus = L("verify_cancelling")
    }

    private func apply(_ snapshot: OffloadVerifyProgress) {
        guard isRunning else { return }
        progress = snapshot
        guard !isCancelling else { return }
        controller?.offloadStatus = L("verify_progress", snapshot.filesDone,
                                      snapshot.filesTotal)
    }

    private func finish(_ result: OffloadVerifyReport) {
        stop()
        report = result
        controller?.verifyDidFinish(result)
    }

    /// The folder could not be checked. The sentence is built once and used
    /// twice — the sheet keeps showing it after the toast has gone.
    private func fail(_ error: Error) {
        stop()
        let message = CaptureController.verifyFailureMessage(error, at: root)
        failure = message
        controller?.verifyDidFail(message)
    }

    private func stop() {
        isRunning = false
        isCancelling = false
        progress = nil
        cancellation = nil
    }
}
