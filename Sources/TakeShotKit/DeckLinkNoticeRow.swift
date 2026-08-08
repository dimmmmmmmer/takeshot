import SwiftUI

/// What the operator is told, where the device is chosen, when this build
/// cannot see a board.
///
/// This row and not only the overlay over the picture, and that IS the change.
/// The demo source is in every build's device list unconditionally (see
/// `MockCaptureBackend` and CLAUDE.md's "Demo source"), which is what keeps a
/// downloaded app usable at all — but it also means a stub build selects it,
/// captures from it, and `LiveStatusOverlay` never appears. The only place the
/// operator meets the missing hardware is the picker directly above this row:
/// one entry, no explanation, and a real UltraStudio plugged in beside it.
///
/// Not a toast either. Every state this shows survives a relaunch — a binary
/// built without the SDK, a machine without Desktop Video, a signature that
/// refuses the framework — and each needs a different thing done to it, so it
/// stays on screen for as long as it is true.
///
/// Draws nothing when the build can see boards: `noticeTitle` is nil for
/// `.loaded`, and an operator with a working build has nothing to read here.
struct DeckLinkNoticeRow: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        if let title = DeckLinkProbe.current.noticeTitle,
           let detail = DeckLinkProbe.current.noticeDetail {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // a Form row TRUNCATES a Text it cannot fit rather than
                    // wrapping it, and the signature case's remedy is the last
                    // clause of its sentence
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // the entitlement name is something the reader has to paste into a
            // codesign command, not retype
            .textSelection(.enabled)
        }
    }
}
