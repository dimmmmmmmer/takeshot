import AppKit
import CaptureCore
import SwiftUI

/// The DIT offload sheet: one card, a list of destinations, one pass.
///
/// It replaces two chained modal file panels. The panels could not show what
/// this has to: several destinations at once, which file is being copied, the
/// rate each disk is managing, and a per-destination verdict at the end. The
/// operator also has to be able to stop it safely, which a modal panel flow has
/// nowhere to put.
struct OffloadSheet: View {
    @ObservedObject var model: OffloadSheetModel
    @Environment(\.dismiss) private var dismiss

    /// Wide enough for a full destination path at a readable size; the sheet is
    /// fixed so the layout cannot shift as paths change length.
    static let width: CGFloat = 620

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable, and the footer pinned below it: four destinations plus
            // a result card each is taller than the app's minimum window, and a
            // sheet is clamped to its window — Start and Stop have to stay
            // reachable rather than be the part that gets clipped off.
            ScrollView { content.padding(20) }
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: Self.width)
        // A run must not be dismissed out from under itself: the sheet is the
        // only place the operator can stop it, and closing it would leave a
        // half-copied card with nothing reporting on it.
        .interactiveDismissDisabled(model.isRunning)
    }

    /// The sheet without its fixed frame.
    ///
    /// Separate because that frame is also what hides a layout that does not
    /// fit: content wider than `width` is clipped silently, and a view whose
    /// width is pinned reports the pin rather than what it needed. The render
    /// tests measure this, at the width the padding leaves it.
    @ViewBuilder var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("offload_title"))
                .font(.headline)
            sourceSection
            Divider()
            destinationSection
            checksumSection
            if let warning = model.validationMessage {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let progress = model.progress {
                Divider()
                OffloadProgressPanel(progress: progress,
                                     isCancelling: model.isCancelling)
            }
            if let report = model.report {
                Divider()
                OffloadResultPanel(report: report)
            }
        }
    }

    // MARK: - source

    private var sourceSection: some View {
        HStack(spacing: 10) {
            Text(L("offload_source_label"))
                .fixedSize()
            Text(model.source?.path ?? L("offload_no_source"))
                .foregroundStyle(model.source == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("choose")) {
                if let url = OffloadPanels.pickFolder(
                    message: L("offload_pick_source"),
                    prompt: L("offload_source_prompt")) {
                    model.source = url
                }
            }
            .disabled(model.isRunning)
        }
    }

    // MARK: - destinations

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("offload_dest_label"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    if let url = OffloadPanels.pickFolder(
                        message: L("offload_pick_dest"),
                        prompt: L("offload_dest_prompt")) {
                        model.addDestination(url)
                    }
                } label: {
                    Label(L("offload_add_dest"), systemImage: "plus")
                }
                .disabled(model.isRunning)
            }
            if model.rows.isEmpty {
                Text(L("offload_no_dest"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.rows) { row in
                destinationRow(row)
            }
            Text(L("offload_reports_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func destinationRow(_ row: OffloadSheetModel.Row) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.url.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let folder = model.destinationFolder(for: row) {
                    Text("→ \(folder.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(L("offload_dest_target_help"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("choose")) {
                if let url = OffloadPanels.pickFolder(
                    message: L("offload_pick_dest"),
                    prompt: L("offload_dest_prompt")) {
                    model.setDestination(url, at: row.id)
                }
            }
            .disabled(model.isRunning)
            Button {
                model.removeDestination(row.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(model.isRunning)
            .help(L("offload_remove_dest"))
        }
    }

    // MARK: - checksum

    private var checksumSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(L("offload_hash_label"), selection: $model.algorithm) {
                ForEach(OffloadHashAlgorithm.allCases) { algorithm in
                    Text(algorithm.displayName).tag(algorithm)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isRunning)
            Text(L("offload_hash_help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - footer

    private var footer: some View {
        HStack {
            if model.isRunning {
                Button(L("offload_cancel_run")) { model.cancel() }
                    .disabled(model.isCancelling)
            }
            Spacer()
            Button(L("close")) { dismiss() }
                .disabled(model.isRunning)
            Button(L("offload_start")) { model.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
        }
    }
}

/// The file panels the sheet opens. Kept out of the model so everything the
/// model does stays reachable from a test.
enum OffloadPanels {
    @MainActor
    static func pickFolder(message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

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
            if !report.sourceFailures.isEmpty {
                Label(L("offload_source_problems", report.sourceFailures.count),
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
            Text("\(OffloadFormat.bytes(result.bytesWritten)) · "
                + "\(OffloadFormat.duration(result.elapsed)) · "
                + OffloadFormat.rate(result.megabytesPerSecond))
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
            return L("offload_verified_all", result.filesVerified)
        case .mismatched:
            return result.mismatches.isEmpty
                ? L("offload_result_incomplete", result.filesVerified,
                    result.filesTotal)
                : L("offload_result_mismatch", result.mismatches.count)
        case .failed:
            return L("offload_result_failed", result.failure ?? "")
        case .cancelled:
            return L("offload_result_cancelled", result.filesVerified,
                     result.filesTotal)
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
