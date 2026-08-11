import AppKit
import CaptureCore
import SwiftUI

/// The DIT offload sheet: one card, a list of destinations, one pass.
///
/// It replaces two chained modal file panels. The panels could not show what
/// this has to: several destinations at once, which file is being copied, the
/// rate each disk is managing, and a per-destination verdict at the end. The
/// operator also has to be able to stop it safely, which a modal panel flow has
/// nowhere to put.
///
/// Everything in it is set in one small type family (see `OffloadChrome`), and
/// it can be closed over a running job — the run reports on itself from the
/// takes panel while the sheet is away (see `OffloadStatusStrip`).
///
/// The two ends of the operation are drawn as one family of tiles (owner item
/// 22) and both can be opened in the Finder (item 23); the other half of the
/// job — checking a copy made earlier — is a button in the footer rather than a
/// second item in a dropdown somewhere else (item 25).
struct OffloadSheet: View {
    @ObservedObject var model: OffloadSheetModel
    @ObservedObject var history: OffloadHistoryStore
    /// Cards the app has stopped asking about. Shown under the history (owner
    /// item 18) — without it a card that silently never prompts is
    /// indistinguishable from a bug.
    @ObservedObject var ledger: OffloadedCardLedger
    /// Read for the enabling rules alone — `isOffloadRunning`, `canStartOffload`,
    /// `canStopDiskJob`, `canStartVerify`, each named once in
    /// `CaptureController+Offload`. The models are still observed, which is what
    /// keeps the re-read fresh.
    @EnvironmentObject private var controller: CaptureController
    @Environment(\.dismiss) private var dismiss

    /// Wide enough for a full destination path at a readable size; the sheet is
    /// fixed so the layout cannot shift as paths change length.
    static let width: CGFloat = 620

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable, and the footer pinned below it: four destinations plus
            // a result card each is taller than the app's minimum window, and a
            // sheet is clamped to its window — Start and Stop have to stay
            // reachable rather than be the part that gets clipped off.
            ScrollView { content.padding(20) }
            Divider()
            OffloadSheetFooter(model: model) { dismiss() }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: Self.width)
    }

    /// The sheet without its fixed frame.
    ///
    /// Separate because that frame is also what hides a layout that does not
    /// fit: content wider than `width` is clipped silently, and a view whose
    /// width is pinned reports the pin rather than what it needed. The render
    /// tests measure this, at the width the padding leaves it.
    @ViewBuilder var content: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.sectionSpacing) {
            Text(L("offload_title"))
                .offloadText(.title)
            sourceSection
            Divider()
            destinationSection
            if let warning = model.validationMessage {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .offloadText(.body, tint: .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Between the form and the run, which is where it happens: Start has
            // been pressed, the destinations have been asked what they already
            // hold, and nothing copies until this is answered.
            if let review = model.resumeReview {
                Divider()
                OffloadResumePanel(review: review,
                                   resume: { model.resumeRun() },
                                   copyEverything: { model.copyEverything() })
            }
            if model.isSurveying {
                Divider()
                Label(L("offload_resume_checking"), systemImage: "clock")
                    .offloadText(.body)
            }
            if let progress = model.progress {
                Divider()
                OffloadProgressPanel(progress: progress,
                                     isCancelling: model.isCancelling)
            }
            if let report = model.report {
                Divider()
                OffloadResultPanel(report: report)
            }
            // Last, and therefore the first thing in view on a sheet that has
            // nothing running and nothing finished — which is exactly when
            // "have I already copied this card?" gets asked.
            Divider()
            OffloadHistoryList(store: history)
            OffloadCardLedgerList(ledger: ledger)
        }
    }

    // MARK: - source

    /// The card, as a tile of the same family as a destination (owner item 22).
    /// It used to be a line of text beside two prominent icon rows, which said
    /// the destinations were the important half — they are not, and picking the
    /// wrong source is the more expensive mistake of the two.
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            Text(L("offload_source_label"))
                .offloadText(.section)
            OffloadPathTile(
                icon: model.source.map(OffloadVolumeFacts.icon) ?? "folder",
                title: model.source.map(OffloadVolumeFacts.name)
                    ?? L("offload_no_source"),
                path: model.source?.path,
                detail: sourceDetail,
                isEmpty: model.source == nil,
                finderTarget: model.source) {
                    Button(L("choose")) { pickSource() }
                        .disabled(controller.isOffloadRunning)
                }
        }
    }

    /// How full the card is — but only for a volume. The same two numbers over
    /// a folder on a working disk would describe the disk, which is not what
    /// the line beside a sound roll appears to be saying.
    private var sourceDetail: String? {
        guard let source = model.source,
              OffloadVolumeFacts.isVolumeRoot(source) else { return nil }
        return OffloadVolumeFacts.usedText(of: source)
    }

    private func pickSource() {
        if let url = OffloadPanels.pickFolder(
            message: L("offload_pick_source"),
            prompt: L("offload_source_prompt")) {
            model.source = url
        }
    }

    // MARK: - destinations

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            HStack {
                Text(L("offload_dest_label"))
                    .offloadText(.section)
                Spacer()
                Button {
                    if let url = pickDestination() {
                        model.addDestination(url)
                    }
                } label: {
                    Label(L("offload_add_dest"), systemImage: "plus")
                }
                .disabled(controller.isOffloadRunning)
            }
            if model.rows.isEmpty {
                Text(L("offload_no_dest"))
                    .offloadText(.caption)
            }
            ForEach(model.rows) { row in
                destinationTile(row)
            }
        }
    }

    private func destinationTile(_ row: OffloadSheetModel.Row) -> some View {
        OffloadPathTile(icon: "externaldrive",
                        title: OffloadVolumeFacts.name(of: row.url),
                        path: row.url.path,
                        detail: destinationDetail(row),
                        finderTarget: model.finderTarget(for: row)) {
            Button(L("choose")) {
                if let url = pickDestination() {
                    model.setDestination(url, at: row.id)
                }
            }
            .disabled(controller.isOffloadRunning)
            Button {
                model.removeDestination(row.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(controller.isOffloadRunning)
            .help(L("offload_remove_dest"))
        }
    }

    /// Where this copy lands and whether the disk can hold it — the two facts
    /// the operator checks before pressing Start, on one line.
    private func destinationDetail(_ row: OffloadSheetModel.Row) -> String? {
        let parts = [model.destinationFolder(for: row)
            .map { "→ \($0.lastPathComponent)" },
                     OffloadVolumeFacts.freeText(of: row.url)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func pickDestination() -> URL? {
        OffloadPanels.pickFolder(message: L("offload_pick_dest"),
                                 prompt: L("offload_dest_prompt"))
    }

}

/// The sheet's action bar.
///
/// Its own view rather than a computed property on the sheet for two reasons:
/// it is the one part that needs the controller (starting a verify is a
/// controller decision — one disk job at a time), and a view that reads an
/// `@EnvironmentObject` has to be evaluated by SwiftUI rather than by whoever
/// asks for the property, which is exactly what the render tests do.
///
/// Close is live while a run is going, and says so: the run continues, the
/// takes panel reports on it, and the sheet is one click away again. It used to
/// refuse to close at all, which meant a half-hour copy covered the app.
///
/// Checking a copy made earlier sits on the same bar (owner item 25) — the
/// other half of this job, previously the second item of an unlabelled dropdown
/// on a strip under the takes panel, where nobody looked for it.
struct OffloadSheetFooter: View {
    @ObservedObject var model: OffloadSheetModel
    @EnvironmentObject private var controller: CaptureController
    /// Passed in rather than read from the environment here: the sheet owns its
    /// own dismissal, and a footer measured on its own in a render test has no
    /// sheet to dismiss.
    let dismiss: () -> Void

    var body: some View {
        HStack {
            if model.isRunning {
                Button(L("offload_cancel_run")) { model.cancel() }
                    .disabled(!controller.canStopDiskJob)
            }
            Button(L("verify_menu")) { controller.chooseDiskToVerify() }
                .disabled(!controller.canStartVerify)
            Spacer()
            Button(model.isRunning ? L("offload_hide") : L("close"),
                   action: dismiss)
            Button(L("offload_start")) { model.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canStartOffload)
        }
    }
}

/// The folder browser the sheet opens. Kept out of the model so everything the
/// model does stays reachable from a test; the dialog itself is `FilePanel`, so
/// the call sites are reachable too.
enum OffloadPanels {
    @MainActor
    static func pickFolder(message: String, prompt: String) -> URL? {
        FilePanel.openOne(.init(files: false, directories: true,
                                createDirectories: true,
                                message: message, prompt: prompt))
    }
}
