@preconcurrency import CoreMedia
import Foundation
import os.log

/// Audio: levels for the meters, the monitor feed, LTC decoding, and the
/// channel mask latched for the take.
///
/// Split out of CapturePipeline, which had grown past 1300 lines.
extension CapturePipeline {
    /// Toggle the live audio monitor feed (onMonitorAudio).
    public func setAudioMonitorEnabled(_ on: Bool) {
        queue.async { self.monitorEnabled = on }
    }
    /// What the backend says its audio input is configured for, before any
    /// packet has arrived. A take can start on capture frame 1 (a VANC trigger
    /// fires with no debounce), and without this the writer got no audio input
    /// at all and every packet of that take was discarded in silence. The first
    /// real packet still wins — this is only the head start.
    public func setExpectedAudioChannels(_ count: Int) {
        queue.async {
            guard count > 0, self.sourceAudioChannels == 0 else { return }
            self.sourceAudioChannels = count
        }
    }
    public func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        handleAudio(sampleBuffer, from: .embedded)
    }

    /// The one audio entry, for both sources: everything downstream — the
    /// meters, LTC, the monitor feed, the take — is shared, and which source
    /// feeds it is decided here in one place.
    public func handleAudio(_ sampleBuffer: CMSampleBuffer,
                            from source: AudioSource) {
        queue.async {
            // never mixed: while one source is active the other's packets are
            // discarded whole — a take spliced from two clocks would be worse
            // than either source alone
            guard source == self.audioSourceKind else { return }
            var packet = sampleBuffer
            if source == .external {
                // host clock → stream clock (see +ExternalAudio)
                guard let admitted = self.admitExternalPacket(sampleBuffer)
                else { return }
                packet = admitted
            }
            let levels = PCMAudio.peakLevels(of: packet)
            self.sourceAudioChannels = levels.count
            self.noteCarryingChannels(levels: levels, in: packet)
            if self.config.settings.capture.timecodeSource == "ltc" {
                self.decodeLTC(from: packet, channels: levels.count)
            }
            self.recordAudio(packet)
            self.feedMonitor(packet)
            self.publishLevels(levels)
        }
    }

    /// Route the packet to the take (or the pre-roll ring while standing by).
    /// Meters show ALL channels; only the ones in the mask are written.
    /// Internal rather than private: the silence padding in `+ExternalAudio`
    /// sends its packets through the same door as the real ones.
    func recordAudio(_ sampleBuffer: CMSampleBuffer) {
        // the mask is LATCHED for the take: the writer's channel count is
        // fixed at start, a live change would kill the whole file
        let activeMask = activeAudioChannelMask
        var toWrite: CMSampleBuffer? = sampleBuffer
        if let mask = activeMask {
            toWrite = PCMAudio.selectChannels(sampleBuffer,
                                              indices: Self.channels(in: mask),
                                              formatCache: &trimFormatCache)
        }
        if let writer {
            // The writer conforms what it is given to the count it latched — a
            // source can change its own, and the mask trim above filters to what
            // ARRIVED (see `TakeWriter.conformed`). Reported from here, because
            // only the pipeline can raise an alarm.
            if let toWrite { writer.append(audioSampleBuffer: toWrite) }
            // Both only take the health lock when a tally actually moved, so an
            // accepted packet costs two comparisons.
            noteAudioDrops(from: writer)
            noteAudioConform(from: writer)
        } else if preRollFrames > 0 {
            // not recording: keep the sound of the pre-roll window, so the
            // take that starts in a moment has audio under its first frames
            bufferPreRollAudio(sampleBuffer)
        }
    }

    /// The first two ENABLED channels as a stereo feed for the operator.
    ///
    /// The mask in force, so the operator hears what is being recorded — which
    /// now includes the measurement's answer. A monitor feed taken from a
    /// different set of channels than the file is the operator checking the
    /// wrong thing, and doing it confidently.
    private func feedMonitor(_ sampleBuffer: CMSampleBuffer) {
        guard monitorEnabled, let onMonitorAudio else { return }
        let mask = activeAudioChannelMask
        let indices = mask.map { Array(Self.channels(in: $0).prefix(2)) } ?? [0, 1]
        if let monitor = PCMAudio.selectChannels(sampleBuffer, indices: indices,
                                                 formatCache: &monitorFormatCache) {
            onMonitorAudio(monitor)
        }
    }

    /// Meters, deduplicated — identical level arrays are not worth a main hop.
    /// Internal rather than private: the silence padding in `+ExternalAudio`
    /// keeps the meters honest through the same publisher.
    func publishLevels(_ levels: [Float]) {
        guard !levels.isEmpty, levels != lastPublishedLevels else { return }
        if lastPublishedLevels.isEmpty {
            os_log("audio: %d channel(s) flowing",
                   log: Self.levelsLog, type: .default, levels.count)
        }
        lastPublishedLevels = levels
        DispatchQueue.main.async { self.onAudioLevels?(levels) }
    }

    /// Forget what the last source was measured carrying, and tell the UI the
    /// answer is gone. On the queue; called when the source changes under the
    /// pipeline (`+ExternalAudio`) or the session ends (`+Control`).
    ///
    /// The hop is unconditional here rather than change-gated: a stale "1-2
    /// carry signal" left standing over a device that is no longer connected is
    /// exactly the reading nobody can act on, and this runs a handful of times
    /// a session.
    func resetAudioChannelDetection() {
        audioDetector.reset()
        detectedAudioMask = nil
        DispatchQueue.main.async { self.onAudioChannelsDetected?(nil) }
    }

    /// Feed the standby measurement, and say so when its ANSWER moves.
    ///
    /// Called on every packet, so the shape is the health mirror's: the cheap
    /// path is the one that runs 25 times a second, and it is a handful of
    /// comparisons and an add. The answer itself changes a few times a session
    /// at most — once when the first second of standby has been seen, and again
    /// only if a channel that was digitally silent starts carrying — so the
    /// main-queue hop and the cache reset below cost nothing per packet.
    ///
    /// A take that is already rolling is measured but never re-masked: the mask
    /// is latched (`+Take`) and the answer it latched is the answer it keeps.
    /// The measurement still runs, because the NEXT take is the one it is for.
    private func noteCarryingChannels(levels: [Float], in packet: CMSampleBuffer) {
        audioDetector.note(levels: levels, seconds: PCMAudio.seconds(of: packet))
        let answer = audioDetector.detectedMask
        guard answer != detectedAudioMask else { return }
        detectedAudioMask = answer
        // the packed-buffer format caches describe the OLD channel count — the
        // same reason a mask change resets them in `update(config:)`, and this
        // is a mask change by the other route
        trimFormatCache = nil
        monitorFormatCache = nil
        DispatchQueue.main.async { self.onAudioChannelsDetected?(answer) }
    }

    /// Channel indices set in a bit mask (bit i = channel i). Internal rather
    /// than private: the pre-roll drain applies the same mask from `+PreRoll`.
    static func channels(in mask: Int) -> [Int] {
        (0..<32).filter { mask & (1 << $0) != 0 }
    }
}
