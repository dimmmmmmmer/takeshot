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
}
