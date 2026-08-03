@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation

/// What the backends deliver, from their own capture threads: format changes,
/// signal presence and the frames themselves. Each one hands off to `queue`
/// immediately — a DeckLink callback runs inside the SDK's @synchronized
/// region and nothing that can park may happen on it.
///
/// Split out of CapturePipeline, which had grown past 1300 lines.
extension CapturePipeline {
    public func handleFormat(_ newFormat: CaptureFormat) {
        queue.async {
            // a re-announced identical format must not reset detection state:
            // it would wipe the pre-roll buffer and restart REC debounce mid-take
            guard newFormat != self.format else { return }
            // a REAL format change restarts the streams (PTS timeline resets),
            // so an open take would silently starve while REC stayed red —
            // close it cleanly and tell the operator
            if self.writer != nil {
                self.finishTake()
                DispatchQueue.main.async {
                    self.onError?("Take closed: input format changed mid-take")
                }
            }
            self.format = newFormat
            self.detector.reset()
            self.preRollBuffer.removeAll()
            self.preRollAudio.removeAll()
            // the restart resets the stream's PTS timeline, so the external
            // audio anchor is stale — re-pinned on the next frame
            self.externalHostAnchor = nil
            DispatchQueue.main.async { self.onFormatChanged?(newFormat) }
        }
    }

    public func handleSignal(present: Bool) {
        // called from the DeckLink callback inside its @synchronized region —
        // clearToBlack does GPU work (nextDrawable can park ~1 s occluded),
        // so everything hops to our own queues
        queue.async {
            if !present {
                self.signalLost()
            }
            DispatchQueue.main.async { self.onSignal?(present) }
        }
    }

    /// The cable is out or the camera stopped feeding: no frames means
    /// no VANC, so the camera's stop AND its next start are both
    /// invisible to the detector. Left open, the writer would swallow
    /// the next take into the same file — one clip holding the tail of
    /// take 12, a gap, and take 13, with a clip counter that advanced
    /// once. Close on the spot; a re-lock starts a fresh take.
    private func signalLost() {
        if writer != nil {
            finishTake()
            DispatchQueue.main.async {
                self.onError?("Take closed: input signal lost mid-take")
            }
        }
        detector.reset()
        // frames buffered before the dropout are separated from whatever
        // comes back by the length of the dropout — as pre-roll they
        // would open the next take with stale frames and a PTS gap
        preRollBuffer.removeAll()
        preRollAudio.removeAll()
        // no stale frame for later sink registrations or the compare
        latestPreviewLock.lock()
        latestPreview = nil
        latestPreLUT = nil
        latestPreviewLock.unlock()
        displayQueue.async {
            self.displaySinks.clearToBlack()
        }
    }

    /// What the backends deliver.
    public func handleFrame(_ frame: CapturedFrame) {
        handleFrame(pixelBuffer: frame.pixelBuffer, pts: frame.pts,
                    timecode: frame.timecode, vancTrigger: frame.vancTrigger,
                    ancillaryPackets: frame.ancillaryPackets,
                    colorimetry: frame.colorimetry)
    }

    public func handleFrame(pixelBuffer: CVPixelBuffer, pts: CMTime,
                            timecode rawTimecode: Timecode?,
                            vancTrigger: VancTrigger? = nil,
                            ancillaryPackets: [AncillaryPacket] = [],
                            colorimetry: WireColorimetry = .sdr) {
        // backpressure: a stalled destination (NAS waking up) piles retained
        // UHD buffers into the queue — drop at ingress past a small window
        guard admitFrameAtIngress() else { return }
        queue.async {
            defer {
                self.inFlightLock.lock()
                self.inFlightFrames -= 1
                self.inFlightLock.unlock()
            }
            self.processFrame(pixelBuffer: pixelBuffer, pts: pts,
                              timecode: rawTimecode, vancTrigger: vancTrigger,
                              ancillaryPackets: ancillaryPackets,
                              colorimetry: colorimetry)
        }
    }

    /// Take a slot in the in-flight window, or drop the frame at ingress and
    /// report the running count. False means the caller must not enqueue.
    private func admitFrameAtIngress() -> Bool {
        inFlightLock.lock()
        if inFlightFrames >= 12 {
            ingressDrops += 1
            let drops = ingressDrops
            inFlightLock.unlock()
            if drops == 1 || drops % 100 == 0 {
                DispatchQueue.main.async {
                    self.onError?("Pipeline overloaded — \(drops) frame(s) "
                        + "dropped at ingress")
                }
            }
            return false
        }
        inFlightFrames += 1
        inFlightLock.unlock()
        return true
    }
}
