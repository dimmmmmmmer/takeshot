import Foundation

/// The taught-indicator row of the state table: the third trigger, beside the
/// VANC packet and the running timecode.
///
/// Its own file so `RecDetector` keeps the shape it had — that file is the one
/// CaptureCore file already at the top of the complexity range, and a third
/// machine written inline is how the two existing ones become hard to read.
///
/// **No second debounce.** The confirm counts are the operator's existing
/// `startDebounceFrames` / `stopDebounceFrames`, unchanged and in the same
/// units: frames. What differs is which frames count. The runs advance only on
/// frames that CARRY a reading, and the watcher offers a reading a few times a
/// second rather than on every frame (see `CapturePipeline+VisualRec`), so a
/// confirm of N is N MEASURED frames. That is also what makes the numbers an
/// operator already has long enough in wall clock to ride out a blinking dot:
/// at 25 fps the watcher measures every fifth frame, so a stop confirm of 12
/// spans 12 readings — about 2.4 s — where 12 of every frame would have spanned
/// 0.48 s and chattered on any camera that flashes the indicator once a second.
///
/// **Blinking is the norm and it costs nothing extra.** A blink-off reading
/// while the take is rolling advances the stop run and nothing else; the next
/// reading that says rolling clears it. Only an unbroken run of `off` readings
/// as long as the confirm closes the take, which is exactly what the existing
/// hysteresis is for.
extension RecDetector {
    /// One reading's effect. nil for "nothing happened yet", which is the
    /// overwhelming majority of frames and also what lets the timecode machine
    /// downstream still see the frame.
    func visualEvent(for reading: VisualRecReading,
                     sample: FrameSample) -> RecEvent? {
        switch (reading, isRecording) {
        case (.rolling, false):
            return accumulateVisualStart(sample)
        case (.idle, true):
            return accumulateVisualStop(at: sample.index)
        // Evidence that agrees with the state we are already in is not an event;
        // it clears the run that was heading the other way.
        case (.rolling, true):
            visualStopRun = 0
            return nil
        case (.idle, false):
            visualStartRun = 0
            return nil
        }
    }

    /// The indicator is lit and no take is open: run up the start confirm.
    ///
    /// The take's start frame is the FIRST frame that read rolling, not the one
    /// the confirm fired on — the same shape as the timecode machine's backfill,
    /// and the pipeline pulls those frames out of the pre-roll ring. It is not
    /// backed up any further than that on purpose: an indicator lights some
    /// unknown number of frames after the camera actually rolled, and inventing
    /// a correction for a latency nobody measured would be a guess dressed as a
    /// frame number. Covering it is what the pre-roll setting is for, and the
    /// ring is sized for the visual confirm's whole span while the trigger is
    /// armed (see `preRollCapacity`).
    private func accumulateVisualStart(_ sample: FrameSample) -> RecEvent? {
        visualStopRun = 0
        if visualStartRun == 0 {
            visualStartIndex = sample.index
            visualStartTimecode = sample.timecode
        }
        visualStartRun += 1
        guard visualStartRun >= config.startDebounceFrames else { return nil }
        setRecording(true, trigger: .visual)
        return .started(atIndex: visualStartIndex, timecode: visualStartTimecode)
    }

    /// The indicator has gone and a take is open: run up the stop confirm — but
    /// only over a take this trigger opened.
    ///
    /// A take started by a VANC trigger or by running timecode is not ended by
    /// the indicator, for the mirror image of the reason the stall row does not
    /// end a visual take: the camera's own overlay may not even be on the
    /// monitoring output during that take, and a box that is watching nothing
    /// reads `idle` all day.
    private func accumulateVisualStop(at index: Int) -> RecEvent? {
        visualStartRun = 0
        guard activeTrigger == .visual else { return nil }
        if visualStopRun == 0 { visualStopIndex = index }
        visualStopRun += 1
        guard visualStopRun >= config.stopDebounceFrames else { return nil }
        setRecording(false)
        return .stopped(atIndex: max(0, visualStopIndex - 1))
    }
}
