import CaptureCore
import Foundation

/// Which half of the naming block the footer is showing.
///
/// The two used to be STACKED — the file-name fields on top, the slate under
/// them — because CAM + ROLL + CLIP + POSTFIX already spend most of the
/// footer's half and three more labelled fields overflow it, which pushes the
/// centered REC button off centre. Wrapping to a second row respected that
/// budget by costing a row of height instead.
///
/// A switch spends neither (owner: "просто переключатель как рек/плейбэк только
/// будет в подвале file/meta, ну для выбора того что писать"). One row is on
/// screen at a time, so the footer is a row shorter than it was AND each half
/// gets the whole width — which is what pays for the slate row's fields being
/// wider than they were.
///
/// It is a choice about which control is in front of the operator and nothing
/// else: both halves are always recorded, whichever one is showing. That is
/// what keeps it clear of "Settings the app deliberately does not offer" —
/// there is no measurement here to contradict.
enum NamingPane: String, CaseIterable, Identifiable, Sendable {
    /// What the file is called: prefix, cam, roll, clip, postfix.
    case file
    /// What was shot: scene, shot, take.
    case meta

    var id: String { rawValue }

    var titleKey: String { "naming_pane_" + rawValue }
}
