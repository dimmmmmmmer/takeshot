import CaptureCore
import SwiftUI

/// Панель дублей: список или сетка миниатюр, отметка circle take
/// (уходит в takeshot-log.csv как Good Take для DaVinci Resolve).
/// Ниже — Other content: файлы, попавшие в папку записи мимо TakeShot.
/// Граница между секциями перетаскивается (VSplitView).
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

// MARK: - секция дублей

private struct TakesSection: View {
    @EnvironmentObject private var controller: CaptureController
    @AppStorage("takesViewMode") private var viewMode = "list"
    @AppStorage("gridTileSize") private var tileSize = 150.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(L("takes"))
                    .font(.headline)
                Button {
                    controller.openDestinationInFinder()
                } label: {
                    Label(L("open"), systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .controlSize(.small)
                .fixedSize()
                .help(L("open_folder"))
                Spacer()
                if viewMode == "grid" {
                    Slider(value: $tileSize, in: 110...260)
                        .frame(width: 70)
                        .controlSize(.mini)
                        .help(L("tile_size"))
                }
                ViewModePicker(mode: $viewMode)

                Menu {
                    Button(L("reveal_csv")) {
                        NSWorkspace.shared.activateFileViewerSelecting([controller.takeLogURL])
                    }
                    .disabled(controller.takes.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
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
                }
                .listStyle(.inset)
            }
        }
    }
}

func gridColumns(size: Double) -> [GridItem] {
    [GridItem(.adaptive(minimum: size, maximum: size * 1.6), spacing: 10)]
}

/// Переключатель список/миниатюры (общий стиль для обеих секций).
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
            VStack(alignment: .leading, spacing: 2) {
                Text(take.displayName)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let tc = take.startTimecode {
                        Text(tc.description)
                    }
                    Text(durationText(take.durationSeconds))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            RatingToggle(take: take)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { controller.play(url: take.url) }
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
            .overlay(alignment: .topTrailing) {
                RatingToggle(take: take)
                    .padding(4)
                    .background(.black.opacity(0.45), in: Circle())
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
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { controller.play(url: take.url) }
        .contextMenu { TakeContextMenu(take: take) }
    }
}

// MARK: - Other content

private struct OtherContentSection: View {
    @EnvironmentObject private var controller: CaptureController
    @AppStorage("otherViewMode") private var viewMode = "list"
    @AppStorage("gridTileSize") private var tileSize = 150.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(L("other_content"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if viewMode == "grid" {
                    Slider(value: $tileSize, in: 110...260)
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
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { controller.play(url: url) }
                    .contextMenu { OtherContextMenu(url: url) }
                }
                .listStyle(.inset)
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

// MARK: - общее

private struct RatingToggle: View {
    @EnvironmentObject private var controller: CaptureController
    let take: Take

    var body: some View {
        Button {
            controller.cycleRating(take)
        } label: {
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

private func durationText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
