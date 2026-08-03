import AVFoundation
import CoreMedia
import Foundation

/// Plays the live capture audio feed through a system output.
///
/// Capture packets carry the board's own PTS base, so the first packet
/// establishes a constant offset onto the render synchronizer's timeline;
/// continuity of the source PTS keeps playback gapless. A PTS jump (device
/// restart, source switch) outside the tolerance window resyncs.
///
/// The renderer and its timeline sit behind `AudioRenderRoute` so the whole of
/// the above can be driven without an output device — see the note there.
final class AudioMonitor: @unchecked Sendable {
    private let route: AudioRenderRoute
    private let queue = DispatchQueue(label: "takeshot.audio-monitor")
    private var offset: CMTime?
    private let deviceLock = NSLock()
    private var deviceUID: String?
    /// Packets waiting for the renderer. A packet that arrives while the
    /// renderer reports not-ready used to be DROPPED, and every dropped packet
    /// is 40 ms of silence spliced into the tone — audible as steady crackle.
    /// Now it queues here and drains when the renderer asks for more.
    private var pending: [CMSampleBuffer] = []
    /// Half a second of backlog is a stalled output, not jitter; beyond it the
    /// oldest packets are the least useful thing in the room.
    static let pendingLimit = 12
    /// A drain request is armed on the renderer.
    private var draining = false

    init(route: AudioRenderRoute = SystemAudioRoute()) {
        self.route = route
    }

    /// The renderer pulls the backlog itself — but the request is armed ONLY
    /// while a backlog exists and is torn down the moment it empties.
    /// `requestMediaDataWhenReady` fires its block again and again for as long
    /// as the renderer is ready; installed permanently on an idle monitor it
    /// is a busy loop pinning a core per instance.
    private func armDrainIfNeeded() {
        guard !pending.isEmpty, !draining else { return }
        draining = true
        route.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.drainLocked()
        }
    }

    private func drainLocked() {
        while route.isReadyForMoreMediaData, !pending.isEmpty {
            route.enqueue(pending.removeFirst())
        }
        if pending.isEmpty, draining {
            route.stopRequestingMediaData()
            draining = false
        }
    }

    /// The renderer object itself is replaced on `queue` when the output device
    /// changes, so the level is kept here and applied on that same queue —
    /// touching the route straight from a slider callback on the main thread
    /// raced the swap and left the new output at the old level.
    private let volumeLock = NSLock()
    private var storedVolume: Float = 1

    var volume: Float {
        get {
            volumeLock.lock()
            defer { volumeLock.unlock() }
            return storedVolume
        }
        set {
            volumeLock.lock()
            storedVolume = newValue
            volumeLock.unlock()
            queue.async { [self] in route.volume = newValue }
        }
    }

    /// Output device UID (nil — system default); shares the playback picker.
    ///
    /// The UID is locked for the same reason as the volume above, and the store
    /// happens on the caller's thread rather than on `queue`: the getter used to
    /// read it unsynchronized while the setter wrote it from the queue, so a
    /// settings read-back straight after a device change reported the previous
    /// device. Only the renderer work — which must not race the swap — is
    /// deferred to the queue.
    var outputDeviceUID: String? {
        get {
            deviceLock.lock()
            defer { deviceLock.unlock() }
            return deviceUID
        }
        set {
            deviceLock.lock()
            let unchanged = deviceUID == newValue
            deviceUID = newValue
            deviceLock.unlock()
            guard !unchanged else { return }
            queue.async { [self] in
                // A drain request belongs to the renderer it was armed on, and
                // going back to the system default throws that renderer away
                // (see `SystemAudioRoute.route`), so the request comes down
                // first. Naming a device keeps the renderer, and with it a
                // request that is still valid — tearing it down there would
                // stall the backlog until the next packet re-armed it.
                if newValue == nil, draining {
                    route.stopRequestingMediaData()
                    draining = false
                }
                if route.route(to: newValue) {
                    // fresh renderer: the timeline it was synced to and the
                    // packets queued for the old one are both meaningless now
                    offset = nil
                    pending.removeAll()
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            route.setRate(0, at: .zero)
            route.flush()
            offset = nil
            pending.removeAll()
            if draining {
                route.stopRequestingMediaData()
                draining = false
            }
        }
    }

    /// Enqueue a capture packet (called from the pipeline queue).
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        queue.async { self.enqueueLocked(sampleBuffer) }
    }

    /// Run `body` after everything already handed to the monitor has been
    /// handled. The queue is private and every public entry point is async onto
    /// it, so this is the only way a caller can know a packet has landed —
    /// which is what the suite waits on instead of a wall-clock window.
    func settle() {
        queue.sync {}
    }

    // MARK: - on queue

    private func enqueueLocked(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if let offset {
            // resync on PTS discontinuity: adjusted time far from the clock
            let adjusted = CMTimeAdd(pts, offset)
            let drift = CMTimeSubtract(adjusted, route.currentTime).seconds
            if drift < -0.05 || drift > 1.0 {
                route.flush()
                self.offset = nil
                pending.removeAll()
            }
        }
        if offset == nil {
            // start the clock slightly behind the first packet to absorb jitter
            let lead = CMTime(value: 60, timescale: 1000)
            offset = CMTimeSubtract(lead, pts)
            route.setRate(1, at: .zero)
        }
        guard let offset,
              let retimed = Self.retimed(sampleBuffer, by: offset) else { return }
        if pending.count >= Self.pendingLimit {
            pending.removeFirst(pending.count - Self.pendingLimit + 1)
        }
        pending.append(retimed)
        drainLocked()
        armDrainIfNeeded()
    }

    private static func retimed(_ sampleBuffer: CMSampleBuffer,
                                by offset: CMTime) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMTimeAdd(pts, offset),
            decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleBufferOut: &out)
        return out
    }
}
