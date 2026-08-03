import CoreMedia
import CoreVideo
import Foundation

@testable import TakeShotKit

// Stand-ins for the three pieces of hardware the app talks to that are not the
// capture board: the audio OUTPUT, the DeckLink playout, and the modal file
// dialog. Each mirrors an existing precedent in this suite — the capture backend
// is a protocol with a mock, the audio INPUT device layer is a protocol with a
// fake, and the Finder opener is a replaceable handler — for the same reason:
// the real ones open a device, put a picture on somebody's monitor, or stop the
// calling thread until a human clicks a button.

/// An audio output the test drives by hand.
///
/// Every call the monitor makes is recorded, and the two things the monitor
/// READS back — whether the renderer wants more data, and where the timeline is
/// — are settable, so the resync window and the backlog cap can be driven
/// exactly instead of waited for.
///
/// `@unchecked Sendable` with a lock: the monitor calls this on its own serial
/// queue while the test reads it from the test's thread.
final class FakeAudioRoute: AudioRenderRoute, @unchecked Sendable {
    /// One `setRate` call. A named type because two loose numbers in a tuple
    /// read the same in either order.
    struct RateChange: Equatable {
        var rate: Float
        var time: CMTime
    }

    private let lock = NSLock()
    private var readyForMore = true
    private var timelineTime = CMTime.zero
    private var level: Float = 1
    private var enqueuedPTS: [CMTime] = []
    private var flushCount = 0
    private var rateChanges: [RateChange] = []
    private var armCount = 0
    private var disarmCount = 0
    private var routedTo: [String?] = []
    private var replacements = 0
    private var request: (queue: DispatchQueue, block: () -> Void)?

    // MARK: - what the test sets

    /// Whether the renderer will take a packet right now. False is a stalled
    /// output, which is what makes the backlog observable.
    var accepting: Bool {
        get { lock.withLock { readyForMore } }
        set { lock.withLock { readyForMore = newValue } }
    }

    /// Where the render timeline is, for the drift comparison.
    var clock: CMTime {
        get { lock.withLock { timelineTime } }
        set { lock.withLock { timelineTime = newValue } }
    }

    /// Fire the armed drain request, on the queue it was armed on, and wait for
    /// it. Nothing happens when no request is armed — which is itself the
    /// assertion in the busy-loop test.
    func deliverRequest() {
        guard let request = lock.withLock({ request }) else { return }
        request.queue.sync { request.block() }
    }

    // MARK: - what the test reads

    var enqueued: [CMTime] { lock.withLock { enqueuedPTS } }
    var flushes: Int { lock.withLock { flushCount } }
    var rates: [RateChange] { lock.withLock { rateChanges } }
    var arms: Int { lock.withLock { armCount } }
    var disarms: Int { lock.withLock { disarmCount } }
    var routes: [String?] { lock.withLock { routedTo } }
    var rendererReplacements: Int { lock.withLock { replacements } }
    var isRequestArmed: Bool { lock.withLock { request != nil } }

    // MARK: - AudioRenderRoute

    var isReadyForMoreMediaData: Bool { lock.withLock { readyForMore } }

    var volume: Float {
        get { lock.withLock { level } }
        set { lock.withLock { level = newValue } }
    }

    var currentTime: CMTime { lock.withLock { timelineTime } }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        lock.withLock { enqueuedPTS.append(pts) }
    }

    func requestMediaDataWhenReady(on queue: DispatchQueue,
                                   using block: @escaping () -> Void) {
        lock.withLock {
            armCount += 1
            request = (queue, block)
        }
    }

    func stopRequestingMediaData() {
        lock.withLock {
            disarmCount += 1
            request = nil
        }
    }

    func flush() {
        lock.withLock { flushCount += 1 }
    }

    func setRate(_ rate: Float, at time: CMTime) {
        lock.withLock { rateChanges.append(RateChange(rate: rate, time: time)) }
    }

    func route(to uid: String?) -> Bool {
        lock.withLock {
            routedTo.append(uid)
            guard uid == nil else { return false }
            // the real route replaces the renderer to get back to the default
            replacements += 1
            return true
        }
    }
}

/// A DeckLink output the test owns.
///
/// Holds every frame it was handed, so the feeder's two paths — hand the buffer
/// over untouched, or fit it into the output raster first — can be told apart by
/// identity rather than by inspecting the feeder.
final class FakePlayoutOutput: PlayoutOutput, @unchecked Sendable {
    let outputWidth: Int
    let outputHeight: Int

    private let lock = NSLock()
    private var frames: [CVPixelBuffer] = []
    private var stopCount = 0
    /// Held closed, `display` parks on it. How the coalescing test keeps the
    /// feeder's queue busy without a wall-clock window: the test waits for
    /// `entered` to know a frame really is parked, then submits behind it.
    private let gate = DispatchSemaphore(value: 0)
    private let entered = DispatchSemaphore(value: 0)
    private var gated = false
    /// Nothing here should ever wait, so a budget only decides whether a broken
    /// test fails or wedges the whole suite.
    private static let budget = DispatchTime.now() + .seconds(30)

    init(width: Int, height: Int) {
        outputWidth = width
        outputHeight = height
    }

    var displayed: [CVPixelBuffer] { lock.withLock { frames } }
    var stops: Int { lock.withLock { stopCount } }

    /// Make this and every later `display` park until `release()`.
    func hold() {
        lock.withLock { gated = true }
    }

    /// Wait until a frame is parked inside `display`.
    func waitUntilParked() -> Bool {
        entered.wait(timeout: Self.budget) == .success
    }

    /// Let one parked `display` through.
    func release() {
        gate.signal()
    }

    @discardableResult
    func display(_ buffer: CVPixelBuffer) -> Bool {
        if lock.withLock({ gated }) {
            entered.signal()
            _ = gate.wait(timeout: Self.budget)
        }
        lock.withLock { frames.append(buffer) }
        return true
    }

    func stop() {
        lock.withLock { stopCount += 1 }
    }
}

/// The file dialogs, answered without one.
///
/// `NSSavePanel.runModal()` stops the calling thread until a human clicks a
/// button, so the exporters behind it were unreachable. This records what was
/// asked for and answers with whatever the test lines up — including nothing,
/// which is how Cancel is spelled.
@MainActor
final class FakeFilePanel {
    private(set) var saveRequests: [FilePanel.SaveRequest] = []
    private(set) var openRequests: [FilePanel.OpenRequest] = []

    /// Answers for successive `save` calls. Exhausted — Cancel.
    var saveAnswers: [URL] = []
    /// Answers for successive `open` calls. Exhausted — Cancel.
    var openAnswers: [[URL]] = []

    var lastSaveName: String? { saveRequests.last?.suggestedName }
    var lastSaveDirectory: URL? { saveRequests.last?.directory }

    /// Install for the duration of `body` and put back whatever was there.
    /// Leaving a fake installed would silently disarm the dialogs for every
    /// later suite; the suite is serial, so the substitution cannot leak
    /// sideways while it is in place.
    static func installed(
        saving: [URL] = [], opening: [[URL]] = [],
        _ body: (FakeFilePanel) async throws -> Void) async throws {
        let fake = FakeFilePanel()
        fake.saveAnswers = saving
        fake.openAnswers = opening
        let previousSave = FilePanel.saveHandler
        let previousOpen = FilePanel.openHandler
        FilePanel.saveHandler = { request in
            fake.saveRequests.append(request)
            return fake.saveAnswers.isEmpty ? nil : fake.saveAnswers.removeFirst()
        }
        FilePanel.openHandler = { request in
            fake.openRequests.append(request)
            return fake.openAnswers.isEmpty ? [] : fake.openAnswers.removeFirst()
        }
        defer {
            FilePanel.saveHandler = previousSave
            FilePanel.openHandler = previousOpen
        }
        try await body(fake)
    }
}
