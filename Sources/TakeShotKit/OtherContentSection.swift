import Foundation
import SwiftUI

// MARK: - Other content

/// Foreign video files that landed in the record folder outside TakeShot.
struct OtherContentSection: View {
    @EnvironmentObject private var controller: CaptureController
    @AppStorage("otherViewMode") private var viewMode = "list"
    @AppStorage("otherTileSize") private var tileSize = 150.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // the pickers finish as close to the right edge as this title
            // starts from the left (owner items 22 and 44 — see
            // `PanelChrome.viewPickerEdgeInset`)
            PanelSectionHeader(viewMode: $viewMode, tileSize: $tileSize) {
                Text(L("other_content"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            Divider()
            if viewMode == "grid" {
                ScrollView {
                    LazyVGrid(columns: gridColumns(size: tileSize), spacing: 10) {
                        ForEach(controller.otherFiles, id: \.self) { url in
                            OtherCell(url: url, tileWidth: tileSize)
                        }
                    }
                    .padding(PanelChrome.contentMargin)
                }
            } else {
                List(controller.otherFiles, id: \.self) { url in
                    OtherRow(url: url)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

/// One row in the Other content list.
struct OtherRow: View {
    @EnvironmentObject private var controller: CaptureController
    let url: URL

    var body: some View {
        HStack {
            OtherTypeGlyph(url: url)
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            // The folder it is in, after the name and in the quieter voice:
            // the name is what the operator is reading for, and the folder is
            // what tells two files of that name apart. Nothing at all for a
            // file in the record folder itself, which is most of them.
            if let folder = controller.otherFolderText(for: url) {
                Text(folder)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    // The HEAD is what gives way: the folder nearest the file
                    // is the one that tells two rows apart, and "…/100CANON"
                    // says more than "CARD_A/DCI…".
                    .truncationMode(.head)
                    // Space goes to the name first. The probe cannot read a
                    // rendered truncation, so what the tests pin is the half
                    // they can: the label truncates instead of widening the
                    // row (`aLongFolderDoesNotWidenTheRow`).
                    .layoutPriority(-1)
            }
            Spacer(minLength: 4)
            if let metric = controller.otherMetricText(for: url) {
                Text(metric)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .panelItemClicks(url, in: controller) { controller.play(url: url) }
        .contextMenu { OtherContextMenu(url: url) }
        .panelSelectionOutline(controller.selectedItems.contains(url),
                               tint: controller.accentColor)
    }
}

/// One tile in the Other content grid. `tileWidth` is the slider's value and the
/// tile's exact width (see `gridColumns`), so the badge layout is chosen from it
/// rather than guessed at render time — the same rule the takes grid follows.
struct OtherCell: View {
    @EnvironmentObject private var controller: CaptureController
    let url: URL
    var tileWidth: Double = 150

    /// A small tile is not tall enough for the type glyph and the metric badge
    /// one above the other; below the threshold the metric moves onto the
    /// caption line, exactly as a take's duration does.
    private var metricOnImage: Bool {
        TakeTileBadges.typeAndMetricFitOnImage(
            thumbnailHeight: TakeTileBadges.thumbnailHeight(tileWidth: tileWidth))
    }

    var body: some View {
        let metric = controller.otherMetricText(for: url)
        VStack(alignment: .leading, spacing: 4) {
            TakeTileThumbnail(image: controller.otherThumbnails[url]) {
                OtherTypeGlyph(url: url)
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
            .overlay(alignment: .topLeading) {
                // the tile is the one place a photo and a clip look alike — the
                // frame in the middle of a video is a still picture too — so the
                // type is stated on the image rather than left to be inferred
                OtherTypeBadge(url: url)
                    .padding(TakeTileBadges.inset)
            }
            .overlay(alignment: .bottomLeading) {
                if let metric, metricOnImage {
                    TileMetricBadge(text: metric)
                        .padding(TakeTileBadges.inset)
                }
            }
            HStack(spacing: 4) {
                // the BEGINNING of the name, and it wins the space: middle
                // truncation on a narrow tile spends what little there is on
                // an ellipsis between two fragments of two characters each
                Text(url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    // A tile has one caption line and the name already fills
                    // it, so the folder is what the tooltip is for.
                    .help(controller.otherFolderText(for: url)
                        .map { "\($0)/\(url.lastPathComponent)" }
                        ?? url.lastPathComponent)
                if let metric, !metricOnImage,
                   TakeTileBadges.metricFitsBesideName(metric,
                                                       tileWidth: tileWidth) {
                    Spacer(minLength: 2)
                    TileMetricBadge(text: metric, onImage: false)
                }
            }
        }
        .panelItemClicks(url, in: controller) { controller.play(url: url) }
        .contextMenu { OtherContextMenu(url: url) }
        .panelSelectionOutline(controller.selectedItems.contains(url),
                               tint: controller.accentColor)
        .newItemHighlight(controller.recentlyAddedURL == url,
                          tint: controller.accentColor)
        .onAppear { controller.requestOtherThumbnail(for: url) }
    }
}

private struct OtherContextMenu: View {
    @EnvironmentObject private var controller: CaptureController
    let url: URL

    var body: some View {
        Button(L("play")) { controller.play(url: url) }
        if CaptureController.imageExtensions.contains(url.pathExtension.lowercased()) {
            Button(L("pin_reference")) { controller.pinReference(imageURL: url) }
        }
        Divider()
        PanelItemActions(url: url) { controller.deleteOtherFile(url) }
    }
}

// MARK: - photo or video

/// The type glyph itself, with the tooltip that names the type in words.
///
/// One view rather than a bare `Image` in three places: the row, the tile badge
/// and the empty tile's placeholder all have to say the same thing, and the
/// glyph is only unambiguous once it is the same everywhere.
struct OtherTypeGlyph: View {
    let url: URL

    var body: some View {
        Image(systemName: otherIsPhoto(url) ? "photo" : "film")
            .help(L(otherIsPhoto(url) ? "other_type_photo" : "other_type_video"))
    }
}

/// The type glyph as it sits on a tile: the same dark plate the metric badge
/// wears, so the two read as one family.
///
/// The glyph is boxed to a fixed height rather than left at its natural one. An
/// SF Symbol's ascent is not a text line's, and the two badges share the tile's
/// leading edge — the layout decides from `TakeTileBadges.typeBadgeHeight`
/// whether they both fit, so that number has to be what this renders as.
struct OtherTypeBadge: View {
    let url: URL

    var body: some View {
        OtherTypeGlyph(url: url)
            .font(.caption2)
            .frame(height: TakeTileBadges.typeBadgeHeight - 2)
            .padding(.horizontal, TakeTileBadges.inset)
            .padding(.vertical, 1)
            .background(.black.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.white)
    }
}

/// Whether an Other-content item is a still.
///
/// The list is the scanner's own (`CaptureController.imageExtensions`) rather
/// than a copy: a still whose extension the scan accepts but the icon table does
/// not comes up looking like a video clip. Extension only, and deliberately no
/// look at the disk — this is asked once per glyph in a grid that redraws while
/// a slider moves, and a `fileExists` per tile per frame is a stall nobody can
/// see the cause of.
func otherIsPhoto(_ url: URL) -> Bool {
    CaptureController.imageExtensions.contains(url.pathExtension.lowercased())
}

extension CaptureController {
    /// The one fact shown beside an Other-content item's name: how long a clip
    /// runs, or how big a photo is.
    ///
    /// A duration on a still would be a lie and a blank would be a third state
    /// nobody can read, so the two types answer the same question differently —
    /// which is also the second, quieter half of telling them apart. nil while
    /// the decoder has not got to the file yet.
    func otherMetricText(for url: URL) -> String? {
        if let size = otherPixelSizes[url] {
            return "\(Int(size.width))×\(Int(size.height))"
        }
        // `ClipTimeText` and not a local spelling: this is the one duration in
        // the app read straight off `AVAsset.duration.seconds` of a file
        // nobody wrote, so it is the one most likely to be NaN — see the note
        // on the type.
        return otherDurations[url].map(ClipTimeText.minutesSeconds.text)
    }
}

extension CaptureController {
    /// **Which folder an Other-content item is in**, relative to the record
    /// folder — nil for a file sitting directly in it.
    ///
    /// The list is flat and stays flat: it is a "what else is in here" list,
    /// not a file browser, and a tree would answer a question nobody opened
    /// this panel to ask. What it could not answer before is where a row's
    /// file actually IS (owner: "other content в принципе не учитывает
    /// папки") — and the scan walks the whole tree, so two rows reading
    /// `A001C001.mov` were routinely two different files in two folders, with
    /// nothing on screen to tell them apart and Play, Reveal and Delete all
    /// aimed at whichever one the row happened to hold.
    ///
    /// Compared through `comparablePath`, which is `standardized` and purely
    /// lexical. `standardizedFileURL` is the trap here and the comment on
    /// `comparablePath` names it: it folds a leading `/private` only when what
    /// is left EXISTS, so the record folder (which does) and a file inside it
    /// standardize to two different roots the moment the file has just been
    /// deleted — and every row would then be labelled with an absolute path.
    /// Lexical also keeps this cheap, which matters: it is asked per row while
    /// a list scrolls.
    func otherFolderText(for url: URL) -> String? {
        let root = CaptureController.comparablePath(destinationRoot)
        let folder = CaptureController
            .comparablePath(url.deletingLastPathComponent())
        guard folder != root else { return nil }
        guard folder.hasPrefix(root + "/") else {
            // Outside the record folder entirely — nothing in the scan puts a
            // file there, but a stale row from a folder that has since been
            // re-pointed would otherwise be labelled with a path fragment cut
            // at the wrong place. The whole folder is the honest answer.
            return folder
        }
        return String(folder.dropFirst(root.count + 1))
    }
}
