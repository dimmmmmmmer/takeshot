import Foundation

/// The two compare values that move with a GESTURE, kept off the object the
/// whole window observes.
///
/// `wipePosition` and `blendOpacity` were `@Published` on `CaptureController`,
/// which every view in the window has as an `@EnvironmentObject`. So one drag
/// of the wipe handle, or one nudge of the blend slider, re-ran the body of the
/// footer, the takes panel, the badges and the naming rows — sixty times a
/// second, to move a line two points (owner: "шторка вайпа в режиме плейбэка
/// лагает", "бленд соответственно лагает при смене процентов непрозрачности").
///
/// This is the same fix `ScopeFeed` already is, and the same one the footer's
/// meter bank needed: a value that changes at gesture rate belongs on an object
/// only the views that DRAW it observe. The controller still owns the numbers
/// and still pushes them to the compositor — what changed is who gets woken.
///
/// Not persisted: neither survives a relaunch today, and both are a position
/// inside a comparison rather than a preference about one.
@MainActor
final class CompareLive: ObservableObject {
    /// 0…1; left/top is playback.
    @Published var wipePosition: Double = 0.5
    /// Playback opacity in blend mode.
    @Published var blendOpacity: Double = 0.5
}
