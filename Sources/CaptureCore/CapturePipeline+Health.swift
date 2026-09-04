import Foundation

/// What the recorder has been doing, readable from any thread at any time.
///
/// Every counter here already existed on the pipeline, and every one of them is
/// confined to the capture queue. Reading them from the main actor would mean a
/// `queue.sync` — which parks the main thread behind whatever per-frame work is
/// in flight, and would park it forever if that work is exactly what has gone
/// wrong. A diagnostic that can hang the app on the day it is needed is worse
/// than no diagnostic, so the handful of values worth asking about are MIRRORED
/// under a lock of their own instead.
///
/// The mirror is written only at the moments a counter actually moves: a drop,
/// a gap-fill, a take opening or closing. A take that records cleanly never
/// touches the lock at all, so the per-frame path pays nothing for this.
public struct PipelineHealth: Sendable, Equatable, Codable {
    /// A writer is open — a take is rolling.
    public var isRecording = false
    /// What opened the most recent take (see `RecTrigger`); nil until one has
    /// started.
    ///
    /// Deliberately NOT cleared when the take closes: a bundle collected after a
    /// spurious roll has to be able to say what fired, and by then `isRecording`
    /// is already false. It is overwritten by the next take and by nothing else.
    public var startTrigger: RecTrigger?
    /// File name of the open take; nil — none.
    public var takeFileName: String?
    /// Video frames the writer refused, in the CURRENT take.
    public var droppedVideoFramesInTake = 0
    /// …and since launch. A take-local counter resets on every start, so a rig
    /// that drops two frames on every single take looks healthy in isolation.
    public var droppedVideoFramesTotal = 0
    /// Audio packets the writer refused, current take / since launch.
    public var droppedAudioPacketsInTake = 0
    public var droppedAudioPacketsTotal = 0
    /// Silence written to keep a take's audio continuous after the external
    /// (USB) source stopped delivering, current take / since launch.
    public var gapFilledAudioPacketsInTake = 0
    public var gapFilledAudioPacketsTotal = 0
    /// Silence the WRITER padded into its own audio track, current take / since
    /// launch. A different number from the two above and deliberately so: those
    /// are about a take's SOUND being kept continuous for a source the pipeline
    /// can name, this is about the FILE staying readable at all — an audio input
    /// with no data holds every fragment shut (`TakeWriter.padAudioIfNeeded`).
    /// Summing them would say one thing where two happened.
    public var paddedAudioPacketsInTake = 0
    public var paddedAudioPacketsTotal = 0
    /// Frames refused at ingress because the in-flight window was full — the
    /// pipeline being outrun rather than the encoder being behind.
    public var ingressDrops = 0
    /// Frames the wire converter could not produce at all — pool exhaustion,
    /// or a pixel format it stopped reading. Counted since launch, because the
    /// drop happens before a take exists and is invisible to every other
    /// counter here.
    public var conversionFailures = 0
    /// 8-bit frames whose limited→full expansion failed and were passed on
    /// UNEXPANDED. The levels log has already said they were expanded by the
    /// time this can happen, so the count is the only honest record.
    public var expansionFallbacks = 0
    /// Frames shown WITHOUT the chroma key because they were already past
    /// their frame interval. Not a recording fault: the display stage drops
    /// the effect rather than the frame.
    public var chromaLateDrops = 0
    /// Frames a BAKING take wrote without the key because the render failed.
    ///
    /// The recording half of the pair above, and the one that costs footage: a
    /// take the operator believes was keyed comes back with the green screen in
    /// it. The pipeline has counted these since the bake shipped, behind a
    /// property whose doc said it was "read from the main actor for the
    /// diagnostics bundle" — and the bundle only ever printed the display-only
    /// number beside it.
    public var chromaBakeFallbacks = 0
    /// Frames a LUT-baking take wrote without the look because the render
    /// failed — the same claim as the chroma one, for a look instead of a key:
    /// the file's metadata says baked and the frame is clean.
    public var lutBakeFallbacks = 0
    /// Takes whose writer was closed since launch, and how many of those could
    /// not be finalized (the `_FAILED.mov` ones).
    public var takesClosed = 0
    public var takesFailedToFinalize = 0

    public init() {}
}

extension CapturePipeline {
    /// The current mirror, plus the two counters that already live behind locks
    /// of their own. Safe from any thread, and it cannot block on the capture
    /// queue — which is the whole reason this exists.
    public var health: PipelineHealth {
        var snapshot = healthLock.withLock { storedHealth }
        inFlightLock.lock()
        snapshot.ingressDrops = ingressDrops
        inFlightLock.unlock()
        chromaLock.lock()
        snapshot.chromaLateDrops = chromaLateDropCount
        snapshot.chromaBakeFallbacks = chromaBakeFallbackCount
        snapshot.lutBakeFallbacks = lutBakeFallbackCount
        chromaLock.unlock()
        return snapshot
    }

    /// Update the mirror. Called from the capture queue, only when something
    /// has actually changed.
    func noteHealth(_ change: (inout PipelineHealth) -> Void) {
        healthLock.withLock { change(&storedHealth) }
    }

    /// Say once per take that the source changed its own channel count under a
    /// latched track, and what it was changed to.
    ///
    /// The conform itself happens in the writer, which is the only place that
    /// knows the latched width and the only one every append path goes through
    /// (see `TakeWriter.conformed`); the ALARM has to happen here, because the
    /// writer has no callbacks. Once per take rather than once per packet: a
    /// device that renegotiates its count every buffer would otherwise raise a
    /// sticky alarm at packet rate, and the operator needs to be told the map
    /// moved, not how often.
    func noteAudioConform(from writer: TakeWriter) {
        guard writer.conformedAudioPackets > 0, !reportedAudioConform else { return }
        reportedAudioConform = true
        let from = writer.conformedFromChannels
        let to = writer.audioTrackChannels
        DispatchQueue.main.async {
            self.onError?(.takeAudioChannelsConformed(from: from, to: to))
        }
    }

    /// Say once per take that the writer had to keep its own audio track alive,
    /// and mirror the running tally.
    ///
    /// The padding itself happens in the writer, which is the only place that
    /// knows the fragment interval and the latched width (see
    /// `TakeWriter.padAudioIfNeeded`); the ALARM has to happen here, because the
    /// writer has no callbacks — exactly the split `noteAudioConform` has. Once
    /// per take, because a starved track pads on every frame for the rest of the
    /// take and the operator needs to be told the sound is gone, not how often.
    ///
    /// Called from the frame path, so the cheap case is the one that matters: a
    /// take nobody starves costs one integer comparison per frame and never
    /// takes the lock.
    func noteAudioPadding(from writer: TakeWriter) {
        let padded = writer.paddedAudioPackets
        guard padded != mirroredAudioPadding else { return }
        let delta = padded - mirroredAudioPadding
        mirroredAudioPadding = padded
        noteHealth {
            $0.paddedAudioPacketsInTake = padded
            $0.paddedAudioPacketsTotal += delta
        }
        guard !reportedAudioStarved else { return }
        reportedAudioStarved = true
        DispatchQueue.main.async { self.onError?(.takeAudioStarved) }
    }

    /// Mirror the writer's audio-drop tally, which lives on the writer and is
    /// only ever bumped from the capture queue. The delta is tracked here so
    /// the running session total survives the take that produced it, and so a
    /// packet that was accepted costs no lock.
    func noteAudioDrops(from writer: TakeWriter) {
        let dropped = writer.droppedAudioPackets
        guard dropped != mirroredAudioDrops else { return }
        let delta = dropped - mirroredAudioDrops
        mirroredAudioDrops = dropped
        noteHealth {
            $0.droppedAudioPacketsInTake = dropped
            $0.droppedAudioPacketsTotal += delta
        }
    }
}

extension CapturePipeline {
    /// A frame the wire converter could not produce.
    ///
    /// **The one drop nothing could see.** It happens before the take path, so
    /// no recording counter moves; arrival is stamped at ingress
    /// (`CapturePipeline+Input`, "stamped before the window test on purpose"),
    /// so the frame watchdog goes on believing frames are coming. REC stayed
    /// red, the take stayed open, and nothing at all reached the file.
    ///
    /// Alarms on the same shape as the dropped-frame alarm beside it — a
    /// threshold and then every hundredth — because one lost frame is a pool
    /// that has not recycled yet and a stream of them is the take.
    func noteConversionFailure() {
        conversionFailures += 1
        let count = conversionFailures
        noteHealth { $0.conversionFailures = count }
        guard count == Self.droppedFrameAlarmThreshold || count % 100 == 0
        else { return }
        DispatchQueue.main.async {
            self.onError?(.frameLostConversionFailed(count: count))
        }
    }

    /// An 8-bit frame whose limited→full expansion could not be made.
    ///
    /// Counted and not alarmed: the frame still reaches the file, and what is
    /// wrong with it is its levels rather than its existence. The count is the
    /// honest record, because the levels log now says `passthrough` for these
    /// and a bundle would otherwise show only that the mode changed.
    func noteExpansionFallback() {
        expansionFallbacks += 1
        let count = expansionFallbacks
        noteHealth { $0.expansionFallbacks = count }
    }
}
