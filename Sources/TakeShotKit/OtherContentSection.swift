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
        Button(L("delete_item"), role: .destructive) {
            controller.deleteOtherFile(url)
        }
        Button(L("show_in_finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

// The list is the scanner's own (`CaptureController.imageExtensions`) rather
// than a copy: a copy drifts, and a still on the drifted side gets listed by
// the panel while the player treats it as video.
private func iconName(for url: URL) -> String {
    CaptureController.imageExtensions
        .contains(url.pathExtension.lowercased()) ? "photo" : "film"
}
