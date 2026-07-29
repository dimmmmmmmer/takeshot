import CaptureCore
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import TakeShotKit

// MARK: - fixtures

/// A capture backend that does nothing but record what it was asked to do.
final class StubBackend: CaptureBackend, @unchecked Sendable {
    weak var delegate: CaptureBackendDelegate?
    var isAvailable: Bool
    var embeddedAudioChannels: Int
    var deviceList: [CaptureDeviceInfo]
    /// Set to make `startCapture` fail the way a board held by another app does.
    var startError: Error?

    private(set) var startedDeviceIDs: [String] = []
    private(set) var stopCount = 0

    init(devices: [CaptureDeviceInfo], audioChannels: Int = 0,
         available: Bool = true) {
        self.deviceList = devices
        self.embeddedAudioChannels = audioChannels
        self.isAvailable = available
    }

    func devices() -> [CaptureDeviceInfo] { deviceList }

    func startCapture(deviceID: String) throws {
        if let startError { throw startError }
        startedDeviceIDs.append(deviceID)
    }

    func stopCapture() { stopCount += 1 }
}

/// Thread-safe delegate: the mock source calls back from its own queue.
final class RecordingBackendDelegate: CaptureBackendDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var state = State()

    struct State {
        var formats: [CaptureFormat] = []
        var frames: [CapturedFrame] = []
        var audioChannelCounts: [Int] = []
        var audioPackets = 0
        var signals: [Bool] = []
        var deviceListChanges = 0
        var backends: [ObjectIdentifier] = []
    }

    var snapshot: State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    private func mutate(_ body: (inout State) -> Void) {
        lock.lock()
        body(&state)
        lock.unlock()
    }

    func backend(_ backend: CaptureBackend, didDetectFormat format: CaptureFormat) {
        mutate {
            $0.formats.append(format)
            $0.backends.append(ObjectIdentifier(backend))
        }
    }

    func backend(_ backend: CaptureBackend, didReceive frame: CapturedFrame) {
        mutate {
            $0.frames.append(frame)
            $0.backends.append(ObjectIdentifier(backend))
        }
    }

    func backend(_ backend: CaptureBackend, didReceiveAudio sampleBuffer: CMSampleBuffer) {
        let channels = CMSampleBufferGetFormatDescription(sampleBuffer)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) }
            .map { Int($0.pointee.mChannelsPerFrame) } ?? 0
        mutate {
            $0.audioPackets += 1
            $0.audioChannelCounts.append(channels)
            $0.backends.append(ObjectIdentifier(backend))
        }
    }

    func backend(_ backend: CaptureBackend, signalPresent: Bool) {
        mutate {
            $0.signals.append(signalPresent)
            $0.backends.append(ObjectIdentifier(backend))
        }
    }

    func backendDeviceListChanged(_ backend: CaptureBackend) {
        mutate {
            $0.deviceListChanges += 1
            $0.backends.append(ObjectIdentifier(backend))
        }
    }
}

// MARK: - AggregateBackend

/// The aggregate is what the device picker actually talks to. Its device IDs are
/// prefixed strings that get persisted in settings and handed back on the next
/// launch, so the split has to be exact — and a device that no longer exists has
/// to fail loudly: returning silently once left the UI showing "capturing" over
/// a dead input for a whole setup.
struct ModelAggregateBackendTests {
    private struct Rig {
        let aggregate: AggregateBackend
        let deck: StubBackend
        let demo: StubBackend
    }

    private func makeAggregate() -> Rig {
        let deck = StubBackend(devices: [CaptureDeviceInfo(id: "1234", name: "UltraStudio")],
                               audioChannels: 16)
        let demo = StubBackend(devices: [CaptureDeviceInfo(id: "mock-source", name: "Demo")],
                               audioChannels: 2)
        return Rig(aggregate: AggregateBackend(children: [("deck", deck),
                                                          ("demo", demo)]),
                   deck: deck, demo: demo)
    }

    @Test func deviceIDsCarryTheirBackendPrefix() {
        let aggregate = makeAggregate().aggregate
        let devices = aggregate.devices()
        #expect(devices.map(\.id) == ["deck:1234", "demo:mock-source"])
        #expect(devices.map(\.name) == ["UltraStudio", "Demo"])
    }

    @Test func startRoutesToTheNamedChildWithTheUnprefixedID() throws {
        let rig = makeAggregate()
        let (aggregate, deck, demo) = (rig.aggregate, rig.deck, rig.demo)
        try aggregate.startCapture(deviceID: "deck:1234")
        #expect(deck.startedDeviceIDs == ["1234"])
        #expect(demo.startedDeviceIDs.isEmpty)
    }

    /// Board IDs are opaque strings; only the FIRST colon separates the prefix,
    /// so a device whose own ID contains one still resolves.
    @Test func onlyTheFirstColonSeparatesThePrefix() throws {
        let rig = makeAggregate()
        let (aggregate, deck) = (rig.aggregate, rig.deck)
        try aggregate.startCapture(deviceID: "deck:00:11:22")
        #expect(deck.startedDeviceIDs == ["00:11:22"])
    }

    /// A device ID saved by an older build, or a board that has been unplugged,
    /// must throw rather than leave the app pretending to capture.
    @Test func anUnknownDeviceThrows() {
        let aggregate = makeAggregate().aggregate
        #expect(throws: AggregateBackend.AggregateError.self) {
            try aggregate.startCapture(deviceID: "aja:9999")
        }
        #expect(throws: AggregateBackend.AggregateError.self) {
            try aggregate.startCapture(deviceID: "no-prefix-at-all")
        }
        #expect(throws: AggregateBackend.AggregateError.self) {
            try aggregate.startCapture(deviceID: "")
        }
    }

    @Test func theErrorNamesTheDeviceItCouldNotFind() {
        let aggregate = makeAggregate().aggregate
        do {
            try aggregate.startCapture(deviceID: "aja:9999")
            Issue.record("expected a throw")
        } catch {
            #expect(error.localizedDescription.contains("aja:9999"))
        }
    }

    /// The writer needs the channel count before the first audio packet, and it
    /// must come from the source that is actually running.
    @Test func audioChannelCountFollowsTheRunningSource() throws {
        let aggregate = makeAggregate().aggregate
        #expect(aggregate.embeddedAudioChannels == 0, "nothing is running yet")
        try aggregate.startCapture(deviceID: "deck:1234")
        #expect(aggregate.embeddedAudioChannels == 16)
        try aggregate.startCapture(deviceID: "demo:mock-source")
        #expect(aggregate.embeddedAudioChannels == 2)
        aggregate.stopCapture()
        #expect(aggregate.embeddedAudioChannels == 0)
    }

    /// Switching sources must stop the old one — two boards streaming into one
    /// pipeline interleaves two signals into the same take.
    @Test func switchingSourceStopsThePreviousOne() throws {
        let rig = makeAggregate()
        let (aggregate, deck, demo) = (rig.aggregate, rig.deck, rig.demo)
        try aggregate.startCapture(deviceID: "deck:1234")
        try aggregate.startCapture(deviceID: "demo:mock-source")
        #expect(deck.stopCount >= 1)
        aggregate.stopCapture()
        #expect(demo.stopCount >= 1)
    }

    /// A failed start must not leave the aggregate believing a source is live.
    @Test func aChildThatFailsToStartLeavesNothingActive() {
        let rig = makeAggregate()
        let (aggregate, deck) = (rig.aggregate, rig.deck)
        struct Busy: Error {}
        deck.startError = Busy()
        #expect(throws: Busy.self) {
            try aggregate.startCapture(deviceID: "deck:1234")
        }
        #expect(aggregate.embeddedAudioChannels == 0)
    }

    /// Callbacks are re-labelled with the aggregate: the controller compares the
    /// reported backend against the one it started.
    @Test func callbacksAreForwardedAsTheAggregateItself() {
        let rig = makeAggregate()
        let (aggregate, deck) = (rig.aggregate, rig.deck)
        let delegate = RecordingBackendDelegate()
        aggregate.delegate = delegate

        let format = CaptureFormat(width: 1920, height: 1080, frameRate: 25,
                                   timecodeFPS: 25, name: "1080p25")
        deck.delegate?.backend(deck, didDetectFormat: format)
        deck.delegate?.backend(deck, signalPresent: true)
        deck.delegate?.backendDeviceListChanged(deck)

        let state = delegate.snapshot
        #expect(state.formats == [format])
        #expect(state.signals == [true])
        #expect(state.deviceListChanges == 1)
        #expect(Set(state.backends) == [ObjectIdentifier(aggregate)],
                "a child leaked through as the reported backend")
    }

    @Test func availabilityIsTrueWhenAnyChildIsAvailable() {
        let unavailable = StubBackend(devices: [], available: false)
        let available = StubBackend(devices: [], available: true)
        #expect(!AggregateBackend(children: [("a", unavailable)]).isAvailable)
        #expect(AggregateBackend(children: [("a", unavailable),
                                            ("b", available)]).isAvailable)
    }

    /// The demo REC button reaches its backend through this lookup.
    @Test func childLookupFindsABackendByType() {
        let mock = MockCaptureBackend()
        let stub = StubBackend(devices: [])
        let aggregate = AggregateBackend(children: [("deck", stub), ("demo", mock)])
        #expect(aggregate.child(of: MockCaptureBackend.self) === mock)
        #expect(aggregate.child(of: DeckLinkBackendAdapter.self) == nil)
    }
}

// MARK: - MockCaptureBackend

/// The demo source is how the GUI and the take logic are exercised without a
/// board, so its signal has to keep matching what it claims: 1080p25, 16
/// embedded audio channels, and — the part that matters — a timecode that stands
/// STILL. The demo camera is in standby; a running TC here would make the
/// running-timecode detector open takes on its own, which is precisely the false
/// positive the VANC-only default exists to prevent.
struct ModelMockBackendTests {
    private func waitUntil(_ condition: () -> Bool,
                           timeout: Duration = .seconds(5)) async {
        let steps = Int(timeout / .milliseconds(20))
        for _ in 0..<steps where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForFrames(_ delegate: RecordingBackendDelegate,
                               atLeast count: Int) async {
        await waitUntil { delegate.snapshot.frames.count >= count }
    }

    @Test func advertisesExactlyOneDeviceUnderTheDemoID() {
        let devices = MockCaptureBackend().devices()
        #expect(devices.count == 1)
        #expect(devices[0].id == MockCaptureBackend.deviceID)
        #expect(!devices[0].name.isEmpty)
        #expect(devices[0].name != "mock_device_name", "device name is not localized")
    }

    @Test func announcesItsFormatAndSignalBeforeAnyFrame() throws {
        let backend = MockCaptureBackend()
        let delegate = RecordingBackendDelegate()
        backend.delegate = delegate
        defer { backend.stopCapture() }

        try backend.startCapture(deviceID: MockCaptureBackend.deviceID)
        let state = delegate.snapshot
        #expect(state.formats.count == 1)
        let format = try #require(state.formats.first)
        #expect(format.width == 1920 && format.height == 1080)
        #expect(format.frameRate == 25)
        #expect(format.timecodeFPS == 25)
        #expect(!format.isDropFrame)
        #expect(state.signals == [true])
    }

    /// Rec Run with the camera in standby: the timecode is frozen. If it ever
    /// advances, the timecode-run detector starts recording the demo signal by
    /// itself and the manual REC button stops being the only way in.
    @Test func theDemoTimecodeStandsStill() async throws {
        let backend = MockCaptureBackend()
        let delegate = RecordingBackendDelegate()
        backend.delegate = delegate
        defer { backend.stopCapture() }

        try backend.startCapture(deviceID: MockCaptureBackend.deviceID)
        await waitForFrames(delegate, atLeast: 5)
        let frames = delegate.snapshot.frames
        #expect(frames.count >= 5, "the demo source produced no signal")

        let timecodes = Set(frames.compactMap { $0.timecode })
        #expect(timecodes.count == 1, "the demo timecode moved: \(timecodes)")
        #expect(timecodes.first == Timecode(hours: 10, minutes: 0, seconds: 0,
                                            frames: 0, fps: 25))
        // …and it carries no VANC trigger either, so nothing else can start a take
        #expect(frames.allSatisfy { $0.vancTrigger == nil })
    }

    /// The presentation timestamps have to advance monotonically at the declared
    /// rate; a writer fed non-increasing PTS drops the take.
    @Test func framesArriveWithStrictlyIncreasingTimestamps() async throws {
        let backend = MockCaptureBackend()
        let delegate = RecordingBackendDelegate()
        backend.delegate = delegate
        defer { backend.stopCapture() }

        try backend.startCapture(deviceID: MockCaptureBackend.deviceID)
        await waitForFrames(delegate, atLeast: 5)
        // milliseconds, so the step check is exact integer arithmetic and a
        // frame the buffer pool could not serve shows as a multiple, not a fail
        let stamps = delegate.snapshot.frames.map {
            CMTimeConvertScale($0.pts, timescale: 1000, method: .default).value
        }
        #expect(stamps.count >= 5)
        for (previous, next) in zip(stamps, stamps.dropFirst()) {
            #expect(next > previous, "PTS went backwards: \(previous) → \(next)")
            #expect((next - previous) % 40 == 0, "not a 25 fps step: \(next - previous)")
        }
        let buffer = try #require(delegate.snapshot.frames.first?.pixelBuffer)
        #expect(CVPixelBufferGetWidth(buffer) == 1920)
        #expect(CVPixelBufferGetHeight(buffer) == 1080)
    }

    /// The count the writer's audio track is built from must match what the
    /// packets actually carry, or the take gets a track of the wrong width.
    @Test func embeddedAudioMatchesTheAdvertisedChannelCount() async throws {
        let backend = MockCaptureBackend()
        let delegate = RecordingBackendDelegate()
        backend.delegate = delegate
        defer { backend.stopCapture() }

        #expect(backend.embeddedAudioChannels == MockCaptureBackend.audioChannels)
        try backend.startCapture(deviceID: MockCaptureBackend.deviceID)
        await waitUntil { delegate.snapshot.audioPackets >= 3 }
        let state = delegate.snapshot
        #expect(state.audioPackets >= 3, "the demo source produced no audio")
        #expect(Set(state.audioChannelCounts) == [backend.embeddedAudioChannels])
    }

    /// Stopping has to actually stop: a timer left running after the device is
    /// released keeps pushing frames into a torn-down pipeline.
    @Test func stopEndsTheSignal() async throws {
        let backend = MockCaptureBackend()
        let delegate = RecordingBackendDelegate()
        backend.delegate = delegate

        try backend.startCapture(deviceID: MockCaptureBackend.deviceID)
        await waitForFrames(delegate, atLeast: 3)
        backend.stopCapture()

        // let anything already in flight land, then take the reading
        try await Task.sleep(for: .milliseconds(250))
        let settled = delegate.snapshot.frames.count
        try await Task.sleep(for: .milliseconds(400))
        #expect(delegate.snapshot.frames.count == settled,
                "frames kept arriving after stopCapture()")
    }

    @Test func stopIsSafeBeforeAnyStart() {
        let backend = MockCaptureBackend()
        backend.stopCapture()
        backend.stopCapture()
        #expect(backend.devices().count == 1)
    }
}
