import AppKit
import CaptureCore
import SwiftUI

// What the sheet shows once a run has started: the live progress, and the
// per-destination verdict afterwards.
//
// Split out of `OffloadSheet.swift`, which is the form the operator fills in.
// These two are read-only reports on a run that is already going, and the
// verdict below is the one the card gets formatted on the strength of.
//
// Both are set in the shared type family (see `OffloadChrome`).

/// Live progress: the file in flight, and a row per destination with its own
/// rate — one slow disk in a set of three is exactly what this is for.
struct OffloadProgressPanel: View {
    let progress: OffloadProgress
    let isCancelling: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(isCancelling
                     ? L("offload_cancelling")
                     : L("offload_progress_file", progress.currentFile))
                    .offloadText(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(progress.destinations) { destination in
                row(destination)
            }
        }
    }

    private func row(_ destination: OffloadDestinationProgress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: OffloadChrome.rowSpacing) {
                Text(destination.url.lastPathComponent)
                    .offloadText(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let failure = destination.failure {
                    Text(failure)
                        .offloadText(.caption, tint: .red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(L("offload_files_done", destination.filesDone,
                           progress.filesTotal))
                        .offloadText(.caption)
                        .monospacedDigit()
                    Text(OffloadFormat.rate(destination.megabytesPerSecond))
                        .offloadText(.caption)
                        .monospacedDigit()
                }
            }
            ProgressView(value: fraction(destination))
        }
    }

    /// Both halves count: a resumed destination that already held nine tenths of
    /// the card would otherwise show an empty bar while it verifies them, which
    /// reads as "it is copying everything again" — the one thing resume is for.
    private func fraction(_ destination: OffloadDestinationProgress) -> Double {
        guard progress.bytesTotal > 0 else { return 0 }
        let done = destination.bytesWritten + destination.bytesReused
        return min(1, Double(done) / Double(progress.bytesTotal))
    }
}

/// One card per destination once the run is over: the verdict, the numbers, and
/// a way into the folder to see the report that was left there.
struct OffloadResultPanel: View {
    let report: OffloadReport

    var body: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            ForEach(report.destinations) { result in
                card(result)
            }
            if !report.run.problems.source.isEmpty {
                Label(L("offload_source_problems",
                        report.run.problems.source.count),
                      systemImage: "exclamationmark.triangle.fill")
                    .offloadText(.body, tint: .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func card(_ result: OffloadDestinationResult) -> some View {
        VStack(alignment: .leading, spacing: OffloadChrome.tightSpacing) {
            HStack(spacing: 6) {
                Image(systemName: symbol(result.outcome))
                    .foregroundStyle(color(result.outcome))
                Text(result.url.lastPathComponent)
                    .offloadText(.section)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(L("offload_open_dest")) {
                    FinderOpen.folder(result.url)
                }
                .buttonStyle(.link)
            }
            Text(verdict(result))
                .offloadText(.body, tint: color(result.outcome))
                .fixedSize(horizontal: false, vertical: true)
            // What was NOT copied, and how much of it was replaced instead of
            // trusted. The verdict above counts reused files as verified —
            // because they were, off this disk, this run — so without this line
            // the operator cannot tell an hour of copying from four minutes.
            if let resume = result.resume, resume.reused > 0 {
                Text(L("offload_result_resumed", resume.reused,
                       OffloadFormat.shortBytes(resume.reusedBytes),
                       resume.replaced.count))
                    .offloadText(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // the duration's unit WORDS follow the UI language, like the report
            Text("\(OffloadFormat.bytes(result.totals.bytesWritten)) · "
                + "\(OffloadFormat.duration(result.totals.elapsed, labels: .current())) · "
                + OffloadFormat.rate(result.totals.megabytesPerSecond))
                .offloadText(.caption)
            // The REPORT, not the manifest. The manifest is still written and
            // still named in the report itself — it is what post re-verifies
            // the disk against — but leading with the word in front of the
            // operator taught nobody anything: an editor handed "Manifest:
            // 0001_CARD_A001.mhl" does not know what they have been given. The
            // picture and the text beside it are the human artifact, so that is
            // what the card names.
            if let name = Self.reportName(result) {
                Text(L("offload_report_saved", name))
                    .offloadText(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(OffloadChrome.cardPadding)
        .background(color(result.outcome).opacity(OffloadChrome.cardTintOpacity),
                    in: RoundedRectangle(cornerRadius: OffloadChrome.cardRadius))
    }

    /// The picture if there is one, the text if the picture could not be drawn.
    /// Both carry the same facts and both are in the destination folder the
    /// button beside this line opens. Never the manifest: a destination that got
    /// neither report says nothing here rather than falling back to the file the
    /// operator was not meant to be handed.
    static func reportName(_ result: OffloadDestinationResult) -> String? {
        (result.imageURL ?? result.summaryURL)?.lastPathComponent
    }

    private func verdict(_ result: OffloadDestinationResult) -> String {
        switch result.outcome {
        case .verified:
            // A verify that could not bypass the page cache still compared the
            // hashes — it just cannot promise it read the DISK, which is the
            // whole point of the pass before a card is wiped. Said on the same
            // line rather than as a separate warning: it qualifies this verdict
            // and belongs where the verdict is read.
            guard result.unbypassedVerifies == 0 else {
                return L("offload_verified_uncached",
                         result.totals.filesVerified,
                         result.unbypassedVerifies)
            }
            return L("offload_verified_all", result.totals.filesVerified)
        case .mismatched:
            return result.mismatches.isEmpty
                ? L("offload_result_incomplete", result.totals.filesVerified,
                    result.totals.filesTotal)
                : L("offload_result_mismatch", result.mismatches.count)
        case .failed:
            return L("offload_result_failed", result.failure ?? "")
        case .cancelled:
            return L("offload_result_cancelled", result.totals.filesVerified,
                     result.totals.filesTotal)
        }
    }

    private func symbol(_ outcome: OffloadOutcome) -> String {
        switch outcome {
        case .verified: return "checkmark.seal.fill"
        case .mismatched: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    private func color(_ outcome: OffloadOutcome) -> Color {
        switch outcome {
        case .verified: return .green
        case .mismatched, .cancelled: return .orange
        case .failed: return .red
        }
    }
}
