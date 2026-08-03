import Foundation

/// The mirrors of the viewer, and what the operator is told about them.
///
/// The hardware playout output and the NDI source are the same kind of thing:
/// both show whatever the viewer shows, both take the DECORATED frame, and both
/// ride the one display-mirror handler slot per source that
/// `CaptureController.wireDisplayMirrors` installs. Holding them together is
/// what makes that function readable, and it is also what keeps
/// `CaptureController` off its type-body ceiling — the controller is a
/// stored-state inventory that is deliberately capped, and a subsystem that
/// needs five properties takes one, the way `live`, `scopes` and `transport`
/// already do.
///
/// An ObservableObject for one field only: `ndiState` is what the settings row
/// reads, and the row observes this object directly (`NDIStatusRow`) rather than
/// the whole controller — the same reason `live` exists.
///
/// MainActor state throughout: every field here is written from the controller.
@MainActor
final class DisplayMirrors: ObservableObject {
    /// Hardware playout: mirrors the viewer to the DeckLink output chosen in
    /// settings. Rebuilt on device/format changes; routed by viewer mode.
    var playout: PlayoutFeeder?

    /// The NDI source; nil — off, which is the default. Built on the setting's
    /// edge and dropped on the other, so with the switch off the display path
    /// has no NDI consumer at all (see `CaptureController+NDI`).
    var ndi: NDIVideoMirror?

    /// What Settings shows about the NDI output. Published because it is the
    /// only honest answer to "is it sending?": the switch is a wish, and a build
    /// with no SDK or a machine with no runtime cannot honour it.
    @Published var ndiState: NDIOutputState = .off

    /// Overridden in tests so a suite never announces a real source on the set
    /// network; nil — the real sender. `ControllerHarness` fills it in for every
    /// controller it builds, so reaching the real one by omission is not
    /// possible from a test.
    var ndiSenderFactory: ((String) throws -> NDIVideoSending)?

    /// Debounces the re-announce a name change causes (see `applyNDIChange`).
    var ndiRenameTask: Task<Void, Never>?
}
