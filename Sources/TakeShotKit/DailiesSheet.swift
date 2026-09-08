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
            Text(L("dailies_batch",
                   localizedCount(model.queuedTakes.count, .take)))
                .offloadText(.caption)
            DailiesBurninSection(model: model)
            Divider()
            DailiesDestinationRow(model: model)
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

    // MARK: - footer

    /// Close stays live over a running queue and says so — the run continues
    /// and the takes panel reports on it (the offload sheet's contract).
    private var footer: some View {
        DailiesSheetFooter(model: model) { dismiss() }
    }
}

/// The burn-in switches.
///
/// A view of its own rather than a property of the sheet, and the reason is the
/// same one `OffloadSheetFooter` states: it reads the enabling rule off the
/// controller, and an `@EnvironmentObject` is only bound when SwiftUI evaluates
/// the view — a property the render tests ask for directly is evaluated by the
/// test instead, with no environment at all.
struct DailiesBurninSection: View {
    /// The place picker's width. Fixed so the six rows line up, and named so
    /// the render test can ask whether the longest place name fits inside it —
    /// a menu Picker truncates rather than pushing wider, and the two names
    /// that would collide first are the two centre ones.
    static let pickerWidth: CGFloat = 150

    @ObservedObject var model: DailiesQueueModel
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            Text(L("dailies_burn_section"))
                .offloadText(.section)
            // Each line with its own place. A toggle and a picker on one row,
            // because "is it on" and "where is it" are one decision about one
            // line and reading them apart is how an operator ends up with the
            // reel where the timecode should be.
            burnRow(L("dailies_burn_tc"), on: $model.burnTimecode,
                    at: $model.timecodePosition)
            burnRow(L("dailies_burn_name"), on: $model.burnClipName,
                    at: $model.clipNamePosition)
            burnRow(L("dailies_burn_project"), on: $model.burnProject,
                    at: $model.projectPosition)
            // The date has no place of its own: it JOINS the project strip
            // (four corners, five facts — see `DailiesBurnins.date`).
            Toggle(L("dailies_burn_date"), isOn: $model.burnDate)
            HStack(spacing: OffloadChrome.rowSpacing) {
                TextField(L("dailies_custom_placeholder"), text: $model.customText)
                    .textFieldStyle(.roundedBorder)
                positionPicker(at: $model.customPosition)
            }
            // **What it will look like**, drawn by the code that burns the
            // frame (owner: "а главное визуализации").
            DailiesBurninPreview(model: model)
        }
        .toggleStyle(.checkbox)
        .disabled(controller.isDailiesRunning)
    }

    private func burnRow(_ title: String, on: Binding<Bool>,
                         at position: Binding<DailiesBurninPosition>) -> some View {
        HStack(spacing: OffloadChrome.rowSpacing) {
            Toggle(title, isOn: on)
            Spacer(minLength: 4)
            positionPicker(at: position)
                // disabled(exception): per-ROW, and about THIS row's own
                // toggle rather than about app state — a place is only worth
                // choosing for a line that is being burned. The condition is
                // the argument the row was handed, and `burnRow` is the single
                // definition all four rows go through, so there is no second
                // surface that could spell it differently. The whole section
                // is disabled from the controller while a run is going, which
                // is the app-state rule and is named once, below.
                .disabled(!on.wrappedValue)
        }
    }

    private func positionPicker(
        at position: Binding<DailiesBurninPosition>) -> some View {
        Picker("", selection: position) {
            ForEach(DailiesBurninPosition.allCases, id: \.self) { place in
                Text(L(place.labelKey)).tag(place)
            }
        }
        .labelsHidden()
        .frame(width: Self.pickerWidth)
    }
}

extension DailiesBurninPosition {
    /// The strings key for this place, in the picker.
    ///
    /// The keys are LITERALS and not `"dailies_position_" + rawValue`, for the
    /// reason `CountedNoun` spells out: a key the sources never write is a key
    /// `everyKeyWrittenAsALiteralIsInBothStringsFiles` cannot check and
    /// `everyKeyInTheTableIsReachedFromTheCode` reads as dead. Written out,
    /// both walks see all six — and `everyBurninPositionHasWordsInBothLanguages`
    /// closes the loop by asking this property for each case.
    var labelKey: String {
        switch self {
        case .topLeft: return "dailies_position_topLeft"
        case .topCenter: return "dailies_position_topCenter"
        case .topRight: return "dailies_position_topRight"
        case .bottomLeft: return "dailies_position_bottomLeft"
        case .bottomCenter: return "dailies_position_bottomCenter"
        case .bottomRight: return "dailies_position_bottomRight"
        }
    }
}

/// **The burn-ins as they will be**, rendered by the same code that burns the
/// frame — see `DailiesOverlay.previewImage`.
///
/// A rendering and not a mock-up on purpose: a preview drawn by different code
/// is a preview that can be wrong, and the one question it exists to answer is
/// whether the real thing will look like this.
struct DailiesBurninPreview: View {
    @ObservedObject var model: DailiesQueueModel

    /// 16:9 at a size that shows the arrangement without taking the sheet
    /// over. The strips scale with the height, so this is the layout at any
    /// raster rather than a layout of its own.
    static let size = CGSize(width: 320, height: 180)

    var body: some View {
        ZStack {
            if let image = DailiesOverlay.previewImage(
                size: Self.size, texts: texts,
                background: CGColor(gray: 0.22, alpha: 1)) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(.white.opacity(0.12)))
        .accessibilityLabel(L("dailies_preview_help"))
        .help(L("dailies_preview_help"))
    }

    /// A sample take's facts, so the preview has something to place. The
    /// operator's own custom line and toggles are real; the clip name and the
    /// project line are examples, because a queue may be empty when the
    /// arrangement is being set up.
    private var texts: DailiesOverlay.Texts {
        model.burnins.overlayTexts(for: DailiesItem(
            source: URL(fileURLWithPath: "/"), outputName: "",
            clipName: "A001C001", projectLine: "PROJECT · A001",
            dateText: "12.07.26"))
    }
}

/// The one destination, with both of the controls the offload sheet's
/// destination rows have: Choose, and the minus that puts it back.
///
/// The minus is not decoration. Without it the default — a Dailies folder beside
/// the day's footage — was reachable exactly once, before the first run:
/// `dailies.destinationPath` had no writer that could produce nil, so one choice
/// pinned the deliverable to one absolute path for every show after it. Greyed
/// while the default is already in force, so it also says whether there is an
/// override at all.
struct DailiesDestinationRow: View {
    @ObservedObject var model: DailiesQueueModel
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
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
}

/// The sheet's action bar. Its own view for the reason above — Stop and Start
/// both ask the controller for their rule — and, like the offload sheet's
/// footer, it takes its dismissal in rather than reading the environment: a
/// footer measured on its own in a render test has no sheet to dismiss.
struct DailiesSheetFooter: View {
    @ObservedObject var model: DailiesQueueModel
    @EnvironmentObject private var controller: CaptureController
    let dismiss: () -> Void

    var body: some View {
        HStack {
            if model.isRunning {
                Button(L("dailies_stop")) { model.cancel() }
                    .disabled(!controller.canSteerDailiesQueue)
            }
            Spacer()
            Button(model.isRunning ? L("offload_hide") : L("close"),
                   action: dismiss)
                .keyboardShortcut(.cancelAction)
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
