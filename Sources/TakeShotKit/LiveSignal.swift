import CaptureCore
import Foundation

/// One frame's analysis, on a publisher of its own.
///
/// It used to be a field of `LiveSignal`, which is the same mistake `LiveSignal`
/// itself was extracted to fix, one level down. The scopes arrive 12-15 times a
/// second; the timecode arrives every frame and the audio meters arrive with
/// every packet that differs from the last, so a panel observing `LiveSignal`
/// re-ran its whole body — four trace views, their graticules and a CGImage
/// cache lookup each — two to eight times per analysis it actually had to draw.
/// Idle that is waste; during a drag it is the reason the box the operator is
/// holding stutters, because every one of those republishes relays out the grid
/// the drag is moving boxes around in.
@MainActor
final class ScopeFeed: ObservableObject {
    @Published var data: ScopeData?
}

/// High-frequency live values: timecode (~25/s), audio meters (~25/s). They
/// live in their own observable object so per-frame updates re-render only the
/// small views that display them — when they were @Published on
/// CaptureController, every view observing the controller relaid out the whole
/// window at frame rate (~1 CPU core burned on SwiftUI layout).
@MainActor
final class LiveSignal: ObservableObject {
    @Published var currentTimecode: Timecode?
    @Published var audioLevels: [Float] = []
    /// One shared volume (live monitor AND player — switching rec/playback
    /// must not change loudness). Lives here, not in @Published settings: a
    /// slider drag would otherwise re-render the whole window and persist
    /// JSON on every tick.
    @Published var volume: Double = 1
    /// LUT intensity — same story as `volume` (slider drags must not write
    /// settings/re-render the window per tick).
    @Published var lutIntensity: Double = 1

    // MARK: - monitor DIM and mute (footer buttons; see CaptureController+Audio)

    /// The monitoring level is being held down by DIM. Here rather than in
    /// settings because the footer's DIM highlight is a per-frame neighbour of
    /// the meters (same reason as `volume` above); what gets persisted is the
    /// STATE alone, never the halved level (see `CaptureSettings.monitorDimmed`).
    @Published var dimmed = false
    /// The level DIM took away, put back exactly when it is switched off.
    var volumeBeforeDim: Double = 1

    /// The speaker's full mute is holding the output at silence. A state of its
    /// own rather than "volume == 0": a slider parked at zero is a level the
    /// operator chose, a mute is a hold with a restore point — and the slashed
    /// speaker icon has to be able to tell the two apart. Persisted like DIM —
    /// state only, never the zero (see `CaptureSettings.monitorMuted`).
    @Published var muted = false
}
