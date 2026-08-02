import SwiftUI

/// Live dailies progress in the takes panel, under the utility buttons — the
/// offload strip's sibling, and the same contract: the sheet closes over a
/// running queue, so the run must stay visible from outside it, with a way
/// back in (the readout is a button) and Stop.
///
/// It appears exactly while `dailiesStatus` is set — an idle app pays nothing.
struct DailiesStatusStrip: View {
    @EnvironmentObject private var controller: CaptureController
    /// The controller's one status line, taken as a parameter so whether this
    /// view exists at all is the caller's decision (the offload strip's rule).
    let status: String
    /// Observed directly: the fraction and the file live on the model, and a
    /// view that only watched the controller would read a stale snapshot.
    @ObservedObject var dailies: DailiesQueueModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                controller.dailiesSheetPresented = true
            } label: {
                readout
            }
            .buttonStyle(.plain)
            .help(L("dailies_status_reopen"))
            Button {
                controller.dailies.cancel()
            } label: {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.borderless)
            .disabled(dailies.isCancelling)
            .fixedSize()
            .help(L("dailies_stop"))
        }
    }

    /// Three truncating lines in a 310pt panel, like the offload readout:
    /// what and how far, the bar, and the file itself. The pause icon rides
    /// the first line — the one thing worth knowing about a stopped bar.
    private var readout: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if dailies.progress?.isPaused == true {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.orange)
                }
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
            ProgressView(value: fraction)
            Text(dailies.progress?.currentFile ?? "")
                .offloadText(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    /// Whole items done plus the fraction of the one in flight — frames are
    /// the honest unit here, unlike the offload's bytes: every daily costs
    /// roughly its frame count.
    private var fraction: Double {
        dailies.progress?.overallFraction ?? 0
    }

    private var percent: Int {
        Int((fraction * 100).rounded())
    }
}
