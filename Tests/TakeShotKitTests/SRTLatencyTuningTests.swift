import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **The delivery buffer is measured, not asked for** (owner: "пусть это не на
/// пользователе будет а автоматом считается").
///
/// SRT recovers a lost packet by asking for it again, so the buffer has to hold
/// the picture for several round trips. That number is not something an
/// operator on set can know about a network they did not build — but it is
/// something the link itself reports, and `SRTLatency` is the arithmetic
/// between the two. What is pinned here is the wiring: that a measurement
/// actually reaches the socket, which is the half this feature was missing for
/// a while — the arithmetic existed, was tested, and nothing called it.
@Suite(.enabled(if: SRTVideoEncoder.isSupported,
                "no H.264 encoder on this machine"))
struct SRTLatencyTuningTests {
    /// A link with no measurement yet opens on the floor, and one that reports
    /// a long round trip is re-opened on a buffer sized for it.
    @Test func aLinkThatMeasuresLongIsReopenedOnABiggerBuffer() async throws {
        let stream = FakeSRTStream()
        let log = SRTEventLog()
        let opened = SRTOpenedLatencies()
        let encoder = LiveVideoEncoder(bitsPerSecond: 4_000_000)
        let mirror = SRTMirror(
            endpoint: SRTFixtures.autoEndpoint, encoder: encoder,
            factory: { endpoint in
                opened.record(endpoint.latencyMs)
                return stream
            },
            onEvent: { log.record($0) })
        let rig = SRTRig(encoder: encoder, log: log, mirror: mirror)
        defer { rig.stop() }
        rig.start()
        #expect(opened.all == [SRTLatency.floorMs],
                "the first open did not use the floor: \(opened.all)")

        // The far end turns out to be 300 ms away — four round trips is 1200,
        // which is ten times the buffer the link is running with.
        stream.roundTripMs = 300
        let buffer = try SRTFixtures.displayBuffer()
        let deadline = Date().addingTimeInterval(20)
        while opened.all.count < 2, Date() < deadline {
            rig.offer(buffer, framesPerSecond: 60)
            try await Task.sleep(for: .milliseconds(4))
        }
        #expect(opened.all.count >= 2, """
            the link kept a 120 ms buffer on a 300 ms round trip — a measured \
            figure never reached the socket
            """)
        #expect(opened.all.last == SRTLatency.recommended(forRTT: 300))
    }

    /// A latency the operator PASTED is left alone. It is not their guess: it
    /// comes from a `srt://…?latency=` address, which is the receiving end
    /// stating what it wants, and both ends have to agree on the buffer.
    @Test func aStatedLatencyIsNeverOverwritten() async throws {
        let stream = FakeSRTStream()
        let log = SRTEventLog()
        let opened = SRTOpenedLatencies()
        let encoder = LiveVideoEncoder(bitsPerSecond: 4_000_000)
        var stated = SRTFixtures.autoEndpoint
        stated.latencyMs = 200
        stated.latencyIsExplicit = true
        let mirror = SRTMirror(
            endpoint: stated, encoder: encoder,
            factory: { endpoint in
                opened.record(endpoint.latencyMs)
                return stream
            },
            onEvent: { log.record($0) })
        let rig = SRTRig(encoder: encoder, log: log, mirror: mirror)
        defer { rig.stop() }
        rig.start()
        stream.roundTripMs = 300  // would ask for 1200 if it were allowed to

        let buffer = try SRTFixtures.displayBuffer()
        for _ in 0..<(SRTMirror.roundTripProbeFrames * 2) {
            rig.offer(buffer, framesPerSecond: 60)
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(opened.all.allSatisfy { $0 == 200 },
                "the pasted address's latency was overwritten: \(opened.all)")
    }

    /// The settings row is told what the link is running on, which is what makes
    /// **A build that cannot measure says so, instead of promising a number.**
    ///
    /// libsrt's statistics call is `srt_bstats` and older runtimes do not
    /// export it. The bridge has always known (`CSRTSender.isRoundTripAvailable`)
    /// and nothing asked, so the Settings row read "measuring the link…" from
    /// call time to wrap — over the one number an operator opens that row to
    /// find, on the day the picture is breaking up and the buffer is the thing
    /// to change.
    @Test func aLinkThatCannotBeMeasuredIsNotStillMeasuring() async throws {
        let stream = FakeSRTStream()
        stream.canMeasureRoundTrip = false
        let log = SRTEventLog()
        let seen = SRTMeasurementLog()
        let encoder = LiveVideoEncoder(bitsPerSecond: 4_000_000)
        let mirror = SRTMirror(
            endpoint: SRTFixtures.autoEndpoint, encoder: encoder,
            factory: { _ in stream }, onEvent: { log.record($0) },
            onMeasurement: { seen.record($0) })
        let rig = SRTRig(encoder: encoder, log: log, mirror: mirror)
        defer { rig.stop() }
        rig.start()
        let timing = try #require(seen.all.first)
        #expect(timing.roundTripMs == nil)
        #expect(!timing.canMeasure,
                "a link with no statistics call claimed it was still measuring")
    }

    /// …and a link that CAN says so, which is what makes the assertion above a
    /// distinction rather than a constant.
    @Test func aLinkThatCanBeMeasuredSaysSoBeforeItHas() async throws {
        let stream = FakeSRTStream()
        let log = SRTEventLog()
        let seen = SRTMeasurementLog()
        let encoder = LiveVideoEncoder(bitsPerSecond: 4_000_000)
        let mirror = SRTMirror(
            endpoint: SRTFixtures.autoEndpoint, encoder: encoder,
            factory: { _ in stream }, onEvent: { log.record($0) },
            onMeasurement: { seen.record($0) })
        let rig = SRTRig(encoder: encoder, log: log, mirror: mirror)
        defer { rig.stop() }
        rig.start()
        let timing = try #require(seen.all.first)
        #expect(timing.roundTripMs == nil)
        #expect(timing.canMeasure)
    }

    /// …and the row says the fourth sentence, which is the point of carrying
    /// the fact at all.
    @MainActor
    @Test func theRowSaysWhatTheBuildCannotDo() {
        let mirrors = DisplayMirrors()
        var srt = SRTSettings()
        srt.latencyMs = nil
        mirrors.srtLatencyMs = 260
        mirrors.srtRoundTripMs = nil

        mirrors.srtCanMeasureRoundTrip = true
        let measuring = SRTSettingsSection.latencyText(mirrors: mirrors,
                                                       srt: srt)
        mirrors.srtCanMeasureRoundTrip = false
        let never = SRTSettingsSection.latencyText(mirrors: mirrors, srt: srt)
        #expect(measuring == L("srt_latency_measuring", 260))
        #expect(never == L("srt_latency_unmeasurable", 260), """
            a build that can never measure said \(never)
            """)

        // …and the two sentences an actual measurement produces are still the
        // ones they were, so this is a fourth case and not a replacement.
        mirrors.srtRoundTripMs = 40
        #expect(SRTSettingsSection.latencyText(mirrors: mirrors, srt: srt)
                == L("srt_latency_auto", 260, 40))
        srt.latencyMs = 300
        #expect(SRTSettingsSection.latencyText(mirrors: mirrors, srt: srt)
                == L("srt_latency_stated", 260))
    }

    /// an automatic number different from a hidden one.
    @Test func theMeasurementReachesTheSettingsRow() async throws {
        let stream = FakeSRTStream()
        let log = SRTEventLog()
        let seen = SRTMeasurementLog()
        let encoder = LiveVideoEncoder(bitsPerSecond: 4_000_000)
        let mirror = SRTMirror(
            endpoint: SRTFixtures.autoEndpoint, encoder: encoder,
            factory: { _ in stream }, onEvent: { log.record($0) },
            onMeasurement: { seen.record($0) })
        let rig = SRTRig(encoder: encoder, log: log, mirror: mirror)
        defer { rig.stop() }
        rig.start()
        #expect(seen.all.first?.bufferMs == SRTLatency.floorMs)
        #expect(seen.all.first?.roundTripMs == nil,
                "a round trip was reported before anything was measured")

        stream.roundTripMs = 40
        let buffer = try SRTFixtures.displayBuffer()
        let deadline = Date().addingTimeInterval(20)
        while seen.all.last?.roundTripMs == nil, Date() < deadline {
            rig.offer(buffer, framesPerSecond: 60)
            try await Task.sleep(for: .milliseconds(4))
        }
        #expect(seen.all.last?.roundTripMs == 40,
                "the row was never told what the link measured")
        // 40 ms wants 160, so this link does get re-opened once — and then it
        // SETTLES: at the buffer it asked for, the same measurement no longer
        // asks for another. That is the property that keeps a link from
        // re-opening every probe on a network that has not changed.
        let settled = SRTLatency.recommended(forRTT: 40)
        #expect(SRTLatency.wantsReconnect(current: SRTLatency.floorMs, forRTT: 40))
        #expect(!SRTLatency.wantsReconnect(current: settled, forRTT: 40),
                "a link at its own recommended buffer asked to be re-opened")
    }
}

/// The latency each `open` was handed. Written on the mirror's queue.
final class SRTOpenedLatencies: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []
    func record(_ latency: Int) { lock.withLock { stored.append(latency) } }
    var all: [Int] { lock.withLock { stored } }
}

/// Every measurement handed to the settings row, in order.
final class SRTMeasurementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LinkTiming] = []
    func record(_ timing: LinkTiming) { lock.withLock { stored.append(timing) } }
    var all: [LinkTiming] { lock.withLock { stored } }
}
