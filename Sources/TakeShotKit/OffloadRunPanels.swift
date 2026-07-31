import AppKit
import CaptureCore
import SwiftUI

// What the sheet shows once a run has started: the live progress, and the
// per-destination verdict afterwards.
//
// Split out of `OffloadSheet.swift`, which is the form the operator fills in.
// These two are read-only reports on a run that is already going, and the
// verdict below is the one the card gets formatted on the strength of.

/// Live progress: the file in flight, and a row per destination with its own
/// rate — one slow disk in a set of three is exactly what this is for.
struct OffloadProgressPanel: View {
    let progress: OffloadProgress
    let isCancelling: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(isCancelling
                     ? L("offload_cancelling")
                     : L("offload_progress_file", progress.currentFile))
                    .font(.callout)
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
            HStack(spacing: 8) {
                Text(destination.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let failure = destination.failure {
                    Text(failure)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(L("offload_files_done", destination.filesDone,
                           progress.filesTotal))
                        .monospacedDigit()
                    Text(OffloadFormat.rate(destination.megabytesPerSecond))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            ProgressView(value: fraction(destination))
        }
    }

    private func fraction(_ destination: OffloadDestinationProgress) -> Double {
        guard progress.bytesTotal > 0 else { return 0 }
        return min(1, Double(destination.bytesWritten) / Double(progress.bytesTotal))
    }
}

/// One card per destination once the run is over: the verdict, the numbers, and
/// a way into the folder to see the two report files.
struct OffloadResultPanel: View {
    let report: OffloadReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(report.destinations) { result in
                card(result)
            }
            if !report.run.problems.source.isEmpty {
                Label(L("offload_source_problems",
                        report.run.problems.source.count),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func card(_ result: OffloadDestinationResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol(result.outcome))
                    .foregroundStyle(color(result.outcome))
                Text(result.url.lastPathComponent)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(L("offload_open_dest")) {
                    NSWorkspace.shared.activateFileViewerSelecting([result.url])
                }
                .buttonStyle(.link)
            }
            Text(verdict(result))
                .font(.callout)
                .foregroundStyle(color(result.outcome))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(OffloadFormat.bytes(result.totals.bytesWritten)) · "
                + "\(OffloadFormat.duration(result.totals.elapsed)) · "
                + OffloadFormat.rate(result.totals.megabytesPerSecond))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let manifest = result.manifestURL {
                Text(L("offload_manifest_saved", manifest.lastPathComponent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .background(color(result.outcome).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private func verdict(_ result: OffloadDestinationResult) -> String {
        switch result.outcome {
        case .verified:
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
