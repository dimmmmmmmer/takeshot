import Testing
@testable import CaptureCore

struct RecDetectorTests {
    private func tc(_ frameNumber: Int, fps: Int = 25, drop: Bool = false) -> Timecode {
        Timecode(frameNumber: frameNumber, fps: fps, isDropFrame: drop)
    }

    // MARK: - start on running TC

    @Test func startsAfterDebounceAndReportsFirstAdvanceFrame() {
        let detector = RecDetector(config: RecDetectorConfig(startDebounceFrames: 4,
                                                             stopDebounceFrames: 12))
        // frames 1-5: TC stalled (camera in standby)
        for i in 1...5 {
            #expect(detector.process(FrameSample(index: i, timecode: tc(1000))) == nil)
        }
        #expect(!detector.isRecording)

        // frames 6-9: TC started advancing
        var event: RecEvent?
        for i in 6...9 {
            event = detector.process(FrameSample(index: i, timecode: tc(1000 + i - 5))) ?? event
        }
        #expect(detector.isRecording)
        // debounce 4 → event on frame 9, but the actual start is frame 5
        // (the last frame with the "old" TC, movement began between 5 and 6)
        #expect(event == .started(atIndex: 5, timecode: tc(1000)))
    }

    @Test func shortGlitchDoesNotStart() {
        let detector = RecDetector(config: RecDetectorConfig(startDebounceFrames: 4,
                                                             stopDebounceFrames: 12))
        // two frames of movement, then stalled again — no REC
        #expect(detector.process(FrameSample(index: 1, timecode: tc(100))) == nil)
        #expect(detector.process(FrameSample(index: 2, timecode: tc(101))) == nil)
        #expect(detector.process(FrameSample(index: 3, timecode: tc(102))) == nil)
        #expect(detector.process(FrameSample(index: 4, timecode: tc(102))) == nil)
        #expect(detector.process(FrameSample(index: 5, timecode: tc(102))) == nil)
        #expect(!detector.isRecording)
    }

    // MARK: - stop

    @Test func stopsAfterStallDebounce() {
        let detector = RecDetector(config: RecDetectorConfig(startDebounceFrames: 2,
                                                             stopDebounceFrames: 3))
        var lastEvent: RecEvent?

        // ramp up to REC
        for i in 1...5 {
            lastEvent = detector.process(FrameSample(index: i, timecode: tc(200 + i))) ?? lastEvent
        }
        #expect(detector.isRecording)

        // TC stalls at frame 6
        for i in 6...8 {
            lastEvent = detector.process(FrameSample(index: i, timecode: tc(205))) ?? lastEvent
        }
        #expect(!detector.isRecording)
        // the first stalled frame is 6, so the take's last frame is 5
        #expect(lastEvent == .stopped(atIndex: 5))
    }

    @Test func briefStallDoesNotStop() {
        let detector = RecDetector(config: RecDetectorConfig(startDebounceFrames: 2,
                                                             stopDebounceFrames: 5))
        for i in 1...4 {
            _ = detector.process(FrameSample(index: i, timecode: tc(300 + i)))
        }
        #expect(detector.isRecording)

        // 2 frames stalled (less than debounce 5), then advancing again
        _ = detector.process(FrameSample(index: 5, timecode: tc(304)))
        _ = detector.process(FrameSample(index: 6, timecode: tc(304)))
        _ = detector.process(FrameSample(index: 7, timecode: tc(305)))
        #expect(detector.isRecording)
    }

    @Test func timecodeJumpWhileRecordingStopsImmediately() {
        let detector = RecDetector(config: RecDetectorConfig(startDebounceFrames: 2,
                                                             stopDebounceFrames: 12))
        for i in 1...4 {
            _ = detector.process(FrameSample(index: i, timecode: tc(400 + i)))
        }
        #expect(detector.isRecording)

        let event = detector.process(FrameSample(index: 5, timecode: tc(9000)))
        #expect(event == .stopped(atIndex: 4))
        #expect(!detector.isRecording)
    }

    /// One misread RP188 word is a hiccup, not a camera stop: a frame skipped
    /// or a step back is absorbed and the take stays open. A real jump (the
    /// test above) still closes on the spot.
    @Test func aOneFrameTimecodeHiccupDoesNotSplitTheTake() {
        let detector = RecDetector(config: RecDetectorConfig(startDebounceFrames: 2,
                                                             stopDebounceFrames: 12))
        for i in 1...4 {
            _ = detector.process(FrameSample(index: i, timecode: tc(400 + i)))
        }
        #expect(detector.isRecording)

        #expect(detector.process(FrameSample(index: 5, timecode: tc(406))) == nil,
                "a skipped word closed the take")
        #expect(detector.process(FrameSample(index: 6, timecode: tc(405))) == nil,
                "a step back closed the take")
        #expect(detector.process(FrameSample(index: 7, timecode: tc(407))) == nil)
        #expect(detector.isRecording)
    }

    /// Idle, the tolerance is off: a source whose word steps by two every
    /// frame is not running cleanly, and the start debounce does not open on
    /// it.
    @Test func aTwoFrameStepWhileIdleDoesNotOpenATake() {
        let detector = RecDetector(config: RecDetectorConfig(startDebounceFrames: 2,
                                                             stopDebounceFrames: 12))
        for i in 1...6 {
            #expect(detector.process(FrameSample(index: i, timecode: tc(100 + 2 * i))) == nil,
                    "a word stepping by two opened a take at frame \(i)")
        }
        #expect(!detector.isRecording)
    }

    /// The step back has a midnight twin: 00:00:00:00 re-read as 23:59:59:24
    /// is one word back across the wrap, not a jump of a day.
    @Test func aReReadAcrossMidnightDoesNotSplitTheTake() {
        let detector = RecDetector(config: RecDetectorConfig(startDebounceFrames: 2,
                                                             stopDebounceFrames: 12))
        let day = Timecode.dayFrames(fps: 25, isDropFrame: false)
        var index = 0
        for frame in [day - 4, day - 3, day - 2, day - 1] {
            index += 1
            _ = detector.process(FrameSample(index: index, timecode: tc(frame)))
        }
        #expect(detector.isRecording)
        index += 1
        #expect(detector.process(FrameSample(index: index, timecode: tc(0))) == nil, "the wrap itself")
        index += 1
        #expect(detector.process(FrameSample(index: index, timecode: tc(day - 1))) == nil,
                "a re-read of the last word before midnight closed the take")
        index += 1
        #expect(detector.process(FrameSample(index: index, timecode: tc(1))) == nil)
        #expect(detector.isRecording)
    }

    @Test func lostTimecodeWhileRecordingStopsAfterDebounce() {
        let detector = RecDetector(config: RecDetectorConfig(startDebounceFrames: 2,
                                                             stopDebounceFrames: 3))
        for i in 1...4 {
            _ = detector.process(FrameSample(index: i, timecode: tc(500 + i)))
        }
        #expect(detector.isRecording)

        var lastEvent: RecEvent?
        for i in 5...7 {
            lastEvent = detector.process(FrameSample(index: i, timecode: nil)) ?? lastEvent
        }
        #expect(lastEvent == .stopped(atIndex: 4))
    }

    // MARK: - VANC triggers

    @Test func vancStartAndStopAreImmediate() {
        let detector = RecDetector()

        let start = detector.process(
            FrameSample(index: 10, timecode: tc(600), vancTrigger: .recordStart))
        #expect(start == .started(atIndex: 10, timecode: tc(600)))
        #expect(detector.isRecording)

        let stop = detector.process(
            FrameSample(index: 20, timecode: tc(610), vancTrigger: .recordStop))
        #expect(stop == .stopped(atIndex: 20))
        #expect(!detector.isRecording)
    }

    @Test func duplicateVancStartIsIgnored() {
        let detector = RecDetector()
        _ = detector.process(FrameSample(index: 1, timecode: nil, vancTrigger: .recordStart))
        let repeated = detector.process(FrameSample(index: 2, timecode: nil, vancTrigger: .recordStart))
        #expect(repeated == nil)
        #expect(detector.isRecording)
    }

    // MARK: - drop-frame

    @Test func dropFrameMinuteBoundaryCountsAsAdvancing() {
        let detector = RecDetector(config: RecDetectorConfig(startDebounceFrames: 3,
                                                             stopDebounceFrames: 12))
        // 00:00:59;27 → 00:01:00;03 in DF30: continuous recording across a minute boundary
        let boundary = Timecode(hours: 0, minutes: 0, seconds: 59, frames: 27,
                                fps: 30, isDropFrame: true)
        var event: RecEvent?
        for i in 0..<6 {
            event = detector.process(FrameSample(
                index: i + 1, timecode: boundary.advanced(by: i))) ?? event
        }
        #expect(detector.isRecording)
        #expect(event != nil)
    }

    // MARK: - several takes in a row

    /// Counts the take boundaries a run of frames produces.
    private struct EventTally {
        var starts = 0
        var stops = 0

        mutating func record(_ event: RecEvent) {
            if case .started = event { starts += 1 } else { stops += 1 }
        }
    }

    /// Push `count` frames carrying `timecode` and tally what comes back.
    private func feed(_ detector: RecDetector, frames count: Int,
                      timecode: Timecode, index: inout Int,
                      tally: inout EventTally) {
        for _ in 0..<count {
            index += 1
            guard let event = detector.process(
                FrameSample(index: index, timecode: timecode)) else { continue }
            tally.record(event)
        }
    }

    @Test func threeConsecutiveTakes() {
        let detector = RecDetector(config: RecDetectorConfig(startDebounceFrames: 2,
                                                             stopDebounceFrames: 2))
        var tally = EventTally()
        var index = 0
        var tcBase = 10_000

        for _ in 1...3 {
            // pause: TC stalled
            feed(detector, frames: 5, timecode: tc(tcBase),
                 index: &index, tally: &tally)
            // recording: TC advances for 10 frames
            for frame in 1...10 {
                feed(detector, frames: 1, timecode: tc(tcBase + frame),
                     index: &index, tally: &tally)
            }
            tcBase += 10
        }
        // final pause to close the last take
        feed(detector, frames: 5, timecode: tc(tcBase),
             index: &index, tally: &tally)

        #expect(tally.starts == 3)
        #expect(tally.stops == 3)
    }
}
