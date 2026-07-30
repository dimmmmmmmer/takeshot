import SwiftUI

/// Close behaviour shared by the panels that float over the player (the scopes
/// overlay today, the audio panel next).
///
/// The three rules an operator expects from something covering the picture, and
/// the mechanism each one uses:
///
/// 1. **Esc closes it** — `EscapeKeyCatcher`, an invisible `Button` carrying the
///    key equivalent. SwiftUI resolves key equivalents through the view tree,
///    not the focus chain, so the panel does not have to be focused (and no
///    control inside it steals the key).
/// 2. **A click on the picture closes it** — `dismissesPlayerOverlays()` on the
///    viewer surface. A `simultaneousGesture` rather than an invisible
///    full-player click catcher: a catcher would have to sit above the image and
///    would eat the punch-in pan drag, which is exactly what the operator does
///    while watching the scopes. Simultaneous recognition lets the pan and the
///    tap coexist, and a drag never fires a `TapGesture`. It is attached to the
///    IMAGE, not to the player card, so the transport and the badges keep
///    working while a panel is open.
/// 3. **Opening another one closes it** — the `didSet` observers on the flags
///    themselves (`showAudioPanel`, `showScopesOverlay`), so every call site
///    gets the behaviour: badge, footer button, hotkey.
///
/// None of the three needs a close button, which is why the scopes overlay has
/// none.
extension CaptureController {
    /// The panels that float over the player, at most one at a time.
    enum PlayerOverlay {
        case audio
        case scopes
    }

    /// Close every player overlay but the one that just opened.
    func closeOtherPlayerOverlays(except kept: PlayerOverlay) {
        if kept != .audio, showAudioPanel { showAudioPanel = false }
        if kept != .scopes, showScopesOverlay { showScopesOverlay = false }
    }

    /// The audio panel was opened or closed. Called from the flag's observer,
    /// so badge, footer button and hotkey all get it.
    func applyAudioPanelChange() {
        if showAudioPanel { closeOtherPlayerOverlays(except: .audio) }
    }

    /// The scopes overlay was opened or closed. It also re-routes the
    /// analyzers: they only run for a surface that is actually on screen.
    func applyScopesOverlayChange() {
        if showScopesOverlay { closeOtherPlayerOverlays(except: .scopes) }
        updateScopesRunning()
    }

    /// A panel is covering the picture.
    var anyPlayerOverlayOpen: Bool { showAudioPanel || showScopesOverlay }

    /// Close whatever is covering the picture (Esc, or a click on the image).
    func dismissPlayerOverlays() {
        if showScopesOverlay { showScopesOverlay = false }
        if showAudioPanel { showAudioPanel = false }
    }
}

/// Esc for an overlay that has no close button: an invisible button carrying
/// the key equivalent (see the note above for why this and not `onExitCommand`).
struct EscapeKeyCatcher: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Clicking the picture closes whatever panel is floating over it.
    ///
    /// Simultaneous, so the punch-in pan drag on the same view still works and
    /// a drag does not count as a click.
    func dismissesPlayerOverlays(_ controller: CaptureController) -> some View {
        simultaneousGesture(TapGesture().onEnded {
            controller.dismissPlayerOverlays()
        }, including: controller.anyPlayerOverlayOpen ? .all : .subviews)
    }
}
