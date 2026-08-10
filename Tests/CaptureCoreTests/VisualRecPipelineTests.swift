import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// Where the watcher runs, how often, and what it costs the capture queue.
///
/// The rule this suite exists for is the one the scope analyzer already follows:
/// never on the capture queue. A record indicator does not need 25 fps, so the
/// pass is offered a few times a second on a queue of its own with latest-wins
/// coalescing — and a pass that hangs must cost frames nothing.
struct VisualRecPipelineTests {
    private func idlePipeline() -> CapturePipeline {
        var settings = CaptureSettings()
        settings.capture.detectionMode = .manual
        settings.capture.preRollFrames = 0
        // The start confirm is put out of this suite's reach on purpose. The
        // indicator is a trigger in Manual mode too — that is the composition
        // this feature is built on — so a rolling reading here would open a
        // take, and a take puts an encoder and a destination folder in the way
        // of a suite that is about the watcher. Thirty readings is six seconds
        // at the watcher's rate and nothing below pushes that many frames.
        // (`PipelineScopeTests` avoids the encoder the same way.) The ring it
        // implies costs nothing: every push here hands over the same buffer.
        settings.capture.startDebounceFrames = 30
        let pipeline = CapturePipeline(config: .init(settings: settings,
                                                    takeNumber: 1))
        pipeline.handleFormat(CaptureFormat(
            width: VisualRecProbe.width, height: VisualRecProbe.height,
            frameRate: 25, timecodeFPS: 25, name: "test"))
        return pipeline
    }

    private func push(_ pipeline: CapturePipeline, _ buffer: CVPixelBuffer,
                      frames: Int, from start: Int = 1) {
        for index in start..<(start + frames) {
            pipeline.handleFrame(
                pixelBuffer: buffer,
                pts: CMTime(value: CMTimeValue(index * 40), timescale: 1000),
                timecode: nil, vancTrigger: nil)
        }
    }

    // MARK: - the rate

    /// The delivered rate is a target in hertz, not a frame count: the same five
    /// passes a second at every signal rate this app sees. Asserted as
    /// arithmetic, deliberately — the wall-clock half of a rate measurement
    /// belongs on a machine that is not also building something.
    @Test func theStrideDeliversTheChosenRateAtEveryFrameRate() {
        for rate in [23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0] {
            let stride = CapturePipeline.visualRecStride(atFrameRate: rate)
            let delivered = rate / Double(stride)
            #expect(abs(delivered - CapturePipeline.visualRecUpdatesPerSecond)
                    <= 1.5,
                    "\(rate) fps / stride \(stride) = \(delivered) Hz")
        }
        #expect(CapturePipeline.visualRecStride(atFrameRate: 25) == 5)
        #expect(CapturePipeline.visualRecStride(atFrameRate: 60) == 12)
        // a nonsense rate still yields a usable stride rather than a divide by nil
        #expect(CapturePipeline.visualRecStride(atFrameRate: 0) == 1)
        #expect(CapturePipeline.visualRecUpdatesPerSecond == 5)
    }

    // MARK: - off costs nothing

    /// A disarmed trigger analyses nothing at all: no reading, and no projection
    /// either, which is the observable proof that no pass ran rather than that a
    /// pass ran and said nothing.
    @Test func aDisarmedTriggerAnalysesNothing() async {
        let pipeline = idlePipeline()
        push(pipeline, VisualRecProbe.frame([VisualRecProbe.dot]), frames: 30)
        // give any pass that was going to run the chance to
        try? await Task.sleep(for: .milliseconds(300))
        #expect(pipeline.visualRecReading == nil)
        #expect(pipeline.visualRecPosition == nil,
                "a pass ran with the trigger disarmed")
    }

    /// Switching the trigger off clears the latch, so a reading taken while it
    /// was armed cannot act on a frame after it was switched off.
    @Test func disarmingClearsTheLatch() async {
        let pipeline = idlePipeline()
        let rolling = VisualRecProbe.frame([VisualRecProbe.dot])
        pipeline.setVisualRec(VisualRecProbe.taught(
            rolling: rolling, idle: VisualRecProbe.frame()))
        push(pipeline, rolling, frames: 20)
        await TestWait.until { pipeline.visualRecReading != nil }
        #expect(pipeline.visualRecReading == .rolling)

        var off = pipeline.visualRec
        off.isOn = false
        pipeline.setVisualRec(off)
        #expect(pipeline.visualRecReading == nil)
        #expect(pipeline.latchedVisualRecReading() == nil)
    }

    // MARK: - the live path

    /// The armed trigger reads the picture the pipeline is showing, and its
    /// reading changes with it.
    @Test func theArmedTriggerReadsTheLivePicture() async {
        let pipeline = idlePipeline()
        let rolling = VisualRecProbe.frame([VisualRecProbe.dot])
        let idle = VisualRecProbe.frame()
        let readings = EventCollector<VisualRecReading?>()
        pipeline.onVisualRecReading = { readings.append($0) }
        pipeline.setVisualRec(VisualRecProbe.taught(rolling: rolling, idle: idle))

        // Polled on the COLLECTOR, because that is what the assertions here are
        // about. `publishVisualRec` sets the latch under its lock and then hops
        // the report to the main queue, so there is a window in which
        // `visualRecReading` already reads `.idle` and `readings` does not
        // contain it yet. Waiting on the latch and asserting on the collector is
        // waiting for one outcome and checking another: it went red exactly once
        // on a loaded machine, with `[Optional(.rolling)]` collected and the
        // latch already correct — the watcher had seen IDLE and only the delivery
        // was behind.
        push(pipeline, rolling, frames: 20)
        #expect(await TestWait.becomesTrue {
            readings.all.contains { $0 == VisualRecReading.rolling }
        }, "the watcher never reported ROLLING")
        #expect(pipeline.visualRecReading == .rolling)

        push(pipeline, idle, frames: 20, from: 21)
        #expect(await TestWait.becomesTrue {
            readings.all.contains { $0 == VisualRecReading.idle }
        }, "the watcher never reported IDLE")
        #expect(pipeline.visualRecReading == .idle)

        // the callback fired for each CHANGE and not per pass — the readout
        // exists to be read, not to poke the main queue five times a second
        #expect(readings.all.count <= 4, "\(readings.all.count) reports")
    }

    /// A red practical elsewhere in frame, all the way through the pipeline: the
    /// box does not see it, so nothing changes.
    @Test func aRedPracticalOutsideTheBoxChangesNothingLive() async {
        let pipeline = idlePipeline()
        pipeline.setVisualRec(VisualRecProbe.taught(
            rolling: VisualRecProbe.frame([VisualRecProbe.dot]),
            idle: VisualRecProbe.frame()))
        push(pipeline, VisualRecProbe.frame([VisualRecProbe.practical]),
             frames: 25)
        await TestWait.until { pipeline.visualRecReading != nil }
        #expect(pipeline.visualRecReading == .idle,
                "a red practical read as a roll through the live path")
    }

    // MARK: - never on the capture queue

    /// The proof that the pass is off the capture queue: block the watcher's
    /// queue outright and the frame path keeps delivering frames at the same
    /// rate. A pass on the capture queue would stall every one of them behind
    /// the sleep.
    ///
    /// Measured as a ratio against the same run with the queue free, so it says
    /// nothing about how fast this machine is — only that one is not waiting on
    /// the other.
    @Test func aStalledWatcherQueueDoesNotHoldUpTheFramePath() async throws {
        let pipeline = idlePipeline()
        let rolling = VisualRecProbe.frame([VisualRecProbe.dot])
        pipeline.setVisualRec(VisualRecProbe.taught(
            rolling: rolling, idle: VisualRecProbe.frame()))

        // warm the path up so the first-frame allocations are not in the number
        push(pipeline, rolling, frames: 10)
        await TestWait.until { pipeline.visualRecReading != nil }

        // park the watcher's queue for a third of a second — eight frame
        // intervals at 25 fps — and push frames through
        pipeline.visualRecQueue.async { Thread.sleep(forTimeInterval: 0.35) }
        let start = DispatchTime.now().uptimeNanoseconds
        push(pipeline, rolling, frames: 40, from: 11)
        // the frame path is synchronous on its own queue; wait for it to drain
        pipeline.queue.sync {}
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6

        #expect(elapsed < 300,
                "40 frames took \(elapsed) ms; the watcher's stall reached the capture queue")
    }

    /// Latest-wins: while one pass is in flight the frames that arrive are
    /// skipped rather than queued, so a slow machine analyses fewer frames and
    /// never falls behind on them.
    @Test func passesAreCoalescedRatherThanQueued() async throws {
        let pipeline = idlePipeline()
        let rolling = VisualRecProbe.frame([VisualRecProbe.dot])
        let idle = VisualRecProbe.frame()
        let readings = EventCollector<VisualRecReading?>()
        pipeline.onVisualRecReading = { readings.append($0) }
        pipeline.setVisualRec(VisualRecProbe.taught(rolling: rolling, idle: idle))

        // hold the watcher's queue while a hundred frames go by: without the
        // busy gate that is twenty queued passes waiting behind the stall
        pipeline.visualRecQueue.async { Thread.sleep(forTimeInterval: 0.4) }
        push(pipeline, rolling, frames: 100)
        // Both queues drained rather than slept on. `queue.sync` proves every
        // frame was processed, so every offer this burst will ever make has been
        // made; `visualRecQueue.sync` waits out the stall and any pass queued
        // behind it. No frame follows, so after these two no further pass can be
        // offered and the count can only be what it already is — where the
        // 600 ms sleep this replaces was a wall-clock window that could look
        // either too early (nothing delivered) or too late.
        pipeline.queue.sync {}
        pipeline.visualRecQueue.sync {}
        #expect(await TestWait.becomesTrue { readings.all.count >= 1 },
                "no pass at all got through the stall")

        // one pass got through, and it is the only reading that was published
        #expect(readings.all.count == 1,
                "\(readings.all.count) passes landed behind a stalled queue")
        #expect(pipeline.visualRecReading == .rolling)
    }

    /// Capture stopping clears the latch: the reading describes a frame from the
    /// session that just ended, and the next session must earn its own.
    @Test func captureStoppingClearsTheReading() async {
        let pipeline = idlePipeline()
        let rolling = VisualRecProbe.frame([VisualRecProbe.dot])
        pipeline.setVisualRec(VisualRecProbe.taught(
            rolling: rolling, idle: VisualRecProbe.frame()))
        push(pipeline, rolling, frames: 20)
        await TestWait.until { pipeline.visualRecReading != nil }

        pipeline.captureStopped()
        pipeline.queue.sync {}
        #expect(pipeline.visualRecReading == nil)
        #expect(pipeline.visualRecPosition == nil)
    }

    // MARK: - the teach capture

    /// The reference is captured from the frame the pipeline is holding, and it
    /// is the PRE-LUT display buffer — the same stage the watcher reads, so a
    /// viewing LUT switched on after the teaching cannot move a take.
    @Test func theTeachCaptureReadsThePreLUTDisplayFrame() async throws {
        let pipeline = idlePipeline()
        // nothing pushed yet: there is no frame to learn from and it says so
        #expect(pipeline.captureVisualRecSignature() == nil)

        let rolling = VisualRecProbe.frame([VisualRecProbe.dot])
        var teaching = VisualRecTeaching()
        teaching.region = VisualRecProbe.region()
        pipeline.setVisualRec(teaching)
        push(pipeline, rolling, frames: 3)
        await TestWait.until { pipeline.currentPreLUTPreviewBuffer() != nil }

        let captured = try #require(pipeline.captureVisualRecSignature())
        let direct = try #require(VisualRecSampler.signature(
            of: rolling, region: teaching.region))
        // the frame path passes the codes through at "full" levels, so the
        // signature the operator captures is the one the box actually holds
        let drift = zip(captured.codes, direct.codes)
            .map { abs($0 - $1) }.max() ?? 0
        #expect(drift < 2, "the teach capture read a different stage: \(drift)")
    }

    // MARK: - the pre-roll ring

    /// The visual confirm run spans the confirm COUNT times the watcher's
    /// stride, so the pre-roll ring has to be deeper while the trigger is armed —
    /// otherwise the frames closest to the indicator lighting up have already
    /// been dropped by the time the take opens.
    ///
    /// Asserted through the ring's own contents: with the trigger armed the ring
    /// holds the whole confirm span plus the configured lead, and with it
    /// disarmed it holds what it always did and not a frame more.
    @Test func thePreRollRingCoversTheVisualConfirmSpan() async throws {
        var settings = CaptureSettings()
        settings.capture.detectionMode = .manual
        settings.capture.preRollFrames = 5
        settings.capture.startDebounceFrames = 4
        let pipeline = CapturePipeline(config: .init(settings: settings,
                                                     takeNumber: 1))
        pipeline.handleFormat(CaptureFormat(
            width: VisualRecProbe.width, height: VisualRecProbe.height,
            frameRate: 25, timecodeFPS: 25, name: "test"))
        // The camera's menu overlay: an ARMED trigger reading no evidence, so
        // the ring's sizing can be measured with a real confirm count and
        // without a take opening on top of it.
        let untaught = VisualRecProbe.frame([VisualRecProbe.menuOverlay])

        // disarmed: pre-roll 5 + confirm 4 + slack 3
        push(pipeline, untaught, frames: 60)
        var held = pipeline.queue.sync { pipeline.preRollBuffer.count }
        #expect(held == 12, "disarmed ring holds \(held)")

        // armed: the confirm span is 4 readings at a stride of 5 frames
        pipeline.setVisualRec(VisualRecProbe.taught(
            rolling: VisualRecProbe.frame([VisualRecProbe.dot]),
            idle: VisualRecProbe.frame()))
        push(pipeline, untaught, frames: 20, from: 61)
        await TestWait.until { pipeline.queue.sync { pipeline.visualRecArmed } }
        #expect(pipeline.visualRecReading == nil,
                "the untaught fixture produced evidence")
        push(pipeline, untaught, frames: 40, from: 81)
        held = pipeline.queue.sync { pipeline.preRollBuffer.count }
        #expect(held == 28, "armed ring holds \(held), expected 5 + 4*5 + 3")
    }

    // MARK: - the cost

    /// What one pass costs, printed rather than asserted.
    ///
    /// Opt-in (`TAKESHOT_BENCH=1 scripts/test.sh -c release --filter
    /// VisualRecPipeline`) and it asserts no wall-clock number, for the reasons
    /// `ScopePerformanceTests` gives: the pass runs at utility QoS on the
    /// efficiency cores by design, and this suite shares a machine with whatever
    /// else is building on it. What it prints is the number the budget is argued
    /// from — the budget being one stride interval, 200 ms at 25 fps, which the
    /// pass has to finish inside or the busy gate starts skipping.
    ///
    /// Last measured in release: 0.004 ms at 1080p and 0.004 ms at UHD — the same
    /// figure at both, which is the constant-tap-count claim showing up as a
    /// measurement rather than an argument. (Debug, for reference, is 0.255 and
    /// 0.338 ms; the release build vectorises the accumulation.)
    @Test func onePassCost() {
        guard ProcessInfo.processInfo.environment["TAKESHOT_BENCH"] != nil else {
            return
        }
        let teaching = VisualRecProbe.taught(
            rolling: VisualRecProbe.frame([VisualRecProbe.dot]),
            idle: VisualRecProbe.frame())
        for (label, size) in [("1080p", (1920, 1080)), ("UHD", (3840, 2160))] {
            let frame = VisualRecProbe.frame([VisualRecProbe.dot],
                                             width: size.0, height: size.1)
            // warm up
            for _ in 0..<20 {
                _ = VisualRecSampler.signature(of: frame, region: teaching.region)
            }
            let passes = 500
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<passes {
                guard let signature = VisualRecSampler.signature(
                    of: frame, region: teaching.region) else { continue }
                _ = teaching.reading(of: signature)
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
            print("visual REC pass, \(label): "
                  + String(format: "%.3f ms", elapsed / 1e6 / Double(passes)))
        }
    }
}
