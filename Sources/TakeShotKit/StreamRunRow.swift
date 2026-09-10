import SwiftUI

/// **Start / Stop for one transport, in its settings section** (owner: "нам
/// нужна дополнительно в настройках кнопка старта/стопа на каждом из них").
///
/// The section's checkbox says the cart USES this transport — it puts the
/// badge on the main window and this block on screen. It used to also dial the
/// link, which is what made the checkbox a transmit button and left an
/// operator no way to keep SRT configured and quiet.
///
/// **A button and nothing else.** It carried a "Sending / Not sending" caption
/// for one revision, and that caption could lie: the run switch deliberately
/// stays ON when a start opens nothing — no address, no libsrt, no NDI runtime
/// — so a corrected address retries rather than needing two presses
/// (`setSRTRunning`). A caption reading the switch would have said "Sending"
/// over a link that never existed, and one reading the LINK would have
/// duplicated the status row directly below, which already says what the
/// transport is doing and why. The button's own label is honest by
/// construction: it says what pressing it will do.
///
/// One view for both transports so the two sections cannot describe the same
/// control differently, and it observes `mirrors` directly rather than the
/// whole controller — the `live` pattern this window uses for every nested
/// observable.
struct StreamRunRow: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var mirrors: DisplayMirrors
    let kind: LiveStreamKind

    /// Whether the operator has asked this transport to send — what the button
    /// acts on, and NOT whether anything is going out (see the type comment).
    private var isSwitchedOn: Bool {
        switch kind {
        case .srt: return mirrors.srtRunning
        case .ndi: return mirrors.ndiRunning
        }
    }

    /// **The button alone**, for whoever puts it somewhere.
    ///
    /// It used to be a ROW — an `HStack` with a `Spacer` shoving one button
    /// against the right margin — and read as a stray control floating beside
    /// the settings rather than belonging to any of them (owner: "не нравится
    /// что у обоих источников кнопка старт как-то несуразно выглядит сбоку
    /// отдельной строчкой"). It sits on the STATUS row now, beside the reading
    /// it changes, so the layout is the caller's business and this is only the
    /// button.
    var body: some View {
        Button(isSwitchedOn ? L("stream_stop") : L("stream_start")) {
            controller.toggleStream(kind)
        }
        .fixedSize()
        .controlSize(.small)
    }
}
