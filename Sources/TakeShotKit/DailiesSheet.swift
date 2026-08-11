import AppKit
import CaptureCore
import SwiftUI

/// The dailies sheet: the batch, the burn-in switches, one destination, Start.
///
/// Set in the offload sheets' type family (`offloadText`/`OffloadChrome`) on
/// purpose — the two sheets are siblings in the same corner of the app, and a
/// second type zoo is how the first one grew. Like the offload sheet it can be
/// closed over a running queue; the takes-panel strip reports on the run while
/// the sheet is away (see `DailiesStatusStrip`).
struct DailiesSheet: View {
    @ObservedObject var model: DailiesQueueModel
    /// Read for the enabling rules alone — each of them is named once on the
    /// controller (`isDailiesRunning`, `canStartDailies`, `canSteerDailiesQueue`,
    /// `canClearDailiesDestination`) rather than spelled out per button here.
    /// The model is still observed, which is what makes the re-read fresh.
    @EnvironmentObject private var controller: CaptureController
    @Environment(\.dismiss) private var dismiss

    /// Narrower than the offload sheet: one destination and five switches,
    /// not a destination list with verdict cards.
    static let width: CGFloat = 470

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { content.padding(20) }
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: Self.width)
    }

    /// The sheet without its fixed frame — what the render tests measure
    /// (a pinned frame reports the pin, not what the content needed).
    @ViewBuilder var content: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.sectionSpacing) {
            Text(L("dailies_title"))
                .offloadText(.title)
            Text(L("dailies_batch", model.queuedTakes.count))
                .offloadText(.caption)
            burninSection
            Divider()
            destinationSection
            if let progress = model.progress {
                Divider()
                DailiesProgressPanel(progress: progress,
                                     onSkip: { model.skipCurrentItem() })
            }
            if let report = model.report {
                Divider()
                DailiesResultPanel(report: report)
            }
        }
    }

    // MARK: - burn-ins

    private var burninSection: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            Text(L("dailies_burn_section"))
                .offloadText(.section)
            Toggle(L("dailies_burn_tc"), isOn: $model.burnTimecode)
            Toggle(L("dailies_burn_name"), isOn: $model.burnClipName)
            Toggle(L("dailies_burn_project"), isOn: $model.burnProject)
            Toggle(L("dailies_burn_date"), isOn: $model.burnDate)
            TextField(L("dailies_custom_placeholder"), text: $model.customText)
                .textFieldStyle(.roundedBorder)
        }
        .toggleStyle(.checkbox)
        .disabled(controller.isDailiesRunning)
    }

    // MARK: - destination

    /// One destination, and now both of the controls the offload sheet's
    /// destination rows have: Choose, and the minus that puts it back.
    ///
    /// The minus is not decoration. Without it the default — a Dailies folder
    /// beside the day's footage — was reachable exactly once, before the first
    /// run: `destinationPath` had no writer that could produce nil, so one
    /// choice pinned the deliverable to one absolute path for every show after
    /// it. Greyed while the default is already in force, so it says whether
    /// there is an override at all.
    private var destinationSection: some View {
        HStack(spacing: 10) {
            Text(L("dailies_dest_label"))
                .offloadText(.body)
                .fixedSize()
            Text(model.destination?.path ?? "")
                .offloadText(.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("choose")) {
                if let url = OffloadPanels.pickFolder(
                    message: L("dailies_pick_dest"),
                    prompt: L("offload_dest_prompt")) {
                    model.destination = url
                }
            }
            .disabled(controller.isDailiesRunning)
            Button {
                controller.clearDailiesDestination()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!controller.canClearDailiesDestination)
            .help(L("dailies_reset_dest"))
        }
    }

    // MARK: - footer

    /// Close stays live over a running queue and says so — the run continues
    /// and the takes panel reports on it (the offload sheet's contract).
    private var footer: some View {
        HStack {
            if model.isRunning {
                Button(L("dailies_stop")) { model.cancel() }
                    .disabled(!controller.canSteerDailiesQueue)
            }
            Spacer()
            Button(model.isRunning ? L("offload_hide") : L("close")) {
                dismiss()
            }
            Button(L("dailies_start")) { model.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canStartDailies)
        }
    }
}

/// The item in flight: which take, how far through it, and the two things a
/// visible run must offer — Skip and (in the footer) Stop. The bar is always
/// a bar, never a spinner, for the status strip's reason: a control that
/// changes shape makes everything under it jump.
struct DailiesProgressPanel: View {
    let progress: DailiesProgress
    /// Skip and the footer's Stop are one rule — "the queue is running and not
    /// already stopping" — so both ask `canSteerDailiesQueue` rather than each
    /// carrying its own copy of it. This panel used to be handed the flag as a
    /// value, which is how one rule becomes two spellings.
    @EnvironmentObject private var controller: CaptureController
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            HStack(spacing: 6) {
                Text(L("dailies_status", min(progress.itemIndex + 1,
                                             progress.itemCount),
                       progress.itemCount))
                    .offloadText(.section)
                if progress.isPaused {
                    // Why the bar is standing still, right next to it.
                    Label(L("dailies_paused_rec"), systemImage: "pause.circle")
                        .offloadText(.caption, tint: .orange)
                }
                Spacer(minLength: 2)
                Button(L("dailies_skip"), action: onSkip)
                    .disabled(!controller.canSteerDailiesQueue)
            }
            ProgressView(value: Double(progress.framesDone),
                         total: Double(max(1, progress.framesTotal)))
            HStack {
                Text(progress.currentFile)
                    .offloadText(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                Text(L("dailies_frames", progress.framesDone,
                       progress.framesTotal))
                    .offloadText(.caption)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
    }
}

/// The finished run: one line per outcome kind, failures named. Compact on
/// purpose — a dailies batch is routine, and the toast already carried the
/// verdict; this panel is for the one question a failure raises: which take.
struct DailiesResultPanel: View {
    let report: DailiesReport

    var body: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.tightSpacing) {
            Text(L("dailies_result_done", report.completed.count,
                   report.items.count))
                .offloadText(.section,
                             tint: report.isFullySucceeded ? .green : nil)
            ForEach(report.failed, id: \.source) { item in
                Label("\(item.source.lastPathComponent) — \(item.failure ?? "")",
                      systemImage: "exclamationmark.triangle.fill")
                    .offloadText(.caption, tint: .orange)
                    .lineLimit(2)
            }
            if report.wasCancelled {
                Text(L("dailies_result_cancelled"))
                    .offloadText(.caption)
            }
        }
    }
}
