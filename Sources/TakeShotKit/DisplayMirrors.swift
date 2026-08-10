import Foundation

/// The mirrors of the viewer, and what the operator is told about them.
///
/// One holder rather than a handful of properties on `CaptureController`: the
/// controller is a stored-state inventory that is deliberately capped, and a
/// subsystem that needs several fields takes one, the way `live`, `scopes` and
/// `transport` already do. It is also what keeps
/// `CaptureController.wireDisplayMirrors` readable.
///
/// Today that is the hardware playout alone. It was two — the NDI source rode
/// the same display-mirror handler slot, on the same terms, because both take
/// the DECORATED frame the operator is looking at rather than the clean one the
/// phone grid gets. That slot is what a network output attaches to.
///
/// MainActor state throughout: every field here is written from the controller.
@MainActor
final class DisplayMirrors: ObservableObject {
    /// Hardware playout: mirrors the viewer to the DeckLink output chosen in
    /// settings. Rebuilt on device/format changes; routed by viewer mode.
    var playout: PlayoutFeeder?
}
