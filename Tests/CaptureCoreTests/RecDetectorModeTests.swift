import Foundation
import Testing

@testable import CaptureCore

/// The detector in VANC-only mode — the production DEFAULT ("Detection default
/// is VANC-only": running timecode alone, e.g. a Resolve playout feeding the
/// board, must never start a take) — and the timecode machine at the day wrap.
/// The mode had no direct tests; every existing suite drives the timecode
/// machine.
@Suite struct RecDetectorModeTests {
    private func vancOnly() -> RecDetector {
        RecDetector(config: RecDetectorConfig(startDebounceFrames: 3,
                                              stopDebounceFrames: 5,
                                              vancOnly: true))
    }

    private func tc(_ frame: Int) -> Timecode {
        Timecode(frameNumber: 10 * 90000 + frame, fps: 25)
    }

    /// The rule the default exists for: running timecode alone never starts a
    /// take in VANC-only mode, however long it runs.
    @Test func vancOnlyIgnoresRunningTimecode() {
        let detector = vancOnly()
        for index in 0..<50 {
            let event = detector.process(FrameSample(index: index,
                                                     timecode: tc(index)))
            #expect(event == nil, "frame \(index) produced \(String(describing: event))")
        }
        #expect(!detector.isRecording)
    }

    /// The reason the timecode machine is disabled outright: after a VANC
    /// start, a camera whose timecode STANDS STILL (or is absent) is still
    /// recording — the stall rows must not close the take, however many frames
    /// pass. This is the "otherwise every frame after a VANC start reads as a
    /// stall and the take self-terminates" case from the config's own doc.
    @Test func vancOnlyNeverStopsOnStalledOrMissingTimecode() {
        let detector = vancOnly()
        let started = detector.process(FrameSample(index: 0, timecode: tc(0),
                                                   vancTrigger: .recordStart))
        #expect(started == .started(atIndex: 0, timecode: tc(0)))
        for index in 1..<40 {
            // half the frames carry a frozen TC, half carry none at all
            let frozen = index % 2 == 0 ? tc(0) : nil
            let event = detector.process(FrameSample(index: index,
                                                     timecode: frozen))
            #expect(event == nil, "frame \(index) produced \(String(describing: event))")
        }
        #expect(detector.isRecording, "a stall closed a VANC-triggered take")
        // only the explicit trigger ends it
        let stopped = detector.process(FrameSample(index: 40, timecode: nil,
                                                   vancTrigger: .recordStop))
        #expect(stopped == .stopped(atIndex: 40))
        #expect(!detector.isRecording)
    }

    /// A timecode discontinuity — the one thing that stops a timecode-mode
    /// take immediately — is also inert in VANC-only mode.
    @Test func vancOnlyIgnoresDiscontinuities() {
        let detector = vancOnly()
        _ = detector.process(FrameSample(index: 0, timecode: tc(0),
                                         vancTrigger: .recordStart))
        let jump = detector.process(FrameSample(
            index: 1, timecode: Timecode(frameNumber: 1000, fps: 25)))
        #expect(jump == nil)
        #expect(detector.isRecording)
    }

    // MARK: - the timecode machine at the edges

    /// A take that rolls through midnight: 23:59:59:24 → 00:00:00:00 is one
    /// frame forward, not a discontinuity — a night take must not be cut at
    /// the day wrap.
    @Test func midnightWrapKeepsTheTakeRolling() {
        let detector = RecDetector(config: RecDetectorConfig(
            startDebounceFrames: 3, stopDebounceFrames: 5))
        let wrap = Timecode.dayFrames(fps: 25, isDropFrame: false)
        var index = 0
        var events: [RecEvent] = []
        // start rolling half a second before midnight, run one second past it
        for frame in (wrap - 12)..<(wrap + 25) {
            let sample = FrameSample(
                index: index,
                timecode: Timecode(frameNumber: frame % wrap, fps: 25))
            if let event = detector.process(sample) { events.append(event) }
            index += 1
        }
        #expect(detector.isRecording, "the day wrap stopped the take: \(events)")
        #expect(events.count == 1, "expected one start, got \(events)")
    }

    /// A jump while idle is just a source being scrubbed — nothing starts.
    @Test func discontinuityWhileIdleDoesNothing() {
        let detector = RecDetector()
        #expect(detector.process(FrameSample(index: 0, timecode: tc(0))) == nil)
        let event = detector.process(FrameSample(
            index: 1, timecode: Timecode(frameNumber: 424242, fps: 25)))
        #expect(event == nil)
        #expect(!detector.isRecording)
    }

    /// Frames with no timecode at all, from power-on: the stall row while idle
    /// accumulates nothing and never fires a stop for a take that never was.
    @Test func leadingFramesWithoutTimecodeStayIdle() {
        let detector = RecDetector()
        for index in 0..<20 {
            #expect(detector.process(FrameSample(index: index,
                                                 timecode: nil)) == nil)
        }
        #expect(!detector.isRecording)
    }
}
