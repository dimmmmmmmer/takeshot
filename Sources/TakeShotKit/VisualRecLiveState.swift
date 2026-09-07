import CaptureCore
import Foundation

/// The taught REC indicator exactly as the picture and the panel are showing
/// it — the published controller state plus whatever a drag or a slider has
/// changed since.
///
/// Its own observable object for the reason `AssistLiveState` is one, and it
/// is the same lag one control along. `visualRecTeaching` is `@Published` on
/// the controller, so a write per drag tick fires `objectWillChange` on
/// `CaptureController` and re-lays out every view in the window — the whole
/// panel, the takes list, the footer — sixty times a second while the operator
/// drags the box or a size slider (owner: "лагают и ползунки высоты и ширины").
/// Here it re-renders the box overlay and the rows that read it, and nothing
/// else.
///
/// The earlier round fixed the OTHER half of the same cost — the settings write
/// per tick, debounced in `applyVisualRecChange` — and stopped there. The
/// publish itself was left.
@MainActor
final class VisualRecLiveState: ObservableObject {
    @Published private(set) var teaching = VisualRecTeaching()
    /// A value is on screen that the controller has not published yet.
    private(set) var hasDraft = false

    /// A drag event or a slider tick: on screen now, published later.
    func preview(_ value: VisualRecTeaching) {
        hasDraft = true
        teaching = value
    }

    /// The controller published a value — the draft is folded in or superseded.
    func settle(_ value: VisualRecTeaching) {
        hasDraft = false
        if teaching != value { teaching = value }
    }
}
