import CaptureCore
import SwiftUI

/// Scene / shot / take over whatever bindings the caller owns — the footer's
/// second naming row drives the slate of the NEXT take, the takes panel drives
/// one recorded take's copy. One layout, so the two can never grow apart.
///
/// These used to be a popover behind a chip in the naming row (owner item 27).
/// They are fields now, in the footer, under the fields that name the file: the
/// slate is filled in between takes, on set, and a control you have to open
/// before you can type into it is one nobody keeps up to date.
///
/// **Compact, and where the height went.** Each field used to be a caption
/// STACKED over a box, the shape the file-name row above uses, and three of
/// those made the whole footer a caption-line taller than the picture could
/// spare — the owner's complaint. The caption sits beside its field here
/// instead, so the row costs exactly one control's height (about 14pt less than
/// the stack), and each field has the pair of arrows he asked for. The captions
/// are still the row above's: same 9pt semibold, same caps (SCENE/SHOT/TAKE
/// beside CAM/ROLL/CLIP), only turned through ninety degrees.
///
/// **The caption box is a FIXED width, and that is load-bearing.** These three
/// captions are the only localized strings in the footer's right half, and the
/// footer's REC button is centered by that half measuring the same in English
/// and in Russian (`ViewFooterTests`). Stacked, the caption was narrower than
/// the box under it and cost nothing; beside it, it would charge the row
/// whatever "СЦЕНА" happens to measure. A fixed box makes the row's width a
/// constant again — and `ViewNamingRowTests` measures both languages' captions
/// against it, because the failure mode of a box too small is a silently
/// truncated word.
struct SlateFieldsEditor: View {
    @Binding var scene: String
    @Binding var shot: String
    /// The take number as typed. Text rather than Int so an emptied field can
    /// mean "not logged" — a numeric binding has no way to say that.
    @Binding var takeText: String

    /// The widths, and why they are these. Every field's group is
    /// caption + ‹ + box + ›, and the three of them plus the gaps have to fit
    /// `footerHalfWidth` (363pt at the app's minimum window). Scene keeps the
    /// most of it: it is the one that holds more than a number or a letter.
    private static let sceneWidth: CGFloat = 70
    private static let shotWidth: CGFloat = 32
    /// Four digits of monospaced text plus the box's own insets.
    private static let takeWidth: CGFloat = 36
    /// The caption box. Must hold the longest of SCENE/SHOT/TAKE and
    /// СЦЕНА/КАДР/ДУБЛЬ — pinned in the render tests, not eyeballed.
    static let captionWidth: CGFloat = 36
    /// One arrow. Both dimensions fixed: a chevron that resized with its state
    /// would shuffle the row under the operator's pointer.
    private static let arrowWidth: CGFloat = 13
    /// Half the row's height each, so the pair is the height one arrow used to
    /// be and the row does not grow.
    private static let arrowHeight: CGFloat = 9

    /// What the takes panel's popover sizes its other rows to, so the whole
    /// editor reads as one block rather than a wide slate row over narrow
    /// boxes. Stated here because this row is what sets the width.
    static let popoverContentWidth: CGFloat = 330

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            pagedField(L("scene"), field: .scene, width: Self.sceneWidth,
                       seed: "1", text: $scene)
            pagedField(L("slate_shot"), field: .shot, width: Self.shotWidth,
                       seed: "1", text: $shot)
            pagedField(L("slate_take"), field: .take, width: Self.takeWidth,
                       seed: "1", text: $takeText)
                .help(L("slate_take_help"))
        }
    }

    /// One slate field, built by the SAME function the file-name row's fields
    /// are built by.
    ///
    /// It used to draw its own chevrons, which is why they did not look like
    /// the ones one row away (owner: "почему стрелки вверх/вниз в мете не
    /// похожи на вверх/вниз там где название файла") — a hand-drawn pair
    /// beside a native `Stepper`. Now that both rows put the caption above the
    /// box there is nothing left that differed, so there is no second builder:
    /// the two rows are the same control with different labels.
    ///
    /// `seed` is what an empty field becomes on the first press up, and all
    /// three are "1": scene, shot and take are counted the same way. Stepping
    /// is `SlateStep`, including the part that matters most here — down off the
    /// first value empties the field again, so "not logged" stays reachable
    /// without going for the keyboard.
    private func pagedField(_ caption: String, field: NameField, width: CGFloat,
                            seed: String,
                            text: Binding<String>) -> some View {
        NamingFieldsView.steppedField(
            caption, field: field, width: width, text: text,
            onStep: { delta in
                text.wrappedValue = SlateStep.stepped(text.wrappedValue,
                                                      by: delta, seed: seed)
            })
    }
}
