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
            HStack {
                Text(L("offload_history_title"))
                    .offloadText(.section)
                Spacer(minLength: 8)
                // **A way to empty it**, asked for twice (owner: "возможность
                // почистить было бы классно иметь"; "recent offloads так и не
                // чистятся?"). The list is kept on purpose — an old row is how
                // an operator answers "has this card been copied" weeks later —
                // and that is exactly why it needs a way out: a list nobody can
                // empty is a list that stops being read. Beside the ledger's
                // own, in the same place and the same shape.
                if !store.runs.isEmpty {
                    Button(L("offload_history_clear")) { store.clear() }
                        .buttonStyle(.link)
                        .help(L("offload_history_clear_help"))
                }
            }
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

    /// `CARD_A001 → /Volumes/SSD_1/DAY_03` for one copy, `→ 3 copies` for
    /// several.
    ///
    /// The PATH and not the last component (owner: "recent offloads должен
    /// показывать paths, а не имена скопированных папок"). Two shuttle drives
    /// with a `DAILIES` folder each produce two rows that read identically, and
    /// the question this log answers — "have I copied this card, and where to?"
    /// — is exactly the one a folder name cannot. Several destinations still
    /// collapse to a count: four paths on one line is worth less than the
    /// number, and the run's own summary beside the copy lists them.
    static func headline(_ run: OffloadRunRecord) -> String {
        let target = run.destinationPaths.count == 1
            ? run.destinationURLs[0].path
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
    /// is the common case for an old run; `FinderOpen` is the one place that
    /// decides what to do about it, and it does nothing rather than open a
    /// window on a vanished path.
    @MainActor
    static func reveal(_ run: OffloadRunRecord) {
        guard let present = run.destinationURLs.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else { return }
        FinderOpen.folder(present)
    }
}
