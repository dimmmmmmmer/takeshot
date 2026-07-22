import AVFoundation
import CoreMedia
import Foundation

/// Plays the live capture audio feed through a system output.
///
/// Capture packets carry the board's own PTS base, so the first packet
/// establishes a constant offset onto the render synchronizer's timeline;
/// continuity of the source PTS keeps playback gapless. A PTS jump (device
/// restart, source switch) outside the tolerance window resyncs.
final class AudioMonitor: @unchecked Sendable {
    private var renderer = AVSampleBufferAudioRenderer()
    private let sync = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "takeshot.audio-monitor")
    private var offset: CMTime?
    private var deviceUID: String?

    init() {
        sync.addRenderer(renderer)
    }

    var volume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }

    /// Output device UID (nil — system default); shares the playback picker.
    /// The renderer rejects a nil assignment (NSException), so "back to system
    /// default" is implemented by swapping in a fresh renderer.
    var outputDeviceUID: String? {
        get { deviceUID }
        set {
            queue.async { [self] in
                guard deviceUID != newValue else { return }
                deviceUID = newValue
                if let newValue {
                    renderer.audioOutputDeviceUniqueID = newValue
                } else {
                    let volume = renderer.volume
                    sync.removeRenderer(renderer, at: .zero)
                    renderer = AVSampleBufferAudioRenderer()
                    renderer.volume = volume
                    sync.addRenderer(renderer)
                    offset = nil
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.sync.setRate(0, time: .zero)
            self.renderer.flush()
            self.offset = nil
        }
    }

    /// Enqueue a capture packet (called from the pipeline queue).
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        queue.async { self.enqueueLocked(sampleBuffer) }
    }

    // MARK: - on queue

    private func enqueueLocked(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if let offset {
            // resync on PTS discontinuity: adjusted time far from the clock
            let adjusted = CMTimeAdd(pts, offset)
            let drift = CMTimeSubtract(adjusted, sync.currentTime()).seconds
            if drift < -0.05 || drift > 1.0 {
                renderer.flush()
                self.offset = nil
            }
        }
        if offset == nil {
            // start the clock slightly behind the first packet to absorb jitter
            let lead = CMTime(value: 60, timescale: 1000)
            offset = CMTimeSubtract(lead, pts)
            sync.setRate(1, time: .zero)
        }
        guard let offset,
              let retimed = Self.retimed(sampleBuffer, by: offset),
              renderer.isReadyForMoreMediaData else { return }
        renderer.enqueue(retimed)
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
