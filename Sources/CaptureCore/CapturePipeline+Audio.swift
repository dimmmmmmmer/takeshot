@preconcurrency import CoreMedia
import Foundation
import os.log

/// Audio: levels for the meters, the stereo feed, LTC decoding, and the
/// channel mask latched for the take.
///
/// Split out of CapturePipeline, which had grown past 1300 lines.
///
/// **One stereo mix, several consumers**, which is `LiveVideoEncoder`'s rule
/// one media type along and it arrived here for the same reason: two outputs
/// wanted the same missing thing. The cart's speakers had the only stereo feed
/// the pipeline made, and it is gated on `monitorEnabled` — so an SRT stream or
/// an NDI source hung off it would have made a director's sound a side effect
/// of whether the operator has the speakers up. The tap below is that feed
/// without the gate: registered per consumer, mixed ONCE per packet, and handed
/// to the monitor and every transport alike.
///
/// What it deliberately is NOT is a second trip through the channel selection.
/// `feedStereo` builds the packet once and both halves take that one buffer, so
/// an operator monitoring while streaming pays one `selectChannels` and not
/// two — which is the half of "independent of the monitor" that costs
/// something rather than the half that is a missing `guard`.
extension CapturePipeline {
    /// Toggle the live audio monitor feed (onMonitorAudio).
    ///
    /// The speakers alone. A transport registered through `addAudioTap` keeps
    /// delivering with this false, which is the whole point of the tap.
    public func setAudioMonitorEnabled(_ on: Bool) {
        queue.async { self.monitorEnabled = on }
    }

    // MARK: - the outgoing stereo tap

    /// Register a consumer of the stereo feed. `owner` identifies it, so the
    /// same object cannot register twice and removal needs nothing but the
    /// object itself — `LiveVideoEncoder.addSink`'s contract exactly.
    ///
    /// The tap is called on the PIPELINE queue, which is the capture queue: a
    /// consumer hops to its own before it does anything, the way `AudioMonitor`
    /// already does with the monitor slot. Encoding on this queue would put the
    /// per-frame path behind an AAC encoder.
    public func addAudioTap(_ owner: AnyObject, _ tap: @escaping AudioTap) {
        // The key is taken out here so an `AnyObject` never crosses into the
        // locked scope: the same reason `LiveVideoEncoder.addSink` does it.
        let key = ObjectIdentifier(owner)
        audioTapLock.lock()
        audioTapSinks[key] = tap
        audioTapLock.unlock()
    }

    public func removeAudioTap(_ owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        audioTapLock.lock()
        audioTapSinks.removeValue(forKey: key)
        audioTapLock.unlock()
    }

    /// Whether anything outgoing is listening.
    ///
    /// For the TESTS, and not for the per-packet guard, which this comment used
    /// to claim: `feedStereo` takes a SNAPSHOT of the taps (`audioTaps()`) and
    /// guards on that, because testing a collection and then iterating it is
    /// two reads with a release in between — the same argument the line above
    /// `onMonitorAudio` makes. "Nothing listening costs nothing" is a claim
    /// about this being false, and a tap that was never removed and one that
    /// was are indistinguishable from outside otherwise.
    public var hasAudioTaps: Bool {
        audioTapLock.lock()
        defer { audioTapLock.unlock() }
        return !audioTapSinks.isEmpty
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
            // **The CLOCK reads the packet as it arrived.** The operator's
            // offset is about where the SOUND sits against the picture, and
            // LTC is not sound — it is a timecode the camera sent, and the
            // number a take opens on is recording integrity.
            //
            // It makes no difference TODAY and it is still the right argument
            // to pass: `decodeLTC` reads the block buffer's samples and never
            // the packet's timestamps (`+Timecode.swift`), so a shifted copy
            // decodes to the same timecode. No test can tell the two apart,
            // which is why there is none — handing it the moved packet would
            // be a bet that the decoder never learns to place what it read in
            // time, and that is a bet with nothing on the other side of it.
            if self.config.settings.capture.timecodeSource == "ltc" {
                self.decodeLTC(from: packet, channels: levels.count)
            }
            // …and everything that IS sound moves together: the take, the
            // monitoring, the stereo fold the SRT and NDI legs carry. One
            // shift, at the one door both sources come through, so what the
            // operator dialled in by ear is what lands in the file.
            //
            // Sound pushed past the take's own start is not written — the
            // writer has no session there yet — so a take made under an offset
            // holds that much less sound at the end it was moved away from.
            // That is the offset working rather than a loss: the frames it
            // covers are the ones whose sound belongs to the take before it.
            let heard = self.delayed(packet, from: source) ?? packet
            self.recordAudio(heard)
            self.feedStereo(heard)
            self.publishLevels(levels)
        }
    }

    /// The packet stamped back to when its sound actually happened, or nil
    /// when there is nothing to shift.
    ///
    /// Positive moves it later, negative earlier — see
    /// `AudioSettings.embeddedDelayMS` for which a given source wants. Zero
    /// returns nil and costs a `Double` comparison, so an operator who never
    /// touches this pays nothing per packet.
    ///
    /// Queue-confined, like everything else `handleAudio` does.
    func delayed(_ packet: CMSampleBuffer,
                 from source: AudioSource) -> CMSampleBuffer? {
        let ms = config.settings.audio.delayMS(for: source == .external)
        guard ms != 0 else { return nil }
        guard CMSampleBufferGetPresentationTimeStamp(packet).isValid
        else { return nil }
        let shift = CMTime(value: CMTimeValue((ms * 1000).rounded()),
                           timescale: 1_000_000)
        return Self.retimedAudio(packet, by: shift)
    }

    /// A copy of `packet` moved by `shift`, its samples and their own timing
    /// untouched.
    ///
    /// **The packet's OWN timing array, with only the presentation times
    /// moved.** An audio buffer's timing entry carries the duration of ONE
    /// SAMPLE — 1/48000 — and `CMSampleBufferGetDuration` reports the whole
    /// packet, which is that times the sample count. Handing the whole packet's
    /// duration back as a single entry therefore tells CoreMedia that every one
    /// of the 1920 samples lasts 40 ms, and the copy claims a length 1920 times
    /// its own. Read the array, shift it, hand it back.
    static func retimedAudio(_ packet: CMSampleBuffer,
                             to pts: CMTime) -> CMSampleBuffer? {
        let now = CMSampleBufferGetPresentationTimeStamp(packet)
        guard now.isValid else { return nil }
        return retimedAudio(packet, by: CMTimeSubtract(pts, now))
    }

    static func retimedAudio(_ packet: CMSampleBuffer,
                             by shift: CMTime) -> CMSampleBuffer? {
        var needed: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            packet, entryCount: 0, arrayToFill: nil,
            entriesNeededOut: &needed) == noErr, needed > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: .invalid,
                                           count: Int(needed))
        guard CMSampleBufferGetSampleTimingInfoArray(
            packet, entryCount: needed, arrayToFill: &timings,
            entriesNeededOut: nil) == noErr else { return nil }
        for index in timings.indices where timings[index]
            .presentationTimeStamp.isValid {
            timings[index].presentationTimeStamp =
                CMTimeAdd(timings[index].presentationTimeStamp, shift)
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: packet,
            sampleTimingEntryCount: needed, sampleTimingArray: &timings,
            sampleBufferOut: &out)
        return out
    }

    /// How many channels a packet declares, 0 for one with no audio format.
    static func channelCount(of sampleBuffer: CMSampleBuffer) -> Int {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return 0 }
        return Int(asbd.pointee.mChannelsPerFrame)
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
        var maskKeptNothing = false
        if let mask = activeMask {
            // Decided HERE and not from a nil answer: `selectChannels` also
            // answers nil when it cannot build the re-packed buffer, and that
            // is a dropped packet, not a moved channel map.
            let arrived = Self.channelCount(of: sampleBuffer)
            let wanted = Self.channels(in: mask)
            // A mask that names NO channel is the operator switching the last
            // one off, not the source moving: the take opens with no audio
            // track and says so on its own, and an alarm here would fire on
            // every packet of every take of that day.
            maskKeptNothing = arrived > 0 && !wanted.isEmpty
                && !wanted.contains { $0 < arrived }
            toWrite = maskKeptNothing ? nil
                : PCMAudio.selectChannels(sampleBuffer,
                                          indices: Self.channels(in: mask),
                                          formatCache: &trimFormatCache)
        }
        if let writer {
            // The writer conforms what it is given to the count it latched — a
            // source can change its own, and the mask trim above filters to what
            // ARRIVED (see `TakeWriter.conformed`). Reported from here, because
            // only the pipeline can raise an alarm.
            if let toWrite {
                writer.append(audioSampleBuffer: toWrite)
            } else if maskKeptNothing {
                // the source no longer sends the channels the take latched,
                // and a packet that never reaches the writer is counted
                // nowhere else — the writer's own padding then says
                // "starved", which is the symptom
                noteAudioMaskMiss(arrived: Self.channelCount(of: sampleBuffer))
            }
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

    /// The stereo feed, mixed once and handed to everyone who wants it: the
    /// cart's speakers when the operator has them up, and every outgoing
    /// transport whether they have or not.
    ///
    /// **Nothing listening costs an uncontended lock and two tests.** No mix is
    /// built, no buffer is allocated and no closure is called — the same shape
    /// as `publishDisplayFrame` returning before it pairs the two pictures. The
    /// lock is what `LiveVideoEncoder.hasSinks` already pays per FRAME, at 60 Hz
    /// against this path's 25.
    ///
    /// **Something listening costs ONE mix**, and that is the reason these two
    /// consumers share a function rather than having one each. An operator
    /// monitoring a stream would otherwise pay `selectChannels` twice per
    /// packet for two buffers with identical bytes in them.
    ///
    /// Called after `recordAudio` and deliberately so: the file is written
    /// first, from the untouched packet, and nothing here is upstream of
    /// anything the take gets.
    private func feedStereo(_ sampleBuffer: CMSampleBuffer) {
        // The slot is read ONCE, and the gate with it. `monitorEnabled` is
        // written from the main actor while packets are in flight, so testing
        // `monitorEnabled && onMonitorAudio != nil` and then calling through
        // the property is two reads that can disagree — the speakers going
        // quiet between them, or coming back. (The closure itself is assigned
        // once at bind time and never re-routed; an earlier version of this
        // comment said otherwise and made the pattern look like it was
        // guarding a hazard it is not.)
        let speakers = monitorEnabled ? onMonitorAudio : nil
        let outgoing = audioTaps()
        guard speakers != nil || !outgoing.isEmpty else { return }
        guard let stereo = PCMAudio.selectChannels(
            sampleBuffer, indices: stereoChannelIndices,
            formatCache: &stereoFormatCache) else { return }
        speakers?(stereo)
        for tap in outgoing { tap(stereo) }
    }

    /// The channels the stereo feed is taken from: the first two ENABLED by the
    /// mask in force, or 1-2 when there is no mask at all.
    ///
    /// **The same rule for the speakers and for the wire, which is the
    /// decision.** The mask in force is the operator's own when they have given
    /// one, the standby measurement's when they have not
    /// (`effectiveAudioChannelMask`), and the take's latch while one is rolling
    /// — so what goes out is a stereo fold of what is going into the FILE. The
    /// alternative, a fixed 1-2, is wrong on the rig this app is for: a
    /// sixteen-channel embed whose only live pair is 5-6 would send a director
    /// two dead channels, confidently.
    ///
    /// Stereo and not the mask itself, because the far end of every one of
    /// these is a monitor: a director's laptop, an iPad, a browser. A
    /// sixteen-channel AAC stream is not a thing any of them can play, and a
    /// feed nobody can hear is worse than a fold nobody chose.
    ///
    /// One enabled channel gives a MONO feed rather than a doubled one. Both
    /// legs after the tap state a channel count — ADTS and NDI alike — so mono
    /// travels; faking a second channel would be the app inventing sound.
    var stereoChannelIndices: [Int] {
        activeAudioChannelMask
            .map { Array(Self.channels(in: $0).prefix(2)) } ?? [0, 1]
    }

    /// The taps, copied out under the lock and called outside it — a tap that
    /// removes itself from inside its own callback would otherwise deadlock,
    /// and a tap is allowed to.
    private func audioTaps() -> [AudioTap] {
        audioTapLock.lock()
        defer { audioTapLock.unlock() }
        return Array(audioTapSinks.values)
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
        stereoFormatCache = nil
        DispatchQueue.main.async { self.onAudioChannelsDetected?(answer) }
    }

    /// Channel indices set in a bit mask (bit i = channel i). Internal rather
    /// than private: the pre-roll drain applies the same mask from `+PreRoll`.
    static func channels(in mask: Int) -> [Int] {
        (0..<32).filter { mask & (1 << $0) != 0 }
    }
}
