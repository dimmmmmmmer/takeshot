import CaptureCore
import SwiftUI

/// **Where the dailies come FROM and where they go** — the sheet's second face.
///
/// Sources first, because that is the question the owner opened: "дейлики
/// нужны из исходников. хотелось бы выбирать папку из которой будут
/// рендериться дейлики, вероятно даже несколько источников, как в оффлоаде".
/// Empty means the day's takes, which is what this sheet has always run on, so
/// an operator who never touches this face gets the behaviour they had.
///
/// Its own face rather than more rows under the burn-ins: two folder lists are
/// 160pt, and the sheet has to fit a window that may be 620 tall.
struct DailiesFilesTab: View {
    @ObservedObject var model: DailiesQueueModel
    @EnvironmentObject private var controller: CaptureController

    /// About four rows before a list scrolls. The lists are the one part of
    /// this face with no bound — a day can be shot on eight cards.
    static let listHeight: CGFloat = 96

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OffloadChrome.sectionSpacing) {
                sources
                Divider()
                sound
                Divider()
                destinations
                Divider()
                DailiesOutputSection(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The same inset the burn-ins face keeps, so neither stands
            // against the `TabView`'s own border — see `DailiesSheet.tabInset`.
            .padding(DailiesSheet.tabInset)
        }
        // **The same width the other face asks for, whatever is in it.**
        //
        // A `TabView` takes the size of the face on show, and this one asked
        // for its own rows: measured at 413pt against the burn-ins face's 678,
        // and 804 once a card with a real path had been added — so the box
        // changed size when the operator switched tabs AND again when they
        // added a source. `idealWidth` and not `minWidth`, because the number
        // has to be what this face ANSWERS with, not a floor under an answer
        // that grows with the longest path on set. The rows already truncate
        // in the middle, so 678 costs a path nothing it was not already
        // spending. See `DailiesSheet.tabContentWidth`.
        .frame(idealWidth: DailiesSheet.tabContentWidth, maxWidth: .infinity,
               alignment: .leading)
    }

    // MARK: - sound

    /// **The recordist's folders**, beside the footage's (owner: "было бы
    /// классно иметь возможность выбрать папку со звуком").
    ///
    /// Its own block rather than a row on the sources list, because it answers
    /// a different question: the sources say WHAT is rendered, and this says
    /// what goes UNDER it. A run with no sound folder is the run this app has
    /// always made — the camera's own track and nothing else — which is what
    /// the empty line says rather than leaving a blank.
    @ViewBuilder private var sound: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            HStack {
                Text(L("dailies_sound_label"))
                    .offloadText(.section)
                Spacer(minLength: 4)
                Button {
                    if let url = OffloadPanels.pickFolder(
                        message: L("dailies_pick_sound"),
                        prompt: L("offload_source_prompt")) {
                        model.addSoundFolder(url)
                    }
                } label: {
                    Label(L("dailies_add_sound"), systemImage: "plus")
                }
                .disabled(controller.isDailiesRunning)
            }
            if model.soundFolders.isEmpty {
                Text(L("dailies_sound_camera_only"))
                    .offloadText(.caption)
            } else {
                folderList(model.soundFolders) { url in
                    HStack(spacing: OffloadChrome.rowSpacing) {
                        folderRow(url) {
                            if let picked = OffloadPanels.pickFolder(
                                message: L("dailies_pick_sound"),
                                prompt: L("offload_source_prompt"), near: url) {
                                model.replaceSoundFolder(url, with: picked)
                            }
                        }
                        removeButton(L("dailies_remove_sound")) {
                            model.removeSoundFolder(url)
                        }
                    }
                }
                soundSummary
            }
        }
    }

    /// What the sound folders hold, and what could not be used.
    ///
    /// The second line is the load-bearing one: a file with no `bext` chunk
    /// carries no timecode, so nothing can line it up with a take. An operator
    /// who pointed at a folder of files their recorder wrote without timecode
    /// has to find that out here rather than from a day of silent dailies.
    @ViewBuilder private var soundSummary: some View {
        Text(L("dailies_sound_found",
               localizedCount(model.soundFindings.files.count, .file)))
            .offloadText(.caption)
        if !model.soundFindings.withoutTimecode.isEmpty {
            Label(L("dailies_sound_no_timecode",
                    model.soundFindings.withoutTimecode.count),
                  systemImage: "exclamationmark.triangle")
                .offloadText(.caption)
        }
    }

    // MARK: - sources

    @ViewBuilder private var sources: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            HStack {
                Text(L("dailies_sources_label"))
                    .offloadText(.section)
                Spacer(minLength: 4)
                Button {
                    if let url = OffloadPanels.pickFolder(
                        message: L("dailies_pick_source"),
                        prompt: L("offload_source_prompt")) {
                        model.addSource(url)
                    }
                } label: {
                    Label(L("dailies_add_source"), systemImage: "plus")
                }
                .disabled(controller.isDailiesRunning)
            }
            if model.sources.isEmpty {
                // The default, stated rather than left blank: an empty list
                // that silently means "the day's takes" is a list nobody can
                // tell from a list that lost its rows.
                Text(L("dailies_sources_takes"))
                    .offloadText(.caption)
            } else {
                folderList(model.sources) { url in
                    HStack(spacing: OffloadChrome.rowSpacing) {
                        folderRow(url) {
                            if let picked = OffloadPanels.pickFolder(
                                message: L("dailies_pick_source"),
                                prompt: L("offload_source_prompt"), near: url) {
                                model.replaceSource(url, with: picked)
                            }
                        }
                        removeButton(L("dailies_remove_source")) {
                            model.removeSource(url)
                        }
                    }
                }
                summary
            }
        }
    }

    /// What the folders hold, and what this path is leaving alone.
    ///
    /// The RAW line is not an apology, it is the fact an operator has to have
    /// before they start: this transcode reads through AVFoundation, and a
    /// camera RAW clip is a different decode entirely. Forty items that each
    /// fail with a message about a reader would be a worse way to say it.
    @ViewBuilder private var summary: some View {
        if model.isScanning {
            Label(L("dailies_scanning"), systemImage: "clock")
                .offloadText(.caption)
        } else {
            Text(L("dailies_found", localizedCount(model.findings.files.count,
                                                   .file)))
                .offloadText(.caption)
            if !model.findings.skippedRaw.isEmpty {
                Label(L("dailies_skipped_raw",
                        localizedCount(model.findings.skippedRaw.count, .file)),
                      systemImage: "exclamationmark.triangle")
                    .offloadText(.caption, tint: .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - destinations

    @ViewBuilder private var destinations: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            HStack {
                Text(L("dailies_dest_label"))
                    .offloadText(.section)
                Spacer(minLength: 4)
                Button {
                    if let url = OffloadPanels.pickFolder(
                        message: L("dailies_pick_dest"),
                        prompt: L("offload_dest_prompt")) {
                        model.addDestination(url)
                    }
                } label: {
                    Label(L("dailies_add_dest"), systemImage: "plus")
                }
                .disabled(controller.isDailiesRunning)
            }
            folderList(model.destinations) { url in
                HStack(spacing: OffloadChrome.rowSpacing) {
                    folderRow(url) {
                        if let picked = OffloadPanels.pickFolder(
                            message: L("dailies_pick_dest"),
                            prompt: L("offload_dest_prompt"), near: url) {
                            model.replaceDestination(url, with: picked)
                        }
                    }
                    // The first destination is where the encode lands and
                    // cannot be removed — a run with nowhere to write is not a
                    // run. It has the way BACK to the default instead.
                    if url == model.destinations.first {
                        if controller.hasDailiesDestinationOverride {
                            Button(L("dailies_reset_dest_button")) {
                                controller.clearDailiesDestination()
                            }
                            .disabled(!controller.canClearDailiesDestination)
                            .help(L("dailies_reset_dest"))
                            .fixedSize()
                        }
                    } else {
                        removeButton(L("dailies_remove_dest")) {
                            model.removeDestination(url)
                        }
                    }
                }
            }
            if model.destinations.count > 1 {
                // Said once, where the second shelf appears: the extra copies
                // are COPIES, not second encodes.
                Text(L("dailies_dest_copies"))
                    .offloadText(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - the shared shapes

    /// A bounded list: a day can be shot on eight cards, and a sheet that grew
    /// with the card count is a sheet that stops fitting the window.
    @ViewBuilder private func folderList<Row: View>(
        _ urls: [URL], @ViewBuilder row: @escaping (URL) -> Row) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OffloadChrome.tightSpacing) {
                ForEach(urls, id: \.self) { row($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: Self.listHeight)
    }

    private func folderRow(_ url: URL,
                           choose: @escaping () -> Void) -> some View {
        HStack(spacing: OffloadChrome.rowSpacing) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(OffloadVolumeFacts.name(of: url))
                    .offloadText(.body)
                    .lineLimit(1)
                Text(url.path)
                    .offloadText(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button(L("choose"), action: choose)
                .disabled(controller.isDailiesRunning)
                .fixedSize()
        }
    }

    private func removeButton(_ help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
        .disabled(controller.isDailiesRunning)
        .help(help)
    }
}
