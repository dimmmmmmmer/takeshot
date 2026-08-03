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
struct SlateFieldsEditor: View {
    @Binding var scene: String
    @Binding var shot: String
    /// The take number as typed. Text rather than Int so an emptied field can
    /// mean "not logged" — a numeric binding has no way to say that.
    @Binding var takeText: String

    /// The widths, and why they are these. The row has to fit inside
    /// `footerHalfWidth` alongside the 6pt gaps: 90 + 60 + 50 leaves room for a
    /// scene like "112A pickup" without touching the row above, which is the
    /// one with no slack in it.
    private static let sceneWidth: CGFloat = 90
    private static let shotWidth: CGFloat = 60
    private static let takeWidth: CGFloat = 50

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            NamingFieldsView.labeledField(L("scene"), field: .scene,
                                          width: Self.sceneWidth, text: $scene)
            NamingFieldsView.labeledField(L("slate_shot"), field: .shot,
                                          width: Self.shotWidth, text: $shot)
            NamingFieldsView.labeledField(L("slate_take"), field: .take,
                                          width: Self.takeWidth, text: $takeText)
                .help(L("slate_take_help"))
        }
    }
}
