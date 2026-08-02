import CaptureCore
import Foundation

/// Dailies with burn-ins: the day's takes (or the selected ones) transcoded
/// to small H.264 review files with timecode and identity burned in.
///
/// The engine lives in CaptureCore (`DailiesEngine`) so it is testable without
/// a window; what lives here is the app-side glue — how the sheet gets its
/// batch, how the recording state reaches the queue, and how a result reaches
/// the operator. Split into its own file like every controller domain.
extension CaptureController {
    /// Open the dailies sheet — the "Dailies…" entry in the takes-panel
    /// export menu. A running queue is not a busy signal; reopening the sheet
    /// is how the operator looks at it (the offload sheet's rule).
    func showDailiesSheet() {
        if !dailies.isRunning {
            dailies.prepare(takes: dailiesCandidates, settings: settings,
                            defaultFolder: defaultDailiesFolder)
        }
        dailiesSheetPresented = true
    }

    /// What the sheet offers to queue: the takes selected in the panel, in
    /// take order — or the whole day when nothing is selected. Other content
    /// never qualifies: a foreign file has no take metadata to burn in.
    var dailiesCandidates: [Take] {
        let selected = takes.filter { selectedItems.contains($0.url) }
        return selected.isEmpty ? takes : selected
    }

    /// A Dailies folder beside the takes: the deliverable stays with the
    /// day's footage unless the operator points it elsewhere.
    var defaultDailiesFolder: URL {
        destinationRoot.appendingPathComponent("Dailies")
    }

    /// The operator's burn-in convention survives the relaunch, like the
    /// offload rig does. Written on Start, not on every toggle — a half-set
    /// sheet that was never run is not a convention.
    func rememberDailiesChoices(from model: DailiesQueueModel) {
        settings.dailiesBurnTimecode = model.burnTimecode
        settings.dailiesBurnClipName = model.burnClipName
        settings.dailiesBurnProject = model.burnProject
        settings.dailiesBurnDate = model.burnDate
        let custom = model.customText.trimmingCharacters(in: .whitespaces)
        settings.dailiesCustomText = custom.isEmpty ? nil : custom
        settings.dailiesDestinationPath = model.destination?.path
    }

    /// A finished run, as the rest of the app sees it.
    ///
    /// A clean run is a toast; failures are an error toast, NOT the sticky
    /// alarm — the alarm means footage is at risk, and a daily that failed to
    /// encode left every source take exactly where it was. The detail stays
    /// on the sheet's result panel.
    func dailiesDidFinish(_ report: DailiesReport) {
        dailiesStatus = nil
        if report.wasCancelled {
            lastNotice = L("dailies_cancelled", report.completed.count,
                           report.items.count)
        } else if report.isFullySucceeded {
            lastNotice = L("dailies_done", report.completed.count)
        } else {
            lastError = L("dailies_failed", report.failed.count,
                          report.failed.first?.failure ?? "")
        }
    }
}
