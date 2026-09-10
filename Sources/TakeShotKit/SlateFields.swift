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
/// **Where the height went, and where it came back.** Each field was a caption
/// STACKED over a box; three of those made the footer a caption-line taller
/// than the picture could spare, so the captions moved BESIDE their fields and
/// the row cost one control's height. They are back above them now (owner:
/// "подписи scene shot take в мете должны быть над полями ввода") — this
/// paragraph described the middle state for a while after that, which is how a
/// reader ended up with two adjacent paragraphs saying opposite things. The
/// captions are the file-name row's: same 9pt semibold, same caps
/// (SCENE/SHOT/TAKE beside CAM/ROLL/CLIP), same place.
///
/// **The captions must fit their own boxes, and that is load-bearing.** These
/// three are the only localized strings in the footer's right half, and the
/// footer's REC button is centered by that half measuring the same in English
/// and in Russian (`ViewFooterTests`). They sit ABOVE their boxes now (owner:
/// "подписи scene shot take в мете должны быть над полями ввода"), and a
/// caption is `.fixedSize()` — so one wider than the box under it widens the
/// whole column and pushes the REC button off centre in one language only.
///
/// There used to be a fixed 36pt caption box for this, from when the caption
/// sat BESIDE its field; the frame was deleted with that layout and the
/// constant, its doc and the test that measured against it all outlived it —
/// so the test compared a measured width to a number nothing applied and could
/// not fail. What is measured now is the real constraint: each caption against
/// the width of its own field, in both languages.
struct SlateFieldsEditor: View {
    @Binding var scene: String
    @Binding var shot: String
    /// The take number as typed. Text rather than Int so an emptied field can
    /// mean "not logged" — a numeric binding has no way to say that.
    @Binding var takeText: String
    /// The reel, WHEN the file name does not carry it.
    ///
    /// The roll is edited in exactly one place, and which place depends on
    /// what the template does with it: on the file-name row when the name is
    /// built out of it, here when it is not. A preset like Sony's legacy
    /// scheme names files `C0001` and takes no roll, so a ROLL box under the
    /// file name is a box that has nothing to do with the name beside it
    /// (owner: "в интерфейсе остается текстовый бокс под название ролла").
    ///
    /// It cannot simply be dropped: the reel is written into the take's own
    /// metadata, into the Reel Name column of `takeshot-log.csv` and the ALE,
    /// into the EDL's reel and onto the slate — and the clip counter RESTARTS
    /// on it, which under `C{clip}` is the only thing that decides whether the
    /// next take is C0001 or C0042. The footer field is the only editor of it
    /// in the whole app, so hiding it without a home would make all of that
    /// uneditable while every consumer went on writing it.
    var roll: Binding<String>?
    /// The roll's arrows, which are NOT the slate's own paging: stepping a
    /// reel is `CaptureController.stepRoll`, and it restarts the clip counter
    /// on the way. Passing the same closure the file-name row passes is what
    /// keeps the two homes of one field the same CONTROL rather than two
    /// controls that look alike.
    var onStepRoll: (Int) -> Void = { _ in }

    /// The widths, and why they are these. Every field's group is
    /// caption + ‹ + box + ›, and the three of them plus the gaps have to fit
    /// `footerHalfWidth` (363pt at the app's minimum window). Scene keeps the
    /// most of it: it is the one that holds more than a number or a letter.
    /// Internal, not private: `ViewNamingRowTests` measures each caption
    /// against the field it sits over, which is the constraint that keeps the
    /// footer's halves equal in both languages.
    static let sceneWidth: CGFloat = 70
    static let shotWidth: CGFloat = 32
    /// Four digits of monospaced text plus the box's own insets.
    static let takeWidth: CGFloat = 36
    /// Same box the file-name row gives the reel, so the two homes of one
    /// value are the same size.
    static let rollWidth: CGFloat = 46

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
            if let roll {
                NamingFieldsView.steppedField(
                    L("roll_label"), field: .roll, width: Self.rollWidth,
                    text: roll, onStep: onStepRoll)
            }
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
            },
            canStep: { SlateStep.canStep(text.wrappedValue, by: $0) })
    }
}
