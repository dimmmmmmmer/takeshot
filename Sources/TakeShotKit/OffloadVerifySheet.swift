import AppKit
import CaptureCore
import SwiftUI

/// "Verify disk against MHL": one folder, the manifest already on it, one pass.
///
/// Deliberately the same shape and the same width as `OffloadSheet` — it is the
/// same job at a different time, and the operator reads the result card in both
/// for the same decision. What it does not have is a form: an offload is a plan
/// the operator builds, a verify is a question about a folder, and every
/// parameter of it (the checksum included) is already written on that folder.
/// So the pass is running by the time the sheet appears.
struct OffloadVerifySheet: View {
    @ObservedObject var model: OffloadVerifyModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { content.padding(20) }
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: OffloadSheet.width)
        // A pass must not be dismissed out from under itself: this sheet is the
        // only place it can be stopped.
        .interactiveDismissDisabled(model.isRunning)
    }

    /// The sheet without its fixed frame — what the render tests measure, at
    /// the width the padding leaves it. See `OffloadSheet.content`.
    @ViewBuilder var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("verify_title"))
                .font(.headline)
            Text(L("verify_hint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            diskSection
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress = model.progress {
                Divider()
                OffloadVerifyProgressPanel(progress: progress,
                                           isCancelling: model.isCancelling)
            }
            if let report = model.report {
                Divider()
                OffloadVerifyResultPanel(report: report)
            }
        }
    }

    private var diskSection: some View {
        HStack(spacing: 10) {
            Text(L("verify_disk_label"))
                .fixedSize()
            Text(model.root?.path ?? L("offload_no_source"))
                .foregroundStyle(model.root == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            if model.isRunning {
                Button(L("verify_cancel_run")) { model.cancel() }
                    .disabled(model.isCancelling)
            }
            Spacer()
            Button(L("close")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRunning)
        }
    }
}

/// Live progress: which file is being hashed, and how far in.
///
/// One bar rather than the offload's row per destination — there is only ever
/// one disk here. The rate is the number that says whether the disk itself is
/// healthy: a drive that has started remapping sectors reads at a tenth of its
/// spec long before it starts returning wrong bytes.
struct OffloadVerifyProgressPanel: View {
    let progress: OffloadVerifyProgress
    let isCancelling: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(isCancelling
                     ? L("verify_cancelling")
                     : L("verify_progress_file", progress.currentFile))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                Text(L("offload_files_done", progress.filesDone,
                       progress.filesTotal))
                    .monospacedDigit()
                Spacer()
                Text(OffloadFormat.rate(progress.megabytesPerSecond))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            ProgressView(value: fraction)
        }
    }

    /// By bytes, not by file count: a card is one 40 GB clip and two hundred
    /// 2 KB sidecars, and a bar driven by the count sits at 99% for the half
    /// hour the clip takes.
    private var fraction: Double {
        guard progress.bytesTotal > 0 else { return 0 }
        return min(1, Double(progress.bytesRead) / Double(progress.bytesTotal))
    }
}

/// The verdict card, built like an offload destination's — this is read for the
/// same kind of decision (ship it, wipe it, keep it) and should not need a
/// second reading convention.
struct OffloadVerifyResultPanel: View {
    let report: OffloadVerifyReport

    /// Long lists are capped. A disk that lost a folder produces hundreds of
    /// rows, and a sheet hundreds of rows tall is one nobody scrolls back up to
    /// the verdict on. The count is the fact and the first few names are the
    /// lead; the manifest on the disk has the rest.
    static let listLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            card
            if !report.scanFailures.isEmpty {
                Label(L("verify_scan_problems", report.scanFailures.count),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(report.root.lastPathComponent)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(L("offload_open_dest")) {
                    NSWorkspace.shared.activateFileViewerSelecting([report.root])
                }
                .buttonStyle(.link)
            }
            Text(verdict)
                .font(.callout)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(OffloadFormat.bytes(report.bytesRead)) · "
                + "\(OffloadFormat.duration(report.span.elapsed)) · "
                + OffloadFormat.rate(report.megabytesPerSecond))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L("verify_manifest_line", report.manifest.lastPathComponent,
                   report.algorithm.displayName))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            lists
        }
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var lists: some View {
        list(L("verify_list_mismatched", report.mismatched.count),
             report.mismatched.map { "\($0.relativePath) — \($0.reason)" },
             color: .red)
        list(L("verify_list_missing", report.missing.count), report.missing,
             color: .red)
        // Secondary on purpose: a stray file says nothing about the footage the
        // manifest covers, so it is stated in the card's own quiet colour rather
        // than shouted in red beside two things that are actually wrong.
        list(L("verify_list_extra", report.extra.count), report.extra,
             color: .secondary)
    }

    @ViewBuilder
    private func list(_ title: String, _ rows: [String],
                      color: Color) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                ForEach(rows.prefix(Self.listLimit), id: \.self) { row in
                    Text(row)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if rows.count > Self.listLimit {
                    Text(L("verify_list_more", rows.count - Self.listLimit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - the verdict

    private var verdict: String {
        if report.wasCancelled {
            return L("verify_result_cancelled", report.verified.count,
                     report.filesListed)
        }
        guard report.isIntact else {
            return L("verify_result_damaged",
                     report.mismatched.count + report.missing.count,
                     report.filesListed)
        }
        return L("offload_verified_all", report.verified.count)
    }

    private var symbol: String {
        if report.wasCancelled { return "stop.circle.fill" }
        return report.isIntact
            ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var tint: Color {
        if report.wasCancelled { return .orange }
        return report.isIntact ? .green : .red
    }
}
