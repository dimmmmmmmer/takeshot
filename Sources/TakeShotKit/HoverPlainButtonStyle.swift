import SwiftUI

/// **A plain button that says it is a button when the pointer is on it**
/// (owner: "давай по кнопкам везде вообще какую-то ховер анимацию сделаем а то
/// не всегда ясно что это кнопка").
///
/// `.plain` draws the label and nothing else, which is right for a bar of
/// glyphs over a picture and leaves an operator guessing which of the things
/// on screen can be pressed. This is the same style with two additions: a
/// plate under the pointer, and a dip while the mouse is down.
///
/// **It must not change the layout, and that is the whole difficulty.** Half
/// the controls in this app sit in rows measured against a width budget — the
/// naming block, the footer, the compare bar — so the plate is drawn as a
/// BACKGROUND with a negative inset: a background is sized to the label and is
/// allowed to overflow it, so the highlight is bigger than the glyph while the
/// glyph occupies exactly what it did before. Padding on the label itself
/// would move every row it is in.
struct HoverPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Plate(configuration: configuration)
    }

    /// The state has to live in a VIEW, not in the style: a `ButtonStyle` is a
    /// value that is re-made on every render and cannot hold `@State`.
    private struct Plate: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: HoverPlainButtonStyle.radius)
                        .fill(Color.primary.opacity(hovering ? 0.12 : 0))
                        .padding(-HoverPlainButtonStyle.inset)
                }
                // Pressed reads even where the plate does not — over a bright
                // picture a 12 % plate is nearly nothing, and the dip is what
                // says the press landed.
                .opacity(configuration.isPressed ? 0.55 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: HoverPlainButtonStyle.fade),
                           value: hovering)
        }
    }

    /// How far the plate grows past the label, in points. Three: enough to
    /// read as a target around a 13pt glyph, small enough that two buttons two
    /// points apart do not draw one continuous bar.
    static let inset: CGFloat = 3
    static let radius: CGFloat = 5
    /// Fast enough to feel attached to the pointer and slow enough to be an
    /// animation rather than a flicker as the mouse crosses a row.
    static let fade: Double = 0.12
}

extension ButtonStyle where Self == HoverPlainButtonStyle {
    /// `.plain`, plus the hover plate — see `HoverPlainButtonStyle`.
    static var hoverPlain: HoverPlainButtonStyle { HoverPlainButtonStyle() }
}
