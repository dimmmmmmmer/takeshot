import CaptureCore
import Foundation

/// High-frequency live values: timecode (~25/s), audio meters (~25/s), scopes
/// (~8/s). They live in their own observable object so per-frame updates
/// re-render only the small views that display them — when they were @Published
/// on CaptureController, every view observing the controller relaid out the
/// whole window at frame rate (~1 CPU core burned on SwiftUI layout).
@MainActor
final class LiveSignal: ObservableObject {
    @Published var currentTimecode: Timecode?
    @Published var audioLevels: [Float] = []
    @Published var scopeData: ScopeData?
    /// One shared volume (live monitor AND player — switching rec/playback
    /// must not change loudness). Lives here, not in @Published settings: a
    /// slider drag would otherwise re-render the whole window and persist
    /// JSON on every tick.
    @Published var volume: Double = 1
    /// LUT intensity — same story as `volume` (slider drags must not write
    /// settings/re-render the window per tick).
    @Published var lutIntensity: Double = 1

    // MARK: - monitor DIM (footer button; see CaptureController+Audio)

    /// The monitoring level is being held down by DIM. Here rather than in
    /// settings for two reasons: the footer's DIM highlight is a per-frame
    /// neighbour of the meters (same reason as `volume` above), and dim is
    /// transient like the mute — persisting it would start a session quiet for
    /// a reason nobody can see, which is exactly the bug persisting the mute's
    /// zero once caused.
    @Published var dimmed = false
    /// The level DIM took away, put back exactly when it is switched off.
    var volumeBeforeDim: Double = 1
}
