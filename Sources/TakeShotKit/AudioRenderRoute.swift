import AVFoundation
import CoreMedia
import Foundation

/// Where the live audio monitor puts its packets: a renderer on a timeline.
///
/// A protocol for the same reason the capture backend and the audio INPUT
/// provider are (`CaptureBackend`, `AudioInputDeviceProviding`): the real one
/// opens an output device on the machine running the suite. Everything worth
/// asserting about the monitor is above this line — the PTS offset the first
/// packet establishes, the drift window that forces a resync, the backlog cap,
/// and the drain request that must exist only while there is a backlog — and
/// none of it needs a speaker to be true.
///
/// Threading: every member is called on the monitor's own serial queue and
/// nowhere else. A conformer owes no synchronization of its own.
protocol AudioRenderRoute: AnyObject {
    var isReadyForMoreMediaData: Bool { get }
    /// Output level, 0…1. Write-only in practice — the monitor keeps its own
    /// lock-protected mirror for the getter, since a slider callback reads it
    /// on the main thread while the swap below happens on the queue.
    var volume: Float { get set }
    /// The timeline's current time, for the drift comparison.
    var currentTime: CMTime { get }

    func enqueue(_ sampleBuffer: CMSampleBuffer)
    /// `block` is `@Sendable` because the renderer calls it on `queue`, which is
    /// the caller's and not the one that armed it — the same crossing the
    /// underlying `AVSampleBufferAudioRenderer` already declares.
    func requestMediaDataWhenReady(on queue: DispatchQueue,
                                   using block: @escaping @Sendable () -> Void)
    func stopRequestingMediaData()
    func flush()
    func setRate(_ rate: Float, at time: CMTime)

    /// Send the output to `uid`, or back to the system default when nil.
    ///
    /// Returns true when the renderer object itself was REPLACED, which is the
    /// only way back to the system default (see `SystemAudioRoute`) and which
    /// invalidates everything the caller knew about the old timeline. A caller
    /// that gets true must drop its offset and its backlog.
    func route(to uid: String?) -> Bool
}

/// The real output: an `AVSampleBufferAudioRenderer` on an
/// `AVSampleBufferRenderSynchronizer`.
///
/// Construction is inert — nothing opens a device until a packet is enqueued —
/// so a controller that never monitors never touches the machine's audio.
final class SystemAudioRoute: AudioRenderRoute {
    private var renderer = AVSampleBufferAudioRenderer()
    private let sync = AVSampleBufferRenderSynchronizer()

    init() {
        sync.addRenderer(renderer)
    }

    var isReadyForMoreMediaData: Bool { renderer.isReadyForMoreMediaData }

    var volume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }

    var currentTime: CMTime { sync.currentTime() }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        renderer.enqueue(sampleBuffer)
    }

    func requestMediaDataWhenReady(on queue: DispatchQueue,
                                   using block: @escaping @Sendable () -> Void) {
        renderer.requestMediaDataWhenReady(on: queue, using: block)
    }

    func stopRequestingMediaData() {
        renderer.stopRequestingMediaData()
    }

    func flush() {
        renderer.flush()
    }

    func setRate(_ rate: Float, at time: CMTime) {
        sync.setRate(rate, time: time)
    }

    /// The renderer rejects a nil `audioOutputDeviceUniqueID` (NSException), so
    /// "back to system default" is a fresh renderer on the same timeline. The
    /// level is carried across by hand — a new renderer starts at 1.0, and an
    /// operator who had pulled the monitor down does not expect a device change
    /// to put it back up.
    func route(to uid: String?) -> Bool {
        if let uid {
            renderer.audioOutputDeviceUniqueID = uid
            return false
        }
        let level = renderer.volume
        sync.removeRenderer(renderer, at: .zero)
        renderer = AVSampleBufferAudioRenderer()
        renderer.volume = level
        sync.addRenderer(renderer)
        return true
    }
}
