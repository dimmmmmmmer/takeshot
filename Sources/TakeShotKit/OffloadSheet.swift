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
            OffloadSourceSection(model: model)
            Divider()
            OffloadDestinationSection(model: model)
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
                                     isCancelling: model.isCancelling,
                                     cardIndex: model.cardIndex,
                                     cardCount: model.cardCount)
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
}

/// The card, as a tile of the same family as a destination (owner item 22).
///
/// It used to be a line of text beside two prominent icon rows, which said the
/// destinations were the important half — they are not, and picking the wrong
/// source is the more expensive mistake of the two.
///
/// A view of its own rather than a property of the sheet, for the reason
/// `OffloadSheetFooter` states: it reads its enabling rule off the controller,
/// and an `@EnvironmentObject` is bound only when SwiftUI evaluates the view —
/// a property the render tests ask for directly is evaluated by the test, where
/// there is no environment at all.
struct OffloadSourceSection: View {
    @ObservedObject var model: OffloadSheetModel
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            HStack {
                Text(L("offload_source_label"))
                    .offloadText(.section)
                Spacer()
                Button {
                    if let url = pickSource() { model.addSource(url) }
                } label: {
                    Label(L("offload_add_source"), systemImage: "plus")
                }
                .disabled(controller.isOffloadRunning)
            }
            if model.sourceRows.isEmpty {
                Text(L("offload_no_cards"))
                    .offloadText(.caption)
            }
            ForEach(model.sourceRows) { row in
                sourceTile(row)
            }
        }
    }

    /// One card, built exactly like a destination row: the plate carries what
    /// acts ON this card, and Remove sits outside it in red because it acts on
    /// the LIST. The two lists are the same control now, which is the point of
    /// the change — an operator who has learned one has learned both.
    private func sourceTile(_ row: OffloadSheetModel.Row) -> some View {
        HStack(spacing: OffloadChrome.rowSpacing) {
            OffloadPathTile(icon: OffloadVolumeFacts.icon(for: row.url),
                            title: OffloadVolumeFacts.name(of: row.url),
                            path: row.url.path,
                            detail: sourceDetail(row),
                            finderTarget: row.url) {
                Button(L("choose")) { chooseSource(row) }
                    .disabled(controller.isOffloadRunning)
            }
            .contextMenu { sourceMenu(row) }
            Button {
                model.removeSource(row.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .disabled(controller.isOffloadRunning)
            .help(L("offload_remove_source"))
        }
    }

    @ViewBuilder
    private func sourceMenu(_ row: OffloadSheetModel.Row) -> some View {
        Button(L("choose")) { chooseSource(row) }
            .disabled(controller.isOffloadRunning)
        Button(L("offload_open_source")) { FinderOpen.folder(row.url) }
        Divider()
        Button(L("offload_remove_source"), role: .destructive) {
            model.removeSource(row.id)
        }
        .disabled(controller.isOffloadRunning)
    }

    private func chooseSource(_ row: OffloadSheetModel.Row) {
        guard let url = pickSource(near: row.url) else { return }
        model.setSource(url, at: row.id)
    }

    /// How full the card is — but only for a volume. The same two numbers over a
    /// folder on a working disk would describe the disk, which is not what the
    /// line beside a sound roll appears to be saying.
    private func sourceDetail(_ row: OffloadSheetModel.Row) -> String? {
        guard OffloadVolumeFacts.isVolumeRoot(row.url) else { return nil }
        return OffloadVolumeFacts.usedText(of: row.url)
    }

    private func pickSource(near: URL? = nil) -> URL? {
        OffloadPanels.pickFolder(message: L("offload_pick_source"),
                                 prompt: L("offload_source_prompt"), near: near)
    }
}

/// The destination list: add, re-point, remove.
///
/// Its own view for the same reason as the source section above.
struct OffloadDestinationSection: View {
    @ObservedObject var model: OffloadSheetModel
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
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

    /// One destination.
    ///
    /// **Choose comes last inside the tile, and Remove is outside it** (owner:
    /// "по логике должно быть choose после остальных кнопок" and "кнопка
    /// удаления должна быть по логике не внутри него а правее например и
    /// красным выделена"). The two belong to different things: Choose and Open
    /// act ON this destination and live on its plate; Remove acts on the LIST
    /// and takes the plate away with it, so it sits beside the plate and wears
    /// the colour destructive actions wear everywhere else in the app.
    ///
    /// Everything the row can do is also under the secondary click, because a
    /// row with three affordances spread across two containers is one an
    /// operator should be able to right-click instead of aim at.
    private func destinationTile(_ row: OffloadSheetModel.Row) -> some View {
        HStack(spacing: OffloadChrome.rowSpacing) {
            OffloadPathTile(icon: "externaldrive",
                            title: OffloadVolumeFacts.name(of: row.url),
                            path: row.url.path,
                            detail: destinationDetail(row),
                            finderTarget: model.finderTarget(for: row)) {
                Button(L("choose")) { chooseDestination(row) }
                    .disabled(controller.isOffloadRunning)
            }
            .contextMenu { destinationMenu(row) }
            Button {
                model.removeDestination(row.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .disabled(controller.isOffloadRunning)
            .help(L("offload_remove_dest"))
        }
    }

    @ViewBuilder
    private func destinationMenu(_ row: OffloadSheetModel.Row) -> some View {
        Button(L("choose")) { chooseDestination(row) }
            .disabled(controller.isOffloadRunning)
        Button(L("offload_open_dest")) {
            FinderOpen.folder(model.finderTarget(for: row))
        }
        Divider()
        Button(L("offload_remove_dest"), role: .destructive) {
            model.removeDestination(row.id)
        }
        .disabled(controller.isOffloadRunning)
    }

    private func chooseDestination(_ row: OffloadSheetModel.Row) {
        guard let url = pickDestination(near: row.url) else { return }
        model.setDestination(url, at: row.id)
    }

    /// Where this copy lands and whether the disk can hold it — the two facts the
    /// operator checks before pressing Start, on one line.
    private func destinationDetail(_ row: OffloadSheetModel.Row) -> String? {
        // One card names the folder it lands in; several name how many, since
        // the row cannot show three folder names and a free-space figure.
        let landing: String?
        switch model.sources.count {
        case 0: landing = nil
        case 1: landing = model.sources.first.map {
            "→ \(model.destinationFolder(for: row, card: $0).lastPathComponent)"
        }
        default: landing = "→ " + localizedCount(model.sources.count, .card)
        }
        let parts = [landing, OffloadVolumeFacts.freeText(of: row.url)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `near` is the destination being REPLACED, when there is one — see
    /// `OffloadPanels.pickFolder`. Adding a new destination has nothing to be
    /// near, and the panel opens where it last was.
    private func pickDestination(near: URL? = nil) -> URL? {
        OffloadPanels.pickFolder(message: L("offload_pick_dest"),
                                 prompt: L("offload_dest_prompt"), near: near)
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
            if model.isRunning || model.isSurveying {
                Button(L("offload_cancel_run")) { model.cancel() }
                    .disabled(!controller.canStopDiskJob)
            }
            Button(L("verify_menu")) { controller.chooseDiskToVerify() }
                .disabled(!controller.canStartVerify)
            Spacer()
            Button(model.isRunning ? L("offload_hide") : L("close"),
                   action: dismiss)
                .keyboardShortcut(.cancelAction)
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
    /// `near` is what is chosen NOW, and the panel opens at the root of the
    /// disk that path is on rather than inside the path itself.
    ///
    /// Choosing again is almost always "same drive, different folder" — the
    /// drive is the thing the operator plugged in and the folder is the thing
    /// they are changing — and a panel that opens inside the current folder
    /// makes them climb out of it first (owner: "сделай так чтоб у источника
    /// или результирующего источника finder изначально открывал его корень.
    /// типа диск я выбрал но папку может поменять зочу").
    @MainActor
    static func pickFolder(message: String, prompt: String,
                           near: URL? = nil) -> URL? {
        FilePanel.openOne(.init(files: false, directories: true,
                                createDirectories: true,
                                directory: volumeRoot(of: near),
                                message: message, prompt: prompt))
    }

    /// The root of the volume `url` is on — `/Volumes/SHUTTLE` for anything
    /// under it, and the boot volume's `/` for a path in the home folder.
    ///
    /// **Climbs until something answers.** `volumeURLKey` is answered by the
    /// file system, so it says nothing at all about a path that is not there —
    /// and the paths this is asked about are exactly the ones that may not be:
    /// a destination folder that has not been created yet, or a shuttle that
    /// has been unplugged since. Walking up finds the nearest ancestor that
    /// does exist, which for an unmounted drive is `/Volumes` — where the
    /// operator would go looking for it anyway.
    static func volumeRoot(of url: URL?) -> URL? {
        guard let url else { return nil }
        var candidate = url.standardizedFileURL
        while true {
            if let volume = try? candidate
                .resourceValues(forKeys: [.volumeURLKey]).volume {
                return volume
            }
            let parent = candidate.deletingLastPathComponent()
                .standardizedFileURL
            guard parent != candidate else { return nil }
            candidate = parent
        }
    }
}
