import Foundation
import Testing

@testable import CaptureCore

/// The taught indicator as a row of the REC state table: the confirm-frame
/// hysteresis doing the work, a blinking dot surviving it, and the two rules
/// about which trigger may close whose take.
///
/// The readings are handed in directly here. In the app they come from the
/// watcher a few times a second and are latched (see
/// `CapturePipeline+VisualRec`), so a "frame" in this suite is a frame that
/// CARRIES a reading — which is exactly the unit the confirm counts are in, and
/// is why the operator's existing numbers are long enough in wall clock to ride
/// out a flash.
@Suite struct VisualRecDetectorTests {
    private func detector(start: Int = 4, stop: Int = 12,
                          vancOnly: Bool = true) -> RecDetector {
        RecDetector(config: RecDetectorConfig(startDebounceFrames: start,
                                              stopDebounceFrames: stop,
                                              vancOnly: vancOnly))
    }

    private func tc(_ frame: Int) -> Timecode {
        Timecode(frameNumber: 10 * 90000 + frame, fps: 25)
    }

    /// Feed a run of readings and collect whatever came out.
    private func run(_ detector: RecDetector, _ readings: [VisualRecReading?],
                     from index: Int = 0,
                     timecode: ((Int) -> Timecode?)? = nil) -> [RecEvent] {
        var events: [RecEvent] = []
        for (offset, reading) in readings.enumerated() {
            let frame = index + offset
            let sample = FrameSample(index: frame,
                                     timecode: timecode?(frame),
                                     visualRec: reading)
            if let event = detector.process(sample) { events.append(event) }
        }
        return events
    }

    // MARK: - the hysteresis does the work

    /// The confirm run is what starts the take, and not one reading earlier.
    @Test func theStartConfirmRunHasToCompleteBeforeATakeStarts() {
        let detector = detector(start: 4)
        // three readings of rolling is not four
        #expect(run(detector, Array(repeating: .rolling, count: 3)).isEmpty)
        #expect(!detector.isRecording)
        // the fourth fires, and it names the FIRST rolling frame as the start
        let events = run(detector, [.rolling], from: 3)
        #expect(events == [.started(atIndex: 0, timecode: nil)],
                "\(events)")
        #expect(detector.isRecording)
        #expect(detector.activeTrigger == .visual)
    }

    /// A reading that disagrees breaks the run — the confirm is CONSECUTIVE
    /// evidence, which is the whole reason it filters anything.
    @Test func anIdleReadingBreaksAStartRun() {
        let detector = detector(start: 4)
        let events = run(detector, [.rolling, .rolling, .rolling, .idle,
                                    .rolling, .rolling, .rolling])
        #expect(events.isEmpty, "the broken run still started a take: \(events)")
        #expect(!detector.isRecording)
    }

    /// Frames that carry NO reading leave the run exactly where it was: the
    /// watcher runs at a few hertz, and a frame it did not measure is not
    /// evidence either way. This is the property that makes the confirm count
    /// measured frames.
    @Test func framesWithoutAReadingLeaveTheRunAlone() {
        let detector = detector(start: 4)
        let readings: [VisualRecReading?] = [.rolling, nil, nil, .rolling, nil,
                                             .rolling, nil, nil, nil, .rolling]
        let events = run(detector, readings)
        #expect(events.count == 1, "\(events)")
        #expect(detector.isRecording)
    }

    // MARK: - blinking is the norm

    /// Many cameras flash the dot. A blink-off must not read as "stopped", and
    /// the existing stop confirm is what makes that true — no second debounce,
    /// no units of its own.
    @Test func aBlinkingIndicatorDoesNotStopTheTake() {
        let detector = detector(start: 2, stop: 6)
        _ = run(detector, [.rolling, .rolling])
        #expect(detector.isRecording, "the take never started")

        // ten seconds of a 1 Hz flash as the watcher sees it at 5 Hz: three
        // readings lit, two dark, over and over — never six dark in a row
        var readings: [VisualRecReading?] = []
        for _ in 0..<10 {
            readings += [.rolling, .rolling, .rolling, .idle, .idle]
        }
        let events = run(detector, readings, from: 2)
        #expect(events.isEmpty, "a blink closed the take: \(events)")
        #expect(detector.isRecording)
    }

    /// …and the dot actually going away does close it, after the confirm.
    @Test func anUnbrokenRunOfIdleReadingsStopsTheTake() {
        let detector = detector(start: 2, stop: 6)
        _ = run(detector, [.rolling, .rolling])
        #expect(detector.isRecording)

        let short = run(detector, Array(repeating: .idle, count: 5), from: 2)
        #expect(short.isEmpty, "five of six confirmed a stop: \(short)")
        let events = run(detector, [.idle], from: 7)
        // the take's last frame is the one before the run of idle readings began
        #expect(events == [.stopped(atIndex: 1)], "\(events)")
        #expect(!detector.isRecording)
        #expect(detector.activeTrigger == nil)
    }

    /// A camera whose confirm is tuned tight still gets a decision, and the
    /// numbers are the operator's own — this suite drives the SAME two settings
    /// the timecode machine reads.
    @Test func theConfirmCountsAreTheSameTwoSettings() {
        let tight = detector(start: 1, stop: 1)
        #expect(run(tight, [.rolling]).count == 1)
        #expect(run(tight, [.idle], from: 1).count == 1)

        let loose = detector(start: 20, stop: 30)
        #expect(run(loose, Array(repeating: .rolling, count: 19)).isEmpty)
        #expect(run(loose, [.rolling], from: 19).count == 1)
    }

    // MARK: - which trigger may close whose take

    /// The load-bearing one. The visual trigger exists for a camera whose
    /// timecode does not run, so a stalled or absent timecode is the NORMAL
    /// state of a take it opened — and must never close it, however long it
    /// stalls.
    @Test func timecodeInferenceNeverClosesAVisualTake() {
        // Auto mode: the timecode machine is live alongside the indicator
        let detector = detector(start: 2, stop: 4, vancOnly: false)
        _ = run(detector, [.rolling, .rolling], timecode: { _ in self.tc(0) })
        #expect(detector.isRecording)
        #expect(detector.activeTrigger == .visual)

        // fifty frames of frozen timecode, and half of them with none at all
        var events: [RecEvent] = []
        for index in 2..<52 {
            let frozen = index % 2 == 0 ? tc(0) : nil
            if let event = detector.process(
                FrameSample(index: index, timecode: frozen)) {
                events.append(event)
            }
        }
        #expect(events.isEmpty, "timecode inference closed a visual take: \(events)")
        #expect(detector.isRecording)

        // …and a timecode JUMP is inert too, for the same reason
        let jump = detector.process(FrameSample(
            index: 52, timecode: Timecode(frameNumber: 424_242, fps: 25)))
        #expect(jump == nil)
        #expect(detector.isRecording)
    }

    /// An explicit VANC stop DOES close it: a camera that says it stopped has
    /// settled the question, and that is the one kind of evidence that outranks
    /// everything else here.
    @Test func aVancStopClosesAVisualTake() {
        let detector = detector(start: 2)
        _ = run(detector, [.rolling, .rolling])
        #expect(detector.isRecording)
        let stopped = detector.process(FrameSample(index: 2, timecode: nil,
                                                   vancTrigger: .recordStop))
        #expect(stopped == .stopped(atIndex: 2))
        #expect(!detector.isRecording)
    }

    /// The mirror image: the indicator does not close a take the timecode or a
    /// VANC trigger opened. That camera's overlay may not even be on the
    /// monitoring output during such a take, and a box watching nothing reads
    /// idle all day.
    @Test func theIndicatorDoesNotCloseSomebodyElsesTake() {
        let byVanc = detector(start: 2, stop: 3, vancOnly: false)
        // a VANC trigger opens the take
        _ = byVanc.process(FrameSample(index: 0, timecode: tc(0),
                                       vancTrigger: .recordStart))
        #expect(byVanc.activeTrigger == .vanc)
        // …and a long run of idle readings does nothing to it
        var events = run(byVanc, Array(repeating: .idle, count: 20), from: 1,
                         timecode: { self.tc($0) })
        #expect(events.isEmpty, "the indicator closed a VANC take: \(events)")
        #expect(byVanc.isRecording)

        // the same for a timecode-started take
        let byTimecode = detector(start: 2, stop: 3, vancOnly: false)
        var index = 0
        for _ in 0..<3 {
            _ = byTimecode.process(FrameSample(index: index, timecode: tc(index)))
            index += 1
        }
        #expect(byTimecode.activeTrigger == .timecode)
        events = run(byTimecode, Array(repeating: .idle, count: 20), from: index,
                     timecode: { self.tc($0) })
        #expect(events.isEmpty, "the indicator closed a timecode take: \(events)")
    }

    // MARK: - it composes with the modes

    /// VANC-only is the production default and the recommended companion for
    /// this feature: the timecode machine is off, so nothing but the indicator
    /// (or an explicit trigger) can move the take.
    @Test func vancOnlyModeStillAdmitsTheIndicator() {
        let detector = detector(start: 3, vancOnly: true)
        // running timecode alone still starts nothing, which is the rule this
        // mode exists for
        for index in 0..<30 {
            #expect(detector.process(FrameSample(index: index,
                                                 timecode: tc(index))) == nil)
        }
        // …and the indicator does
        let events = run(detector, [.rolling, .rolling, .rolling], from: 30,
                         timecode: { self.tc($0) })
        #expect(events.count == 1, "\(events)")
        #expect(detector.activeTrigger == .visual)
    }

    /// A VANC trigger arriving while the indicator's start run is part way
    /// through wins on the spot — explicit knowledge fires without debounce, and
    /// the take then belongs to it.
    @Test func anExplicitTriggerOutranksAPartialVisualRun() {
        let detector = detector(start: 6)
        _ = run(detector, [.rolling, .rolling, .rolling])
        #expect(!detector.isRecording)
        let started = detector.process(FrameSample(index: 3, timecode: tc(3),
                                                   vancTrigger: .recordStart,
                                                   visualRec: .rolling))
        #expect(started == .started(atIndex: 3, timecode: tc(3)))
        #expect(detector.activeTrigger == .vanc)
    }

    /// A reset clears the visual runs with everything else — a new capture
    /// session must not inherit half a confirm from the last one.
    @Test func resetClearsTheVisualRuns() {
        let detector = detector(start: 4)
        _ = run(detector, [.rolling, .rolling, .rolling])
        detector.reset()
        #expect(detector.activeTrigger == nil)
        #expect(run(detector, [.rolling], from: 3).isEmpty,
                "a stale run survived the reset")
    }
}
