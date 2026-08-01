import SwiftUI

/// Live offload/verify progress in the takes panel, under the utility buttons.
///
/// The sheet can be closed over a running job now, which is what the operator
/// asked for — an offload takes half an hour and the app is unusable behind a
/// modal for all of it. That trade only works if the run stays visible from the
/// outside, so this is the other half of it: what is running, how far in, which
/// file, and both of the things the sheet offers — a way back in, and Stop.
///
/// It appears exactly where the one-line `offloadStatus` used to, and only
/// while that line is set — an idle app pays nothing for it.
struct OffloadStatusStrip: View {
    @EnvironmentObject private var controller: CaptureController
    /// The one line the controller already publishes about a running job. Taken
    /// as a parameter rather than read here, so whether this view exists at all
    /// is the caller's decision — a view that renders nothing still takes a
    /// slot in its container's spacing.
    let status: String
    /// Observed directly rather than read through the controller: the fraction
    /// and the file in flight live on the models, and a view that only watched
    /// the controller would redraw on the status line and read a progress
    /// snapshot from whenever it happened to be.
    @ObservedObject var offload: OffloadSheetModel
    @ObservedObject var verify: OffloadVerifyModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                controller.showRunningDiskJob()
            } label: {
                readout(status)
            }
            .buttonStyle(.plain)
            .help(L("offload_status_reopen"))
            Button {
                controller.cancelRunningDiskJob()
            } label: {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.borderless)
            .disabled(isCancelling)
            .fixedSize()
            .help(L("offload_cancel_run"))
        }
    }

    /// Three short lines in a 310pt panel: what and how many, how far, and the
    /// file itself. Every one of them truncates rather than widening the panel
    /// — the takes list beside it is what the width is for.
    private func readout(_ status: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(status)
                    .offloadText(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                Text(L("offload_status_percent", percent))
                    .offloadText(.caption)
                    .monospacedDigit()
                    .fixedSize()
            }
            // Always a bar, never a spinner: the strip is one row in a panel
            // and a control that changes shape when the scan ends makes
            // everything under it jump.
            ProgressView(value: fraction)
            Text(currentFile)
                .offloadText(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    // MARK: - what the two jobs have in common

    private var isCancelling: Bool {
        offload.isCancelling || verify.isCancelling
    }

    /// By bytes rather than by file count, for the reason the verify sheet's own
    /// bar states: a card is one 40 GB clip and two hundred 2 KB sidecars, and a
    /// bar driven by the count sits at 99% for the half hour the clip takes.
    ///
    /// The offload's number is the destination that is furthest along — the
    /// same convention the status line's file count already uses, and the one
    /// that does not read as stalled when a second disk falls over.
    private var fraction: Double {
        if let progress = offload.progress, progress.bytesTotal > 0 {
            let written = progress.destinations.map(\.bytesWritten).max() ?? 0
            return min(1, Double(written) / Double(progress.bytesTotal))
        }
        if let progress = verify.progress, progress.bytesTotal > 0 {
            return min(1, Double(progress.bytesRead) / Double(progress.bytesTotal))
        }
        return 0
    }

    private var percent: Int {
        Int((fraction * 100).rounded())
    }

    /// The name only. The relative path is what the sheet has room for; here it
    /// would be three quarters of a truncated line of folder names.
    private var currentFile: String {
        let path = offload.progress?.currentFile
            ?? verify.progress?.currentFile ?? ""
        return (path as NSString).lastPathComponent
    }
}
