import AppKit
import SwiftUI

/// Past offloads, at the bottom of the offload sheet.
///
/// Visible the moment the sheet opens, before anything is picked — that is the
/// whole point of it. The question it answers ("have I already copied this
/// card?") is asked precisely when nothing is running, and an answer that only
/// appears after a run would be an answer to a different question.
///
/// The header is drawn even when the list is empty. A section that comes and
/// goes moves everything under it, and on the first shooting day the empty line
/// is itself the answer.
struct OffloadHistoryList: View {
    @ObservedObject var store: OffloadHistoryStore

    /// Local, so the row text does not change shape with the machine's clock
    /// settings mid-session. Short/short: this is scanned, not read.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            Text(L("offload_history_title"))
                .offloadText(.section)
            if store.runs.isEmpty {
                Text(L("offload_history_empty"))
                    .offloadText(.caption)
            }
            ForEach(store.runs) { run in
                row(run)
            }
        }
    }

    /// One run. The whole row is the button: the thing an operator wants from
    /// this list is to go and look at the disk, and a separate "reveal" control
    /// per row would be four more targets in a list that is already dense.
    private func row(_ run: OffloadRunRecord) -> some View {
        Button {
            Self.reveal(run)
        } label: {
            HStack(spacing: OffloadChrome.rowSpacing) {
                Image(systemName: Self.symbol(run.verdict))
                    .foregroundStyle(Self.tint(run.verdict))
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.headline(run))
                        .offloadText(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Self.detail(run))
                        .offloadText(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(L(Self.verdictKey(run.verdict)))
                    .offloadText(.caption, tint: Self.tint(run.verdict))
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("offload_history_reveal"))
    }

    // MARK: - what a row says

    /// `CARD_A001 → DAILIES_SSD_1` for one copy, `→ 3 copies` for several. The
    /// name of the single destination is worth more than the number 1, and four
    /// destination names on one line is worth less than the count.
    static func headline(_ run: OffloadRunRecord) -> String {
        let target = run.destinationPaths.count == 1
            ? run.destinationURLs[0].lastPathComponent
            : L("offload_history_copies", run.destinationPaths.count)
        return "\(run.sourceName) → \(target)"
    }

    static func detail(_ run: OffloadRunRecord) -> String {
        "\(formatter.string(from: run.date)) · "
            + L("offload_history_files", run.filesVerified, run.files)
    }

    static func verdictKey(_ verdict: OffloadRunRecord.Verdict) -> String {
        switch verdict {
        case .verified: return "offload_history_ok"
        case .problems: return "offload_history_problems"
        case .cancelled: return "offload_history_stopped"
        case .failed: return "offload_history_failed"
        }
    }

    /// The same symbols and colours the result card uses, so a row here and the
    /// card it came from cannot disagree about how the run ended.
    static func symbol(_ verdict: OffloadRunRecord.Verdict) -> String {
        switch verdict {
        case .verified: return "checkmark.seal.fill"
        case .problems: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    static func tint(_ verdict: OffloadRunRecord.Verdict) -> Color {
        switch verdict {
        case .verified: return .green
        case .problems, .cancelled: return .orange
        case .failed: return .red
        }
    }

    /// The first destination still on the machine. A disk that is not mounted
    /// is the common case for an old run, and the Finder is handed the folder
    /// only when it is actually there — `activateFileViewerSelecting` on a
    /// vanished path opens a window on nothing.
    @MainActor
    static func reveal(_ run: OffloadRunRecord) {
        let present = run.destinationURLs.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard let present else { return }
        NSWorkspace.shared.activateFileViewerSelecting([present])
    }
}
