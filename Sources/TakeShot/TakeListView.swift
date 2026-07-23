import CaptureCore
import SwiftUI

/// Takes panel: a list or a thumbnail grid, with a circle-take mark
/// (goes into takeshot-log.csv as a Good Take for DaVinci Resolve).
/// Below — Other content: files that landed in the record folder outside TakeShot.
/// The boundary between sections is draggable (VSplitView).
struct TakeListView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
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
            HStack(spacing: 10) {
                Text(L("takes"))
                    .font(.headline)
                Button {
                    controller.openDestinationInFinder()
                } label: {
                    Image(systemName: "folder")
                }
                .controlSize(.small)
                .fixedSize()
                .help(L("open_folder"))
                Spacer()
                if viewMode == "grid" {
                    Slider(value: $tileSize, in: 70...260)
                        .frame(width: 70)
                        .controlSize(.mini)
                        .help(L("tile_size"))
                }
                ViewModePicker(mode: $viewMode)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
                            TakeCell(take: take)
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
private struct ViewModePicker: View {
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

private struct TakeRow: View {
    @EnvironmentObject private var controller: CaptureController
    let take: Take

    var body: some View {
        HStack {
            // double-tap lives on the info area only: a gesture on the whole
            // row delays every tap on the buttons (double-tap disambiguation)
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
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { controller.play(url: take.url) }
            CommentButton(take: take)
            RatingToggle(take: take)
        }
        .contextMenu { TakeContextMenu(take: take) }
    }
}

private struct TakeCell: View {
    @EnvironmentObject private var controller: CaptureController
    let take: Take

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
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { controller.play(url: take.url) }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    CommentButton(take: take)
                    RatingToggle(take: take)
                }
                .padding(4)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(4)
            }
            .overlay(alignment: .bottomLeading) {
                Text(durationText(take.durationSeconds))
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .padding(4)
            }
            Text(take.displayName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contextMenu { TakeContextMenu(take: take) }
    }
}

// MARK: - Other content

private struct OtherContentSection: View {
    @EnvironmentObject private var controller: CaptureController
    @AppStorage("otherViewMode") private var viewMode = "list"
    @AppStorage("otherTileSize") private var tileSize = 150.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(L("other_content"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if viewMode == "grid" {
                    Slider(value: $tileSize, in: 70...260)
                        .frame(width: 70)
                        .controlSize(.mini)
                        .help(L("tile_size"))
                }
                ViewModePicker(mode: $viewMode)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            if viewMode == "grid" {
                ScrollView {
                    LazyVGrid(columns: gridColumns(size: tileSize), spacing: 10) {
                        ForEach(controller.otherFiles, id: \.self) { url in
                            OtherCell(url: url)
                        }
                    }
                    .padding(10)
                }
            } else {
                List(controller.otherFiles, id: \.self) { url in
                    HStack {
                        Image(systemName: iconName(for: url))
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let duration = controller.otherDurations[url] {
                            Text(durationText(duration))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { controller.play(url: url) }
                    .contextMenu { OtherContextMenu(url: url) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

private struct OtherCell: View {
    @EnvironmentObject private var controller: CaptureController
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.black)
                if let thumbnail = controller.otherThumbnails[url] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: iconName(for: url))
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { controller.play(url: url) }
        .contextMenu { OtherContextMenu(url: url) }
    }
}

private struct OtherContextMenu: View {
    @EnvironmentObject private var controller: CaptureController
    let url: URL

    var body: some View {
        Button(L("play")) { controller.play(url: url) }
        Button(L("show_in_finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

private func isImage(_ url: URL) -> Bool {
    ["jpg", "jpeg", "png", "heic", "tif", "tiff", "dng", "arw", "cr2", "webp"]
        .contains(url.pathExtension.lowercased())
}

private func iconName(for url: URL) -> String {
    ["jpg", "jpeg", "png", "heic", "tif", "tiff", "dng", "arw", "cr2", "webp"]
        .contains(url.pathExtension.lowercased()) ? "photo" : "film"
}

// MARK: - shared

/// Speech-bubble button that opens a popover to edit a take's free-text comment.
private struct CommentButton: View {
    @EnvironmentObject private var controller: CaptureController
    let take: Take
    @State private var showPopover = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        Button {
            draft = take.comment
            showPopover = true
        } label: {
            Image(systemName: take.comment.isEmpty ? "bubble.left" : "bubble.left.fill")
                .font(.system(size: 13))
                .foregroundStyle(take.comment.isEmpty ? Color.secondary : controller.accentColor)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(L("comment_help"))
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("comment_label")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(width: 240, height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.secondary.opacity(0.3)))
                    .focused($editorFocused)
                    .onAppear { editorFocused = true }
                HStack {
                    Spacer()
                    Button(L("comment_save")) {
                        controller.setComment(draft, for: take)
                        showPopover = false
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            .padding(12)
        }
    }
}

private struct RatingToggle: View {
    @EnvironmentObject private var controller: CaptureController
    let take: Take

    var body: some View {
        Button {
            controller.cycleRating(take)
        } label: {
            Group {
                switch take.rating {
                case .none:
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                case .good:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .bad:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.system(size: 13))
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(L("rating_help"))
    }
}

private struct TakeContextMenu: View {
    @EnvironmentObject private var controller: CaptureController
    let take: Take

    var body: some View {
        Button(L("play")) { controller.play(url: take.url) }
        Divider()
        Button(L("good_take")) { controller.setRating(.good, for: take) }
        Button(L("bad_take")) { controller.setRating(.bad, for: take) }
        Button(L("clear_rating")) { controller.setRating(.none, for: take) }
        Divider()
        Button(L("show_in_finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([take.url])
        }
    }
}

/// Take end TC: start + duration at the TC's own fps.
private func endTimecode(of take: Take) -> Timecode {
    let start = take.startTimecode ?? Timecode(frameNumber: 0, fps: 25, isDropFrame: false)
    let frames = Int((take.durationSeconds * Double(max(1, start.fps))).rounded())
    return Timecode(frameNumber: start.frameNumber + frames,
                    fps: start.fps, isDropFrame: start.isDropFrame)
}

private func durationText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
