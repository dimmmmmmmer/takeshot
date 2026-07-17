import CaptureCore
import SwiftUI

/// Список записанных дублей: имя, TC старта, длительность, отметка circle take.
struct TakeListView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Дубли")
                .font(.headline)
                .padding(12)
            Divider()
            if controller.takes.isEmpty {
                Spacer()
                Text("Дублей пока нет")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(controller.takes.reversed()) { take in
                    TakeRow(take: take)
                }
                .listStyle(.inset)
            }
        }
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
                    Text(Self.durationText(take.durationSeconds))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                controller.toggleCircle(take)
            } label: {
                Image(systemName: take.isCircled ? "circle.circle.fill" : "circle")
                    .foregroundStyle(take.isCircled ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Circle take — пометить удачный дубль")
        }
        .contextMenu {
            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([take.url])
            }
        }
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
