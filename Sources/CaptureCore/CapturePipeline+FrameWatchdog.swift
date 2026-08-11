import Foundation
import os.log

/// The frame-arrival watchdog: what closes a take when the input stops
/// delivering and never says so.
///
/// Every other way a take loses its input arrives as an EVENT — `handleSignal`
/// for a cable, `handleFormat` for a camera changing raster, the writer's own
/// failure for a volume going away. This one is the ABSENCE of events. A wedged
/// board stays in the device list, reports no signal loss and no format change,
/// and simply stops calling back: the take stays open, REC stays red, nothing
/// reaches the file, and the operator's only evidence is a timecode display that
/// has stopped moving. Nothing but a clock can notice that.
///
/// It is the picture counterpart of the external audio path's starvation
/// watchdog (`externalStarvationThreshold`), and it answers in the register that
/// path's rules ask for: the take is closed where it stands, the alarm is sticky,
/// and the detector is reset so what comes back opens a fresh take rather than
/// being swallowed into this one.
extension CapturePipeline {
    /// How long a rolling take may go without a frame before the pipeline stops
    /// believing the input.
    ///
    /// The number is read as FRAMES, which is what a signal is made of: one
    /// second is 24 consecutive frames missing at the slowest rate the app
    /// supports (23.976) and 60 at the fastest. A dropped frame is routine — the
    /// encoder refuses one at the head of nearly every take, which is why the
    /// drop alarm waits for five — and a handful in a row is a rig having a bad
    /// moment, but no signal skips a whole second while the board is still locked
    /// to it. So a second is the shortest budget that cannot be reached by a
    /// hiccup, and the longest that is worth waiting: past it the operator is
    /// filming nothing.
    ///
    /// It is deliberately longer than the audio side's 0.5 s rather than equal to
    /// it. Silence is padded and the take survives, so that watchdog may guess
    /// early and cheaply; this one CLOSES a take, and the one thing worse than
    /// noticing a wedge late is ending a good take on a stutter.
    static let frameStarvationThreshold = 1.0

    /// How often the clock is read: four times inside the budget, so a wedge
    /// costs between 1.0 and 1.25 s. The cost is four wakeups a second on the
    /// capture queue while a take rolls, and nothing at all while none does —
    /// the timer only exists between `beginTake` and `finishTake`.
    static let frameWatchdogInterval = 0.25

    /// Arm the watchdog for a take that has just opened, and give it a baseline.
    ///
    /// Seeded from the take's start rather than from the last frame seen, so a
    /// take opened by the button on a signal that was ALREADY wedged is closed
    /// one budget later instead of immediately — the operator gets one alarm that
    /// names the input, not a REC press that appears to do nothing.
    func startFrameWatchdog() {
        stopFrameWatchdog()
        noteFrameArrival()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.frameWatchdogInterval,
                       repeating: Self.frameWatchdogInterval)
        timer.setEventHandler { [weak self] in self?.checkFrameArrival() }
        frameWatchdog = timer
        timer.resume()
    }

    /// Disarm it. Called from `finishTake` however the take ended, including
    /// from the watchdog's own handler — cancelling a timer source from inside
    /// its event handler is allowed, and it is what stops a second alarm.
    func stopFrameWatchdog() {
        frameWatchdog?.cancel()
        frameWatchdog = nil
    }

    /// The board delivered a frame. Stamped at the door (see
    /// `admitFrameAtIngress`) rather than on the capture queue, so what is
    /// measured is the INPUT and not this pipeline's own queue depth: a frame
    /// turned away by the in-flight window is still evidence the board is alive,
    /// and a bounded stall of ours must never read as a dead camera.
    func noteFrameArrival() {
        inFlightLock.lock()
        lastFrameArrival = DispatchTime.now().uptimeNanoseconds
        inFlightLock.unlock()
    }

    // MARK: - on queue

    /// One tick. Runs on the capture queue, so `writer` is read where it lives —
    /// which is also why a wedged capture queue makes this late rather than
    /// wrong: it is the frame path's own queue, and if that is stuck the take is
    /// closed as soon as it moves again.
    private func checkFrameArrival() {
        guard writer != nil else { return } // idle, or between takes
        let quiet = secondsSinceLastFrame()
        guard quiet > Self.frameStarvationThreshold else { return }
        os_log("frame watchdog: no frames for %.2f s — closing the take",
               log: Self.levelsLog, type: .default, quiet)
        closeTakeOnLostInput(.takeClosedFramesStopped)
    }

    private func secondsSinceLastFrame() -> Double {
        inFlightLock.lock()
        let stamp = lastFrameArrival
        inFlightLock.unlock()
        let now = DispatchTime.now().uptimeNanoseconds
        guard now > stamp else { return 0 }
        return Double(now - stamp) / 1_000_000_000
    }
}
