import CaptureCore
import CoreMedia
import Foundation
import Testing

@testable import TakeShotKit

/// The live audio monitor's timing, backlog and routing.
///
/// Never a real output: `AudioRenderRoute` stands in for the renderer and its
/// timeline, so the two things that used to be audible bugs — a dropped packet
/// splicing 40 ms of silence into the tone, and a drain request left armed on an
/// idle monitor pinning a core — are assertable without a speaker. The fake also
/// owns the clock, so the resync window is driven exactly rather than waited for.
@Suite struct MediaAudioMonitorTests {
    /// 40 ms of silence stamped at `seconds`. Silence, not a tone: nothing here
    /// reaches an output, but a fixture that would be audible if it ever did is
    /// a trap for the next person.
    private static func packet(
        at seconds: Double,
        cache: inout CMAudioFormatDescription?) -> CMSampleBuffer {
        let channels = 2
        let sampleFrames = 1920
        let samples = [Int16](repeating: 0, count: sampleFrames * channels)
        let buffer = samples.withUnsafeBytes { raw -> CMSampleBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return PCMAudio.makeSampleBuffer(
                bytes: base, sampleFrames: sampleFrames,
                channelCount: channels, ptsSeconds: seconds,
                formatCache: &cache)
        }
        // A fixture that could not be built is a broken test, not a finding.
        guard let buffer else {
            fatalError("could not build an audio packet at \(seconds)s")
        }
        return buffer
    }

    /// Feed `monitor` a run of packets 40 ms apart starting at `from`.
    private static func feed(_ monitor: AudioMonitor, count: Int,
                             from: Double = 0, step: Double = 0.04) {
        var cache: CMAudioFormatDescription?
        for index in 0..<count {
            monitor.enqueue(packet(at: from + Double(index) * step,
                                   cache: &cache))
        }
        monitor.settle()
    }

    /// The first packet establishes the offset, and it puts that packet 60 ms
    /// ahead of the timeline's zero — the lead that absorbs jitter. The clock is
    /// started at the same moment, once.
    @Test func theFirstPacketStartsTheClockSixtyMillisecondsAhead() {
        let route = FakeAudioRoute()
        let monitor = AudioMonitor(route: route)
        var cache: CMAudioFormatDescription?
        // a board's own PTS base is nowhere near zero; the offset is what
        // absorbs that, so the fixture starts somewhere arbitrary
        monitor.enqueue(Self.packet(at: 4242.5, cache: &cache))
        monitor.settle()

        #expect(route.rates == [.init(rate: 1, time: .zero)])
        #expect(route.enqueued.count == 1)
        let first = route.enqueued.first?.seconds ?? -1
        #expect(abs(first - 0.06) < 0.0005,
                "the first packet landed at \(first)s, not on the 60 ms lead")
    }

    /// The offset is CONSTANT across the run: source PTS continuity has to come
    /// out as timeline continuity, or the tone gets a seam at every packet.
    @Test func aContinuousSourceComesOutGapless() {
        let route = FakeAudioRoute()
        let monitor = AudioMonitor(route: route)
        Self.feed(monitor, count: 5, from: 100)

        let landed = route.enqueued.map(\.seconds)
        #expect(landed.count == 5)
        let expected = (0..<5).map { 0.06 + Double($0) * 0.04 }
        for (got, want) in zip(landed, expected) {
            #expect(abs(got - want) < 0.0005,
                    "packet landed at \(got)s, expected \(want)s")
        }
        // the clock is started once, not per packet
        #expect(route.rates.count == 1)
    }

    /// A source PTS that jumps forward past the tolerance window (a device
    /// restart) resyncs: the renderer is flushed and the next packet becomes the
    /// new reference at the same 60 ms lead.
    @Test func aForwardPTSJumpResyncs() {
        let route = FakeAudioRoute()
        let monitor = AudioMonitor(route: route)
        var cache: CMAudioFormatDescription?
        monitor.enqueue(Self.packet(at: 0, cache: &cache))
        monitor.settle()
        #expect(route.flushes == 0)

        // adjusted time would be 5.06s against a clock still at zero
        monitor.enqueue(Self.packet(at: 5, cache: &cache))
        monitor.settle()

        #expect(route.flushes == 1)
        #expect(route.rates.count == 2, "the clock was not restarted")
        let resynced = route.enqueued.last?.seconds ?? -1
        #expect(abs(resynced - 0.06) < 0.0005,
                "the resynced packet landed at \(resynced)s, not on the lead")
    }

    /// A jump BACKWARDS relative to the clock resyncs too, and the window is
    /// asymmetric on purpose: 50 ms behind the clock is already too late to
    /// play, while a second ahead is still just latency.
    @Test func aPacketBehindTheClockResyncs() {
        let route = FakeAudioRoute()
        let monitor = AudioMonitor(route: route)
        var cache: CMAudioFormatDescription?
        monitor.enqueue(Self.packet(at: 0, cache: &cache))
        monitor.settle()

        // the clock has run on; the next packet's adjusted time is far behind it
        route.clock = CMTime(seconds: 10, preferredTimescale: 600)
        monitor.enqueue(Self.packet(at: 0.04, cache: &cache))
        monitor.settle()

        #expect(route.flushes == 1)
    }

    /// Inside the window nothing is flushed. Jitter is normal — a monitor that
    /// resynced on it would flush continuously and never play anything.
    @Test func driftInsideTheWindowIsLeftAlone() {
        let route = FakeAudioRoute()
        let monitor = AudioMonitor(route: route)
        var cache: CMAudioFormatDescription?
        monitor.enqueue(Self.packet(at: 0, cache: &cache))
        monitor.settle()

        // 0.5 s ahead of the clock: inside the 1 s ceiling
        monitor.enqueue(Self.packet(at: 0.5, cache: &cache))
        // Settled before the clock moves: `enqueue` is async onto the monitor's
        // queue, so a clock written from here without it would be read by
        // whichever packet got there first.
        monitor.settle()
        // and 20 ms behind it: inside the 50 ms floor
        route.clock = CMTime(seconds: 0.6, preferredTimescale: 600)
        monitor.enqueue(Self.packet(at: 0.52, cache: &cache))
        monitor.settle()

        #expect(route.flushes == 0)
        #expect(route.enqueued.count == 3)
    }

    /// A stalled output does not lose packets — it backs them up. Every packet
    /// dropped here is 40 ms of silence spliced into the tone, which is audible
    /// as steady crackle and is what this queue exists to stop.
    @Test func aStalledOutputBacksPacketsUpInsteadOfDroppingThem() {
        let route = FakeAudioRoute()
        route.accepting = false
        let monitor = AudioMonitor(route: route)
        Self.feed(monitor, count: 6)

        #expect(route.enqueued.isEmpty, "the stalled renderer took packets")

        route.accepting = true
        route.deliverRequest()

        #expect(route.enqueued.count == 6, "the backlog did not drain")
        let landed = route.enqueued.map(\.seconds)
        for (index, got) in landed.enumerated() {
            let want = 0.06 + Double(index) * 0.04
            #expect(abs(got - want) < 0.0005,
                    "backlog packet \(index) landed at \(got)s, expected \(want)s")
        }
    }

    /// Beyond half a second of backlog the output is stalled rather than
    /// jittery, and the OLDEST packets go: they are the ones the room has
    /// already moved past.
    @Test func theBacklogIsCappedAndKeepsTheNewestPackets() {
        let route = FakeAudioRoute()
        route.accepting = false
        let monitor = AudioMonitor(route: route)
        let sent = 20
        Self.feed(monitor, count: sent)

        route.accepting = true
        route.deliverRequest()

        #expect(route.enqueued.count == AudioMonitor.pendingLimit)
        // the survivors are the tail of the run, not its head
        let firstKept = sent - AudioMonitor.pendingLimit
        let want = 0.06 + Double(firstKept) * 0.04
        let kept = route.enqueued.first?.seconds ?? -1
        #expect(abs(kept - want) < 0.0005,
                "the backlog starts at \(kept)s, expected \(want)s — it kept the oldest")
    }

    /// The drain request exists only while there is a backlog.
    /// `requestMediaDataWhenReady` fires its block again and again for as long as
    /// the renderer is ready, so one left installed on an idle monitor is a busy
    /// loop pinning a core per instance.
    @Test func theDrainRequestIsArmedOnlyWhileABacklogExists() {
        let route = FakeAudioRoute()
        let monitor = AudioMonitor(route: route)

        // a renderer that takes everything never needs a request at all
        Self.feed(monitor, count: 4)
        #expect(route.arms == 0, "an accepting renderer was asked for more data")
        #expect(!route.isRequestArmed)

        // it stalls: one request is armed, and only one however many packets pile up
        route.accepting = false
        Self.feed(monitor, count: 5, from: 1)
        #expect(route.arms == 1)
        #expect(route.isRequestArmed)

        // and it comes down the moment the backlog empties
        route.accepting = true
        route.deliverRequest()
        #expect(route.disarms == 1)
        #expect(!route.isRequestArmed, "the drain request outlived the backlog")
    }

    /// Naming an output device routes to it and keeps the renderer — the
    /// timeline the packets were placed on is still the right one, so nothing
    /// resyncs.
    @Test func namingADeviceKeepsTheTimeline() {
        let route = FakeAudioRoute()
        let monitor = AudioMonitor(route: route)
        Self.feed(monitor, count: 2)
        let ratesBefore = route.rates.count

        monitor.outputDeviceUID = "AppleHDAEngineOutput:1"
        monitor.settle()

        #expect(route.routes == ["AppleHDAEngineOutput:1"])
        #expect(route.rendererReplacements == 0)
        Self.feed(monitor, count: 1, from: 0.08)
        #expect(route.rates.count == ratesBefore,
                "naming a device restarted the clock")
    }

    /// The UID reads back straight away, before the queue has done the renderer
    /// work. A settings panel asking right after a device change used to be told
    /// the PREVIOUS device.
    @Test func theChosenDeviceReadsBackImmediately() {
        let route = FakeAudioRoute()
        let monitor = AudioMonitor(route: route)
        monitor.outputDeviceUID = "Scarlett-2i2"
        #expect(monitor.outputDeviceUID == "Scarlett-2i2")
        monitor.settle()
    }

    /// Choosing the device that is already selected does nothing. The picker
    /// re-assigns on every settings read-back, and a swap on each one would tear
    /// the output down mid-tone.
    @Test func reselectingTheSameDeviceIsANoOp() {
        let route = FakeAudioRoute()
        let monitor = AudioMonitor(route: route)
        monitor.outputDeviceUID = "Scarlett-2i2"
        monitor.outputDeviceUID = "Scarlett-2i2"
        monitor.settle()
        #expect(route.routes.count == 1)
    }

    /// Back to the system default is a renderer REPLACEMENT, so everything the
    /// monitor knew about the old timeline goes with it: the offset, and the
    /// packets queued for a renderer that no longer exists.
    @Test func returningToTheSystemDefaultStartsOver() {
        let route = FakeAudioRoute()
        route.accepting = false
        let monitor = AudioMonitor(route: route)
        monitor.outputDeviceUID = "Scarlett-2i2"
        Self.feed(monitor, count: 3)
        #expect(route.isRequestArmed)

        monitor.outputDeviceUID = nil
        monitor.settle()

        #expect(route.rendererReplacements == 1)
        #expect(!route.isRequestArmed,
                "the drain request outlived the renderer it was armed on")

        // the backlog went with the old renderer, and the next packet is a
        // fresh reference rather than a continuation of a dead timeline
        route.accepting = true
        route.deliverRequest()
        #expect(route.enqueued.isEmpty, "packets queued for the old renderer played")
        Self.feed(monitor, count: 1, from: 900)
        #expect(abs((route.enqueued.first?.seconds ?? 0) - 0.06) < 0.0005)
    }

    /// Stopping halts the clock, throws away what was queued, and takes the
    /// drain request down with it.
    @Test func stoppingClearsEverything() {
        let route = FakeAudioRoute()
        route.accepting = false
        let monitor = AudioMonitor(route: route)
        Self.feed(monitor, count: 4)
        #expect(route.isRequestArmed)

        monitor.stop()
        monitor.settle()

        #expect(route.rates.last == .init(rate: 0, time: .zero))
        #expect(route.flushes == 1)
        #expect(!route.isRequestArmed)

        // nothing was left to play, and the next packet is a fresh reference
        route.accepting = true
        #expect(route.enqueued.isEmpty)
        Self.feed(monitor, count: 1, from: 7)
        #expect(abs((route.enqueued.first?.seconds ?? 0) - 0.06) < 0.0005)
    }

    /// The level reads back on the caller's thread and reaches the route on the
    /// monitor's queue — the split that stopped a slider callback racing a
    /// device swap.
    @Test func theLevelIsReadableAtOnceAndReachesTheRoute() {
        let route = FakeAudioRoute()
        let monitor = AudioMonitor(route: route)
        #expect(monitor.volume == 1)

        monitor.volume = 0.25
        #expect(monitor.volume == 0.25)
        monitor.settle()
        #expect(route.volume == 0.25)
    }

    /// The real route, on the one path that touches no device: going back to the
    /// system default replaces the renderer, and the operator's level has to
    /// survive it. A fresh renderer starts at 1.0, and a monitor that had been
    /// pulled down jumping back to full is the failure this carries against.
    ///
    /// Nothing is enqueued and no rate is set, so no output is ever opened — the
    /// two objects here are the same pair every controller in this suite already
    /// builds.
    @Test func theRealRouteCarriesTheLevelAcrossARendererSwap() {
        let route = SystemAudioRoute()
        route.volume = 0.3
        #expect(route.route(to: nil), "the renderer was not replaced")
        #expect(abs(route.volume - 0.3) < 0.0001,
                "the level came back as \(route.volume) after the swap")
    }
}
