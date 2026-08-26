@preconcurrency import CoreMedia
import Foundation

/// The external (USB) audio source: admitting its packets in place of the
/// embedded ones, aligning its host-clock timestamps to the board's stream
/// clock, and padding a running take with silence when the device vanishes.
///
/// Clock honesty: video PTS comes from the capture board's stream clock, a
/// USB interface's buffers are stamped with the host clock, and the two are
/// related by nothing but this anchor — one (host, stream) pair taken on the
/// frame path when the source goes live. The offset it fixes is static, so a
/// take's first audio lands against its first video frame, but the residual
/// is real: the board's clock and the interface's crystal free-run against
/// each other, and on a long take they drift apart by however much those two
/// oscillators disagree (tens of milliseconds per hour is typical). TakeShot
/// states that here instead of pretending to resample it away.
///
/// Split into its own file for the same reason `+Audio` was: one mechanism,
/// on the pipeline queue, kept on one screen.
extension CapturePipeline {
    /// Where the audio path's packets come from.
    public enum AudioSource: Equatable, Sendable {
        /// Audio embedded in the capture board's signal (the default).
        case embedded
        /// A Core Audio input device (USB interface, aggregate, built-in mic).
        case external
    }

    /// Silence is padded in 40 ms packets at the pipeline's 48 kHz — the
    /// cadence and rate the converted external packets arrive at.
    ///
    /// `TakeWriter.audioPadFrames` is the same 40 ms one level down. Two
    /// constants rather than one because the two pad at different WIDTHS: this
    /// pads at the SOURCE's channel count so the take's latched mask trims it
    /// exactly like a real packet, and the writer's pads at the count the track
    /// was opened with, which needs no trim at all.
    static let padChunkFrames = 1920
    /// How long external packets may stop arriving before the take is padded
    /// even without a disconnect event — a wedged device must not leave a
    /// silent hole that nobody counted.
    static let externalStarvationThreshold = 0.5

    /// How many silence packets ONE frame may write.
    ///
    /// The loop below fills from the last audio up to this frame's PTS in 40 ms
    /// steps, and the frame's PTS is whatever the board says. The first hard-won
    /// fact about this hardware is that stream time can be pinned or reset, and
    /// a jump forward turns a single frame into a packet per 40 ms of the gap:
    /// fifteen thousand allocations, channel trims and writer appends on the
    /// capture queue for ten minutes of it, which is the one queue that may not
    /// be handed unbounded work.
    ///
    /// 32 is 1.28 s, far above any honest burst — the loop runs once per frame,
    /// a frame interval is 40 ms, and the deepest legitimate catch-up is the
    /// starvation threshold itself (0.5 s, thirteen packets). Past the cap the
    /// cursor is moved to the frame rather than left behind, so an absurd gap
    /// costs one bounded burst instead of spreading the same work across the
    /// next five hundred frames.
    static let maximumPadPacketsPerFrame = 32

    /// Switch the audio path between the embedded and the external source.
    /// `expectedChannels` plays the `setExpectedAudioChannels` role for the
    /// new source: the head start the writer needs when a take begins before
    /// the first packet (the first real packet still wins).
    ///
    /// Mid-take the switch is deferred until the writer closes: the take's
    /// channel mask and the writer's channel count are latched at start, and
    /// changing the source under them would desync the two while looking
    /// like it had been applied.
    public func setActiveAudioSource(_ source: AudioSource,
                                     expectedChannels: Int = 0) {
        queue.async {
            if self.writer != nil {
                self.pendingAudioSourceSwitch = (source, expectedChannels)
                return
            }
            self.applyAudioSourceSwitch(source, expectedChannels: expectedChannels)
        }
    }

    /// The USB device vanished mid-take. The take stays alive: video keeps
    /// recording and the frame path pads the audio with counted silence —
    /// never a fallback to embedded audio mid-take (the writer's channel
    /// count is latched, and splicing two sources into one track would be
    /// worse than honest silence).
    public func markExternalAudioLost() {
        queue.async {
            guard self.audioSourceKind == .external else { return }
            self.externalAudioLost = true
        }
    }

    // MARK: - on queue

    /// The switch itself; also applied from `finishTake` for a change that
    /// arrived mid-take. A direct apply supersedes any deferred one.
    func applyAudioSourceSwitch(_ source: AudioSource, expectedChannels: Int) {
        pendingAudioSourceSwitch = nil
        audioSourceKind = source
        externalHostAnchor = nil
        externalAudioLost = false
        externalAudioStarved = false
        lastExternalAudioEnd = nil
        preRolledAudioEnd = nil
        // the packed-buffer format caches describe the OLD source's channel
        // count (the same reason a mask change resets them in update(config:))
        trimFormatCache = nil
        stereoFormatCache = nil
        padFormatCache = nil
        sourceAudioChannels = max(0, expectedChannels)
        // A different source is a different channel LAYOUT, so what the old
        // one was measured carrying says nothing about this one — a 16-channel
        // embed's answer applied to a 2-channel USB cart would be a mask made
        // of another device's channels.
        resetAudioChannelDetection()
        lastPublishedLevels = []
        // stale columns from a 16-channel embed must not sit behind a
        // 2-channel USB source's meters
        DispatchQueue.main.async { self.onAudioLevels?([]) }
    }

    /// Pin the host→stream offset on the frame path: the frame's stream PTS
    /// against the host clock read as it is processed. Taken once per source
    /// activation (and re-taken after a format change restarts the streams).
    func anchorExternalClock(framePTS: CMTime) {
        guard audioSourceKind == .external, externalHostAnchor == nil else { return }
        externalHostAnchor = (host: CMClockGetTime(CMClockGetHostTimeClock()),
                              stream: framePTS)
    }

    /// Retime an external packet onto the stream clock, or refuse it. Without
    /// an anchor (no video frame processed since the source went live) a host
    /// timestamp cannot be placed on the stream timeline at all — written raw
    /// it would land hours past the take — so the packet is dropped; meters
    /// come alive with the first video frame.
    func admitExternalPacket(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let anchor = externalHostAnchor else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let retimedPTS = CMTimeAdd(CMTimeSubtract(pts, anchor.host), anchor.stream)
        externalAudioStarved = false
        if writer != nil {
            if let last = lastExternalAudioEnd, retimedPTS < last {
                // the take was padded past this packet while the device was
                // silent — writing it now would overlap the padded span
                return nil
            }
            lastExternalAudioEnd = CMTimeAdd(
                retimedPTS, CMSampleBufferGetDuration(sampleBuffer))
        }
        return Self.retimed(sampleBuffer, to: retimedPTS)
    }

    /// Called per frame: keep a recording take's audio continuous when the
    /// external source stops delivering — the device is known gone, or the
    /// starvation watchdog tripped. Padded packets are counted per take and
    /// reported like dropped audio; the first one raises the sticky alarm.
    func padExternalAudioIfNeeded(upTo framePTS: CMTime) {
        guard audioSourceKind == .external, let writer,
              sourceAudioChannels > 0 else { return }
        // In order: where the live feed got to, else where the pre-roll drain got
        // to, else the take's first video frame. The middle one is what stops a
        // take being padded over its own pre-roll audio.
        let baseline = lastExternalAudioEnd ?? preRolledAudioEnd
            ?? (writer.firstPTS.isValid ? writer.firstPTS : nil)
        guard let baseline else { return }
        if !externalAudioLost, !externalAudioStarved {
            guard CMTimeSubtract(framePTS, baseline).seconds
                > Self.externalStarvationThreshold else { return }
            externalAudioStarved = true
        }
        let chunk = CMTime(value: CMTimeValue(Self.padChunkFrames),
                           timescale: 48_000)
        var cursor = baseline
        var padded = 0
        while CMTimeAdd(cursor, chunk) <= framePTS,
              padded < Self.maximumPadPacketsPerFrame {
            guard let silence = silencePacket(at: cursor) else { break }
            if gapFilledAudioPackets == 0 {
                DispatchQueue.main.async {
                    self.onError?(.externalAudioPadded)
                }
            }
            recordAudio(silence)
            gapFilledAudioPackets += 1
            cursor = CMTimeAdd(cursor, chunk)
            padded += 1
        }
        if padded > 0 {
            // Gap left over means the cap stopped the loop, not the frame: the
            // rest is abandoned rather than carried into the next frames, or an
            // absurd stream-time jump would cost this work five hundred times
            // over (see `maximumPadPacketsPerFrame`).
            lastExternalAudioEnd = CMTimeAdd(cursor, chunk) <= framePTS
                ? framePTS : cursor
            // Mirrored once per padding burst rather than per packet — the
            // count is what a diagnostic reads, not the individual writes.
            let inTake = gapFilledAudioPackets
            noteHealth {
                let added = inTake - $0.gapFilledAudioPacketsInTake
                $0.gapFilledAudioPacketsInTake = inTake
                $0.gapFilledAudioPacketsTotal += max(0, added)
            }
            // the meters say what the file gets: silence at the floor
            publishLevels([Float](repeating: -100, count: sourceAudioChannels))
        }
    }

    /// One 40 ms packet of silence at the source's channel count — the raw
    /// count, so the take's latched mask trims it exactly like a real packet.
    private func silencePacket(at pts: CMTime) -> CMSampleBuffer? {
        let samples = [Int16](repeating: 0,
                              count: Self.padChunkFrames * sourceAudioChannels)
        return samples.withUnsafeBytes { raw -> CMSampleBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return PCMAudio.makeSampleBuffer(
                bytes: base, sampleFrames: Self.padChunkFrames,
                channelCount: sourceAudioChannels, ptsSeconds: pts.seconds,
                formatCache: &padFormatCache)
        }
    }

    private static func retimed(_ sampleBuffer: CMSampleBuffer,
                                to pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleBufferOut: &out)
        return out
    }
}
