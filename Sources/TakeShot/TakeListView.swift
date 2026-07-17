import CaptureCore
import SwiftUI

/// Панель дублей: список или сетка миниатюр, отметка circle take
/// (уходит в takeshot-log.csv как Good Take для DaVinci Resolve).
struct TakeListView: View {
    @EnvironmentObject private var controller: CaptureController
    @AppStorage("takesViewMode") private var viewMode = "list"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("takes"))
                    .font(.headline)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([controller.takeLogURL])
                } label: {
                    Image(systemName: "tablecells")
                }
                .buttonStyle(.plain)
                .help(L("reveal_csv_help"))
                .disabled(controller.takes.isEmpty)
                Picker("", selection: $viewMode) {
                    Image(systemName: "list.bullet").tag("list")
                        .help(L("view_list"))
                    Image(systemName: "square.grid.2x2").tag("grid")
                        .help(L("view_grid"))
                }
                .pickerStyle(.segmented)
                .frame(width: 70)
                .labelsHidden()
            }
            .padding(12)
            Divider()
            if controller.takes.isEmpty {
                Spacer()
                Text(L("no_takes_yet"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if viewMode == "grid" {
                TakeGridView()
            } else {
                List(controller.takes.reversed()) { take in
                    TakeRow(take: take)
                }
                .listStyle(.inset)
            }
        }
    }
}

// MARK: - список

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
            CircleToggle(take: take)
        }
        .contextMenu { TakeContextMenu(take: take) }
    }
}

// MARK: - сетка миниатюр

private struct TakeGridView: View {
    @EnvironmentObject private var controller: CaptureController

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(controller.takes.reversed()) { take in
                    TakeCell(take: take)
                }
            }
            .padding(10)
        }
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
                CircleToggle(take: take)
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
        .contextMenu { TakeContextMenu(take: take) }
    }
}

// MARK: - общее

private struct CircleToggle: View {
    @EnvironmentObject private var controller: CaptureController
    let take: Take

    var body: some View {
        Button {
            controller.toggleCircle(take)
        } label: {
            Image(systemName: take.isCircled ? "circle.circle.fill" : "circle")
                .foregroundStyle(take.isCircled ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .help(L("circle_take_help"))
    }
}

private struct TakeContextMenu: View {
    @EnvironmentObject private var controller: CaptureController
    let take: Take

    var body: some View {
        Button(take.isCircled ? L("uncircle_take") : L("circle_take")) {
            controller.toggleCircle(take)
        }
        Button(L("show_in_finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([take.url])
        }
    }
}

private func durationText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
