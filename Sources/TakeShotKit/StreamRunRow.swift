import SwiftUI

/// **Start / Stop for one transport, in its settings section** (owner: "нам
/// нужна дополнительно в настройках кнопка старта/стопа на каждом из них").
///
/// The section's checkbox says the cart USES this transport — it puts the badge
/// on the main window and this block on screen. It used to also dial the link,
/// which is what made the checkbox a transmit button and left an operator no
/// way to keep SRT configured and quiet.
///
/// One view for both transports so the two sections cannot end up describing
/// the same control differently, and so the state it reads is the state the
/// badge reads: `mirrors` publishes both, and the row observes it directly
/// rather than the whole controller — the `live` pattern this window uses for
/// every other nested observable.
struct StreamRunRow: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var mirrors: DisplayMirrors
    let kind: LiveStreamKind

    private var isRunning: Bool {
        switch kind {
        case .srt: return mirrors.srtRunning
        case .ndi: return mirrors.ndiRunning
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(isRunning ? L("stream_running") : L("stream_stopped"))
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 4)
            Button(isRunning ? L("stream_stop") : L("stream_start")) {
                controller.toggleStream(kind)
            }
            .fixedSize()
        }
    }
}
