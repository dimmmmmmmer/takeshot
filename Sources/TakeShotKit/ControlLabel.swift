import SwiftUI

/// **A control that shows only a shape has to say its name out loud.**
///
/// The app's controls are icons: the REC disc, the marker chevrons, the DIM
/// and mute buttons, the transport, the panel toggles. Each carries a `.help`,
/// which is a tooltip — a thing you see by hovering, with a mouse, while
/// looking at the screen. VoiceOver reads a button's LABEL, and the label of a
/// button whose content is a `Circle` and a `RoundedRectangle` is nothing at
/// all: the operator's most important control announced itself as "button".
///
/// Four `accessibilityLabel`s existed across roughly fifty icon-only controls,
/// and the REC button was not one of them.
///
/// The two say the same sentence on purpose. A tooltip is already written to
/// name the control and its shortcut for somebody who cannot tell what the
/// icon means, which is the same sentence a screen reader needs — so a second,
/// separately maintained string would drift, and the drift would be invisible
/// to everyone who can see the icon.
extension View {
    /// The tooltip AND the name a screen reader speaks, from one string.
    func controlHelp(_ text: String) -> some View {
        help(text).accessibilityLabel(Text(text))
    }
}
