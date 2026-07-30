import CaptureCore
import SwiftUI

extension View {
    /// Accent flash around a freshly recorded take / saved still.
    func newItemHighlight(_ active: Bool, tint: Color) -> some View {
        overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(tint, lineWidth: 2)
            .opacity(active ? 1 : 0))
            .animation(.easeOut(duration: 0.5), value: active)
    }
}

/// Takes panel: a list or a thumbnail grid, with a circle-take mark
/// (goes into takeshot-log.csv as a Good Take for DaVinci Resolve).
/// Below — Other content: files that landed in the record folder outside TakeShot.
/// The boundary between sections is draggable (VSplitView).
struct TakeListView: View {
    @EnvironmentObject private var controller: CaptureController
    /// The panel takes keyboard focus so Delete reaches it, and gives it up to
    /// anything else that wants it — the naming fields in the footer must keep
    /// their own Delete key.
    @FocusState private var focused: Bool

    var body: some View {
        sections
            .focusable()
            .focused($focused)
            // clicking a tile is the operator saying "I am working in the panel
            // now"; Delete has to land here without a second click somewhere
            .onChange(of: controller.selectedItems) { _, _ in focused = true }
            .onDeleteCommand {
                guard !controller.selectedInOrder.isEmpty else { return }
                controller.trashPromptOpen = true
            }
            // .visible, not .automatic: the count IS the dialog — an operator
            // has to see whether Delete is about to take one clip or fifty.
            // Counted off `selectedInOrder`, which is also what `trashSelection`
            // walks: between a file leaving the folder and the scan that prunes
            // the selection, the raw set can name an item that is no longer
            // there, and a dialog that promises three and moves two is worse
            // than no dialog.
            .confirmationDialog(
                L("trash_confirm",
                  localizedItemCount(controller.selectedInOrder.count)),
                isPresented: $controller.trashPromptOpen,
                titleVisibility: .visible) {
                Button(L("delete_item"), role: .destructive) {
                    controller.trashSelection()
                }
                Button(L("cancel"), role: .cancel) {}
            }
            // MOUNT LINE (owner item 48): the footer's settings/VANC/offload
            // buttons live in a strip at the bottom of this panel now.
            .takesPanelUtilityStrip()
    }

    @ViewBuilder private var sections: some View {
        if controller.otherFiles.isEmpty {
            TakesSection()
        } else {
            VSplitView {
                TakesSection()
                    .frame(minHeight: 160)
                OtherContentSection()
                    .frame(minHeight: 100, idealHeight: 180)
            }
        }
    }
}

// MARK: - takes section

private struct TakesSection: View {
    @EnvironmentObject private var controller: CaptureController
    @AppStorage("takesViewMode") private var viewMode = "list"
    @AppStorage("takesTileSize") private var tileSize = 150.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("takes"))
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            HStack(spacing: 10) {
                Button {
                    controller.openDestinationInFinder()
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .help(L("open_folder"))
                // a real bordered Button for the chrome (pixel-identical to the
                // folder button), with an invisible Menu stretched on top —
                // no Menu style matched the Button metrics exactly
                Button {} label: {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .allowsHitTesting(false)
                .overlay {
                    Menu {
                        Button(L("export_edl")) { controller.exportSelectsEDL() }
                            .disabled(!controller.takes.contains { $0.rating == .good })
                        Button(L("export_report_pdf")) {
                            controller.exportShiftReport(pdf: true)
                        }
                        Button(L("export_report_csv")) {
                            controller.exportShiftReport(pdf: false)
                        }
                        // Offload is NOT here: it copies an arbitrary card and
                        // has nothing to do with takes, so a menu disabled by
                        // "no takes yet" made card offload unreachable exactly
                        // when it is most needed — before anything was shot.
                        // Its home is the utility strip below Other content.
                    } label: {
                        Color.clear
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
                .fixedSize()
                .disabled(controller.takes.isEmpty)
                .help(L("export_menu_help"))
                if let status = controller.offloadStatus {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if viewMode == "grid" {
                    Slider(value: $tileSize, in: TakeTileBadges.tileWidthRange)
                        .frame(width: 70)
                        .controlSize(.mini)
                        .help(L("tile_size"))
                }
                ViewModePicker(mode: $viewMode)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 8)
            Divider()
            if controller.takes.isEmpty {
                Spacer()
                Text(L("no_takes_yet"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if viewMode == "grid" {
                ScrollView {
                    LazyVGrid(columns: gridColumns(size: tileSize), spacing: 10) {
                        ForEach(controller.takes.reversed()) { take in
                            TakeCell(take: take, tileWidth: tileSize)
                        }
                    }
                    .padding(10)
                }
            } else {
                List(controller.takes.reversed()) { take in
                    TakeRow(take: take)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

func gridColumns(size: Double) -> [GridItem] {
    // max == min: the tile is always exactly the chosen size, the slider stays smooth
    [GridItem(.adaptive(minimum: size, maximum: size + 0.5), spacing: 10)]
}

/// List/thumbnail toggle (shared style for both sections).
struct ViewModePicker: View {
    @Binding var mode: String

    var body: some View {
        Picker("", selection: $mode) {
            Image(systemName: "list.bullet").tag("list")
                .help(L("view_list"))
            Image(systemName: "square.grid.2x2").tag("grid")
                .help(L("view_grid"))
        }
        .pickerStyle(.segmented)
        .frame(width: 70)
        .labelsHidden()
        .controlSize(.small)
    }
}

struct TakeRow: View {
    @EnvironmentObject private var controller: CaptureController
    let take: Take

    var body: some View {
        HStack {
            // clicks live on the info area only: a gesture on the whole row
            // delays every tap on the buttons (double-tap disambiguation)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(take.displayName)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let tc = take.startTimecode {
                            Text("\(tc.description) – \(endTimecode(of: take).description)")
                        }
                        Text(durationText(take.durationSeconds))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if !take.comment.isEmpty {
                        Text(take.comment)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .italic()
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
            }
            .panelItemClicks(take.url, in: controller) {
                controller.play(url: take.url)
            }
            CommentButton(take: take)
            RatingToggle(take: take)
        }
        .contextMenu { TakeContextMenu(take: take) }
        .panelSelectionOutline(controller.selectedItems.contains(take.url),
                               tint: controller.accentColor)
        .newItemHighlight(controller.recentlyAddedURL == take.url,
                          tint: controller.accentColor)
    }
}

/// One tile in the thumbnail grid. `tileWidth` is the slider's value, which is
/// also the tile's exact width (see `gridColumns`) — the badge layout is chosen
/// from it, so no size is guessed at render time.
struct TakeCell: View {
    @EnvironmentObject private var controller: CaptureController
    let take: Take
    let tileWidth: Double

    /// Small tiles are not tall enough for both badges (see TakeTileBadges).
    private var durationOnImage: Bool {
        TakeTileBadges.bothFitOnImage(
            thumbnailHeight: TakeTileBadges.thumbnailHeight(tileWidth: tileWidth))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.black)
                if let thumbnail = controller.thumbnails[take.id] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(TakeTileBadges.aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onAppear { controller.requestThumbnail(for: take) }
            .panelItemClicks(take.url, in: controller) {
                controller.play(url: take.url)
            }
            .overlay(alignment: .topTrailing) {
                TakeTileControls(take: take)
                    .padding(TakeTileBadges.inset)
            }
            .overlay(alignment: .bottomLeading) {
                if durationOnImage {
                    TakeDurationBadge(seconds: take.durationSeconds)
                        .padding(TakeTileBadges.inset)
                }
            }
            HStack(spacing: 4) {
                Text(take.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !durationOnImage {
                    Spacer(minLength: 2)
                    TakeDurationBadge(seconds: take.durationSeconds,
                                      onImage: false)
                }
            }
        }
        .contextMenu { TakeContextMenu(take: take) }
        .panelSelectionOutline(controller.selectedItems.contains(take.url),
                               tint: controller.accentColor)
    }
}

/// Take end TC: start + duration at the TC's own fps.
private func endTimecode(of take: Take) -> Timecode {
    let start = take.startTimecode ?? Timecode(frameNumber: 0, fps: 25, isDropFrame: false)
    let frames = Int((take.durationSeconds * Double(max(1, start.fps))).rounded())
    return Timecode(frameNumber: start.frameNumber + frames,
                    fps: start.fps, isDropFrame: start.isDropFrame)
}

func durationText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
