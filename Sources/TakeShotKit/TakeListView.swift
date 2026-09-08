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
            // **The focus target sits BEHIND the panel, not around it.**
            //
            // `.focusable()` applied to the sections themselves put a
            // full-size focus view OVER the list and the grid, and a scroll
            // wheel is an AppKit responder-chain event: it goes to whatever is
            // under the pointer. Clicks still worked — SwiftUI routes those
            // through its own gesture system — so the panel looked fine and
            // simply would not scroll (owner: "скролл колесом мышки почему то
            // не работает ни на тейках ни на другом контенте… в настройках
            // общих работало").
            //
            // A clear background is focusable in exactly the same way, takes
            // the same Delete command, and is underneath the scroll views
            // instead of on top of them.
            .background {
                Color.clear
                    .focusable()
                    .focused($focused)
                    .onDeleteCommand {
                        guard !controller.selectedInOrder.isEmpty else { return }
                        controller.trashPromptOpen = true
                    }
            }
            // clicking a tile is the operator saying "I am working in the panel
            // now"; Delete has to land here without a second click somewhere
            .onChange(of: controller.selectedItems) { _, _ in focused = true }
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
    }

    /// The sections, with whatever is running underneath them.
    ///
    /// The settings/VANC/offload BUTTONS are not in here: they are a bare row
    /// under this panel's plate, centred on it (see `PanelUtilityButtons`), and
    /// `ContentView.sidePanel` — not this view — is what puts them there. What
    /// IS in here is the live-run readout, because a job whose status is only
    /// visible inside its own sheet cannot be checked without reopening the
    /// sheet.
    @ViewBuilder private var sections: some View {
        VStack(spacing: 0) {
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
            PanelRunStatus()
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
            // **The title is ON the header row**, beside the folder button and
            // level with the slider and the view picker — the arrangement Other
            // content has always had (owner: "название тейкс… можно поставить
            // теперь так же как другой контент, на одном уровне с ползунком и
            // выбором вида. ну и после названия кнопку открытия папки").
            //
            // It could not be before: the row also carried the export button,
            // and a title in front of it left the picker no width. The export
            // control is two menus in the utility row now, and the space it
            // freed is what the title moved into — one row where there were
            // two, which is the height the panel gets back.
            //
            // Same size and weight as Other content's title so the two panels
            // read as siblings; NOT its secondary grey, because this is the
            // section the operator works in and the quieter voice is what
            // marks the other one as subordinate.
            PanelSectionHeader(viewMode: $viewMode, tileSize: $tileSize) {
                Text(L("takes"))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize()
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
                // The export control USED to be here — a bordered button
                // with an invisible menu stretched over it. It is two menus in
                // the utility row under this panel now, beside the offload and
                // the dailies (owner: "кнопку экспорта давай туда же вниз
                // перенесем и разделим на 2"). Its label was a `Color.clear`,
                // which claims no hit points, so it opened only where the
                // menu's own chrome landed — the row's menus carry real icons
                // and cannot have that problem.
                // The offload status line used to sit here, squeezed between
                // the export button and the view picker. It is a live job with
                // a bar, a file name and a Stop button now, and it reads out at
                // the bottom of this panel (see `PanelRunStatus`).
            }
            .padding(.vertical, 6)
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
                    .padding(PanelChrome.contentMargin)
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
///
/// Hugging its two icons rather than pinned to 70pt, which is what it used to
/// be. The 70 belonged to the SLIDER beside it and was copied onto the picker;
/// a segmented control narrower than its frame is CENTERED in it, so the
/// picker's drawn right edge sat ~14pt inside the frame it was aligned by — the
/// lopsidedness owner item 44 is about, which no amount of margin on the header
/// could fix because the gap was inside the control's own box.
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
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
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
                        if let range = TakeRowTimes.timecodeRange(of: take) {
                            Text(range)
                        }
                        Text(TakeRowTimes.length(of: take))
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
            TakeLogButton(take: take)
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
            TakeTileThumbnail(image: controller.thumbnails[take.id]) {
                Image(systemName: "film")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
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
                // Middle truncation HERE and tail truncation on the Other
                // content beside it, which is not an inconsistency: a take's
                // name is the project and the day at the front and the take
                // number at the back, and the back is what tells two of them
                // apart. A foreign file's name is distinguished by its front.
                Text(take.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                // A duration is four characters and survives the narrowest
                // tile; the same rule the Other-content caption follows, so
                // the two cannot drift about which fact gives way first.
                if !durationOnImage,
                   TakeTileBadges.metricFitsBesideName(
                    ClipTimeText.minutesSeconds.text(take.durationSeconds),
                    tileWidth: tileWidth) {
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

// The take row's two readouts used to live here as free functions — a private
// end-TC that counted at the NOMINAL frame rate, and a duration that rounded
// the opposite way from the transport's. Both are `TakeRowTimes` now, over
// `TakeSpan` and `ClipTimeText`; both of those say what was wrong with them.
