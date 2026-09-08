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

    // MARK: - what the sheet's controls are enabled by
    //
    // Every one of these is a rule the sheet used to spell out per button. They
    // are stated here, once, in the extension that owns the queue — see
    // `ViewDisabledRuleTests` for why that is enforced rather than encouraged.

    /// A queue is going: everything that would change what it is doing is
    /// locked (the burn-ins, the destination).
    var isDailiesRunning: Bool { dailies.isRunning }

    /// Start: nothing running, something to encode, somewhere to put it.
    var canStartDailies: Bool { dailies.canStart }

    /// The two controls that steer a run in flight — the footer's Stop and the
    /// progress panel's Skip. One rule: it is running, and it is not already
    /// stopping.
    var canSteerDailiesQueue: Bool {
        dailies.isRunning && !dailies.isCancelling
    }

    /// Whether the destination is pointed somewhere other than the folder
    /// beside the footage — which is the only state the minus button has
    /// anything to undo. Named here so the sheet asks it rather than spelling
    /// it out (see `ViewDisabledRuleTests`).
    var canClearDailiesDestination: Bool {
        !dailies.isRunning && !dailies.isDestinationDefault
    }

    /// Whether there is an override at all — the question the way-back button
    /// asks to decide whether to exist. Separate from
    /// `canClearDailiesDestination`, which also refuses while a run is going:
    /// the button is SHOWN whenever there is something to undo and DISABLED
    /// while the queue is busy, so it greys instead of vanishing mid-run.
    var hasDailiesDestinationOverride: Bool {
        !dailies.isDestinationDefault
    }

    /// Put the destination back to the Dailies folder beside the footage.
    ///
    /// Written through on the spot rather than at the next Start, and that is
    /// the half that was actually missing: `destinationPath` had no writer that
    /// could produce nil, so the first run pinned the deliverable to one
    /// absolute path for good. The record folder is re-pointed between shooting
    /// days; a pinned dailies folder then keeps sending the next show's review
    /// files to the last show's disk.
    func clearDailiesDestination() {
        guard canClearDailiesDestination else { return }
        settings.dailies.destinationPath = nil
        dailies.destination = defaultDailiesFolder
    }

    /// The operator's burn-in convention survives the relaunch, like the
    /// offload rig does. Written on Start, not on every toggle — a half-set
    /// sheet that was never run is not a convention.
    ///
    /// The destination is stored only while it IS an override: a run into the
    /// default folder writes nil, so Start cannot re-pin what the minus just
    /// cleared, and the folder goes on following the record folder.
    func rememberDailiesChoices(from model: DailiesQueueModel) {
        settings.dailies.burnTimecode = model.burnTimecode
        settings.dailies.burnClipName = model.burnClipName
        settings.dailies.burnProject = model.burnProject
        settings.dailies.burnDate = model.burnDate
        settings.dailies.burnCustom = model.burnCustom
        // The TEXT is stored whether the line is on or not. It used to be
        // stored only when non-empty, which was the same statement back when
        // emptiness WAS the off switch — with a real switch beside it, that
        // spelling deletes the operator's sentence every time they untick the
        // box, and there is nothing to put back when they tick it again.
        let custom = model.customText.trimmingCharacters(in: .whitespaces)
        settings.dailies.customText = custom.isEmpty ? nil : custom
        // nil at the classic arrangement, like every other added field: a
        // settings blob written by an older build still decodes, and one
        // written here does not carry four strings nobody changed.
        settings.dailies.timecodePosition = model.timecodePosition == .topCenter
            ? nil : model.timecodePosition.rawValue
        settings.dailies.clipNamePosition = model.clipNamePosition == .bottomLeft
            ? nil : model.clipNamePosition.rawValue
        settings.dailies.projectPosition = model.projectPosition == .bottomRight
            ? nil : model.projectPosition.rawValue
        settings.dailies.customPosition = model.customPosition == .topLeft
            ? nil : model.customPosition.rawValue
        settings.dailies.datePosition = model.datePosition == .bottomRight
            ? nil : model.datePosition.rawValue
        settings.dailies.codec = model.codec == .h264 ? nil : model.codec.rawValue
        settings.dailies.namePrefix = model.namePrefix.isEmpty
            ? nil : model.namePrefix
        settings.dailies.nameSuffix = model.nameSuffix == "_DAILY"
            ? nil : model.nameSuffix
        settings.dailies.destinationPath = model.isDestinationDefault
            ? nil : model.destination?.path
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
            lastNotice = L("dailies_done",
                           localizedCount(report.completed.count, .file))
        } else {
            lastError = L("dailies_failed", report.failed.count,
                          report.failed.first?.failure ?? "")
        }
    }
}
